#!/usr/bin/env perl
use strict;
use Getopt::Long;
use Pod::Usage;
use File::Basename;
use File::Temp qw/ tempfile tempdir /;
use FindBin;
use lib "$FindBin::Bin/lib";
require Subfunctions;
use Module::Load;
require Sequenceretrieval;

load Assembler;
Assembler->parse_config();

my $debug = 0;

my $hit_matrix = {};

if (@ARGV == 0) {
    pod2usage(-verbose => 1);
}

my $runline = "running " . basename($0) . " " . join (" ", @ARGV) . "\n";

#required: input file names
my $short_read_archive = 0;
my $target_fasta = 0;

#optional parameters:
my $help = 0;
my $log_file = "";
my $output_file = "";
my $processes = 0;
my $fraclibs = 1;
my $intermediate = 0;
my $save_temp = 0;
my $complete = 0;
my $protflag = 0;
my $bitscore = 70;
my $contiglength = 100;
my $max_processes = 0;

#parameters with modifiable default values
my $ins_length = 300;
my $iterations = 5;
my $start_iter = 1;
my $exp_cov = 30;
my $evalue = 10e-10;
my $max_target_seqs = 100000000;
my $assembler = "Velvet";
my $kmer = 31;

GetOptions ('reads=s' => \$short_read_archive,
            'target=s' => \$target_fasta,
            'assembler=s' => \$assembler,
            'start_iteration=i' => \$start_iter,
            'iterations=i' => \$iterations,
			'fraction=f' => \$fraclibs,
            'log_file=s' => \$log_file,
            'output=s' => \$output_file,
            'protein' => \$protflag,
            'max_processes|processes=i' => \$max_processes,
            'tempfiles=s' => \$save_temp,
            'debug' => \$debug,
            'complete' => \$complete,
            'insert_length|ins_length=i' => \$ins_length,
            'exp_coverage|expected_coverage=i' => \$exp_cov,
            'kmer=i' => \$kmer,
            'bitscore=i' => \$bitscore,
            'evalue=f' => \$evalue,
            'length=i' => \$contiglength,
            'help|?' => \$help) or pod2usage(-msg => "GetOptions failed.", -exitval => 2);

if ($help) {
    pod2usage(-verbose => 1);
}

if ($debug) {
	set_debug(1);
}

unless($short_read_archive and $target_fasta) {
    pod2usage(-msg => "Must specify a short read archive (that has already been prepared with makelibrary.pl) and a target gene in fasta form.");
}

# check to make sure that the specified short read archive exists:
unless ((-e "$short_read_archive.0.1.fasta") && (-e "$short_read_archive.0.2.fasta")) {
	pod2usage(-msg => "Short read archive does not seem to be in the format made by makelibrary.pl. Did you specify the name correctly?");
}


if ($output_file eq "") {
    $output_file = $short_read_archive;
}
if ($log_file eq "") {
	$log_file = "$output_file.log";
}
if ($save_temp == 0) {
    $intermediate = $output_file;
} else {
    $intermediate = $save_temp;
}

my $log_fh;
open $log_fh, ">", $log_file or die "couldn't open $log_file\n";
set_log($log_fh);

print $runline;
print $log_fh $runline;

my $executing_path = dirname(__FILE__);
my $cmd;

# set up the number of partial libraries we'll be using.
my $numlibs = count_partial_libraries("$short_read_archive");
my $max_partial = $numlibs - 1;
$processes = int ($numlibs * $fraclibs);

# obviously we need to use at least one library.
if ($processes == 0) {
	$processes = 1;
}

unless ((-e "$short_read_archive.$max_partial.1.fasta") && (-e "$short_read_archive.$max_partial.2.fasta")) {
	pod2usage(-msg => "Short read archives were not prepared to handle $numlibs processes.");
}

print "Using $processes of $numlibs total partial libraries.\n";
print $log_fh "Using $processes of $numlibs total partial libraries.\n";

open CONTIGS_FH, ">", "$output_file.all.fasta";
truncate CONTIGS_FH, 0;
close CONTIGS_FH;

my $start_seq = "";
my $end_seq = "";
my @complete_contigs = ();

# process the target sequence file to look for the start seq and end seq.
my $search_fasta = $target_fasta;
my @target_seqs = ();

open SEARCH_FH, "<", $search_fasta;
my $name = "";
my $seq = "";
my $fullseq = "";
while (my $line=readline SEARCH_FH) {
	chomp $line;
	if ($line =~ />(.*)/) {
		if ($name ne "") {
			push @target_seqs, "$name,$seq";
		}
		$name = $1;
		$seq = "";
	} else {
		$seq .= $line;
		$fullseq .= $seq;
	}
}
push @target_seqs, "$name,$seq";

close SEARCH_FH;

my $protein = 0;
if ($protflag != 0) {
	$protein = 1;
} else {
	$protein = is_protein($fullseq);
}

my $len = 100;
if ($protein==1) {
	$len = 30;
}

# check first target seq, see if we need to make just the first bit separated for checking completeness.
my $firstseq = shift @target_seqs;
if ($firstseq =~ /(.*),(.{$len})(.*)/) {
	# split into two smaller seqs:
	$start_seq = "aTRAM_target_start";
	unshift @target_seqs, $firstseq;
	unshift @target_seqs, "$start_seq,$2";
} else {
	# it's short enough to just go as-is
	$firstseq =~ /(.*),/;
	$start_seq = $1;
	unshift @target_seqs, $firstseq;
}

# check last target seq, see if we need to make just the first bit separated for checking completeness.
my $lastseq = pop @target_seqs;
if ($lastseq =~ /(.*),(.*)(.{$len})/) {
	# split into two smaller seqs:
	$end_seq = "aTRAM_target_end";
	push @target_seqs, $lastseq;
	push @target_seqs, "$end_seq,$3";
} else {
	# it's short enough to just go as-is
	$lastseq =~ /(.*),/;
	$end_seq = $1;
	push @target_seqs, $lastseq;
}

# okay, let's re-assemble the file for the target fasta.
my ($TARGET_FH, $target_fasta) = tempfile(UNLINK => 1);
my @targets = ();
foreach my $line (@target_seqs) {
	$line =~ /(.*),(.*)/;
	print $TARGET_FH ">$1\n$2\n";
	push @targets, $1;
}

# make a database from the target so that we can compare contigs to the target.
my (undef, $targetdb) = tempfile(UNLINK => 1);
if ($protein == 1) {
	system_call ("makeblastdb -in $target_fasta -dbtype prot -out $targetdb.db -input_type fasta");
} else {
	system_call ("makeblastdb -in $target_fasta -dbtype nucl -out $targetdb.db -input_type fasta");
}

if ($start_iter > 1) {
	my $x = $start_iter-1;
	$search_fasta = "$intermediate.".($start_iter-1).".contigs.fasta";
}

# writing the header line for the results file
open RESULTS_FH, ">", "$output_file.results.txt";
print RESULTS_FH "contig\t" . join ("\t",@targets) . "\ttotal score\n";
close RESULTS_FH;

my $best_score = 0;

# STARTING ITERATIONS:
for (my $i=$start_iter; $i<=$iterations; $i++) {
	print ("iteration $i starting...\n");
	print $log_fh ("iteration $i starting...\n");

	my $sra = "$short_read_archive";
	my $current_partial_file = "$intermediate.blast.$i";
	my @partialfiles = ();
	my @pids = ();

	# we are multithreading:
	print "\tblasting short reads...\n";
	for (my $p=0; $p<$processes; $p++) {
		$sra = "$short_read_archive.$p";
		$current_partial_file = "$intermediate.blast.$i.$p";
		push @partialfiles, $current_partial_file;
		# 1. blast to find any short reads that match the target.
		if (($protein == 1) && ($i == 1)) {
			push @pids, fork_cmd ("tblastn -max_target_seqs $max_target_seqs -db $sra.db -query $search_fasta -outfmt '6 sseqid' -out $current_partial_file");
		} else {
			push @pids, fork_cmd ("blastn -task blastn -evalue $evalue -max_target_seqs $max_target_seqs -db $sra.db -query $search_fasta -outfmt '6 sseqid' -out $current_partial_file");
		}
		if (($max_processes > 0) && (@pids >= ($max_processes - 1))) {
			# don't spawn off too many threads at once.
			wait_for_forks(\@pids);
		}
	}
	wait_for_forks(\@pids);

	print "\tgetting paired ends...\n";
	for (my $p=0; $p<$processes; $p++) {
		$sra = "$short_read_archive.$p";
		$current_partial_file = "$intermediate.blast.$i.$p";
		# 2 and 3. find the paired end of all of the blast hits.
		push @pids, fork_pair_retrieval("$sra.#.fasta", "$current_partial_file", "$current_partial_file.fasta");
		if (($max_processes > 0) && (@pids >= ($max_processes - 1))) {
			# don't spawn off too many threads at once.
			wait_for_forks(\@pids);
		}
	}
	wait_for_forks(\@pids);

	# now we need to piece all of the partial files back together.
	my $fastafiles = join (" ", map {$_ . ".fasta"} @partialfiles);
	system_call ("cat $fastafiles > $intermediate.$i.blast.fasta");
	system_call ("rm $fastafiles");

	# remove intermediate blast results
	my $readfiles = join (" ", @partialfiles);
	system_call ("rm $readfiles");

	# SHUTDOWN CHECK: did we not find any reads? Go ahead and quit.
	if ((-s "$intermediate.$i.blast.fasta") == 0) {
		print "No similar reads were found.\n";
		last;
	}
	my $contigs_file = "";
	if ($save_temp) {
		$contigs_file = "$intermediate.$i.contigs.fasta";
	} else {
		(undef, $contigs_file) = tempfile(UNLINK => 1);
	}

	print "\tassembling pairs with $assembler...\n";
	# 4. assemble the reads...
	load "$assembler";

	my $assembly_params = { 'kmer' => $kmer,
							'tempdir' => "$intermediate.$assembler",
							'ins_length' => $ins_length,
							'exp_cov' => $exp_cov,
							'min_contig_len' => 200,
						  };

	if ($i > 1) {
		# for iterations after the first one, we can use previous contigs to seed the assembly.
		$assembly_params->{'longreads'} = $search_fasta;
	}

	my $assembled_contig_file = "$assembler"->assembler ("$intermediate.$i.blast.fasta", $assembly_params, $log_fh);
	"$assembler"->rename_contigs($assembled_contig_file, $contigs_file);


	# 5. now we filter out the contigs to look for just the best ones.
	print "\tfiltering contigs...\n";

	my $blast_file = "";
	if ($save_temp) {
		$blast_file = "$intermediate.$i.blast";
	} else {
		(undef, $blast_file) = tempfile(UNLINK => 1);
	}

	if ($protein == 1) {
		system_call ("blastx -db $targetdb.db -query $contigs_file -out $blast_file -outfmt '6 qseqid sseqid bitscore qstart qend sstart send qlen'");
	} else {
		system_call ("tblastx -db $targetdb.db -query $contigs_file -out $blast_file -outfmt '6 qseqid sseqid bitscore qstart qend sstart send qlen'");
	}

	# 6. we want to keep the contigs that have a bitscore higher than $bitscore.
	print "\tsaving best-scoring contigs...\n";
	my $raw_hit_matrix = {};
	make_hit_matrix ($blast_file, $raw_hit_matrix, $i);
	my @contig_names = ();
	my $old_matrix_size = (keys %$hit_matrix);
	my $high_score = process_hit_matrix ($raw_hit_matrix, \@targets, $bitscore, $contiglength, $hit_matrix, \@contig_names);

	if ($high_score > $best_score) {
		$best_score = $high_score;
	}

	# SHUTDOWN CHECK:
	if ((keys %$hit_matrix) == $old_matrix_size) {
		print ("No new contigs were found.\n");
		last;
	}

	# SHUTDOWN CHECK:
	if (@contig_names == 0) {
		print ("No contigs had a bitscore greater than $bitscore and longer than $contiglength in iteration $i: the highest bitscore this time was $high_score.\n");
		last;
	}

	# we've finished the work of the iteration. Now we do post-processing to save results to files.
	my $contig_seqs = findsequences ($contigs_file, \@contig_names);

	# we'll use the resulting contigs as the query for the next iteration.
	if ($save_temp) {
		$search_fasta = "$intermediate.$i.contigs.fasta";
	} else {
		(undef, $search_fasta) = tempfile(UNLINK => 1);
	}
	open SEARCH_FH, ">", $search_fasta;
	foreach my $contig_name (@contig_names) {
		print SEARCH_FH ">$contig_name\n$contig_seqs->{$contig_name}\n";
	}
	close SEARCH_FH;

	# save off these resulting contigs to the ongoing contigs file.
	open CONTIGS_FH, ">>", "$output_file.all.fasta";
	print $log_fh "\twriting contigs to $output_file.all.fasta:\n";
	foreach my $contig_name (@contig_names) {
		my $seq = $contig_seqs->{$contig_name};
		# revcomping contigs with negative strand directions:
		if ($hit_matrix->{$contig_name}->{"strand"} < 0) {
			print $log_fh "\t\twriting out reverse-complement of $contig_name\n";
			$seq = reverse_complement($seq);
			print CONTIGS_FH ">$i.$contig_name\n$seq\n";
		} else {
			print $log_fh "\t\twriting out $contig_name\n";
			print CONTIGS_FH ">$i.$contig_name\n$seq\n";
		}
		$hit_matrix->{$contig_name}->{"seq"} = $seq;
	}
	close CONTIGS_FH;

	open RESULTS_FH, ">>", "$output_file.results.txt";
	foreach my $contig_name (@contig_names) {
		print RESULTS_FH "$i.$contig_name\t";
		foreach my $target (@targets) {
			my $score = $hit_matrix->{$contig_name}->{$target};
			if ($score == undef) {
				print RESULTS_FH "-\t";
			} else {
				print RESULTS_FH "$score\t";
			}
		}
		my $total = $hit_matrix->{$contig_name}->{"total"};
		print RESULTS_FH "$total\n";
		if ((abs($hit_matrix->{$contig_name}->{$start_seq}) > 20) && (abs($hit_matrix->{$contig_name}->{$end_seq}) > 20)) {
			push @complete_contigs, "$i.$contig_name";
		}
	}
	close RESULTS_FH;

	# SHUTDOWN CHECK:
	if ($complete == 1) {
		if (@complete_contigs > 0) {
			print ("Contigs that cover the entire target sequence were found; quitting at iteration $i.\n");
			last;
		}
	}
}

print "\n\nContigs by target coverage:\n";

system ("cat $output_file.results.txt");
print "\nContigs containing the entire target sequence:\n\t" . join("\n\t", @complete_contigs) . "\n";
print $log_fh "Contig coverage in $output_file.results.txt\n";
print $log_fh "\nContigs containing the entire target sequence:\n\t" . join("\n\t", @complete_contigs) . "\n";

close $log_fh;

if (@complete_contigs > 0) {
	open COMPLETE_FH, ">", "$output_file.complete.fasta";
	foreach my $contig_name (@complete_contigs) {
		$contig_name =~ /(\d+)\.(.+)/;
		print COMPLETE_FH ">$contig_name\n$hit_matrix->{$2}->{'seq'}\n";
	}
	close COMPLETE_FH;
}

my @best_unsorted = ();
foreach my $contig_name (keys %$hit_matrix) {
	if ($hit_matrix->{$contig_name}->{"total"} > ($best_score - 100)) {
		push @best_unsorted, $contig_name;
	}
}

if (@best_unsorted > 0) {
	my @best_contigs = sort sort_contigs @best_unsorted;
	open BEST_FH, ">", "$output_file.best.fasta";
	foreach my $contig_name (@best_contigs) {
		print BEST_FH ">$hit_matrix->{$contig_name}->{'iteration'}.$contig_name\n$hit_matrix->{$contig_name}->{'seq'}\n";
	}
	close BEST_FH;
}

sub sort_contigs {
	if ($hit_matrix->{$a}->{"total"} < $hit_matrix->{$b}->{"total"}) {
		return 1;
	} elsif ($hit_matrix->{$a}->{"total"} > $hit_matrix->{$b}->{"total"}) {
		return -1;
	} else {
		if (length($hit_matrix->{$a}->{"seq"}) < length($hit_matrix->{$b}->{"seq"})) {
			return 1;
		} elsif (length($hit_matrix->{$a}->{"seq"}) > length($hit_matrix->{$b}->{"seq"})) {
			return -1;
		}
	}
	return 0;
}

sub reverse_complement {
	my $charstr = shift;

	# reverse the DNA sequence
	my $revcomp = reverse($charstr);

	# complement the reversed DNA sequence
	$revcomp =~ tr/ABCDGHMNRSTUVWXYabcdghmnrstuvwxy/TVGHCDKNYSAABWXRtvghcdknysaabwxr/;
	return $revcomp;
}


__END__

=head1 NAME

aTRAM.pl

=head1 SYNOPSIS

aTRAM.pl -reads shortreadfile -target target.fasta [-iterations int] [-start_iteration int] [-log_file filename] [-output filename] -options

aTRAM does targeted denovo assembly of short reads to find homologs or paralogs of a target sequence.

=head1 OPTIONS
  pipeline parameters:
  -reads:     		short read archive (already run through makelibrary.pl).
  -target:          fasta file with sequences of interest.
  -output:	        optional: the prefix for the pipeline's output files (default name is the same as -reads).
  -log_file:        optional: a file to store output of the pipeline.
  -iterations:      optional: the number of pipeline iterations (default 5).
  -start_iteration: optional: if resuming from previous run, which iteration number to start from (default 0).
  -blast:			optional: saves the blast hits for the raw read library to the specified file.

  target fasta type: aTRAM, by default, tries to guess the type of fasta file specified with -target (either protein or dna).
  override options:
  -protein:         if the target sequence is a protein fasta file.
  -type:            one of the following values: dna, nucl, aa, protein.

  optional parameters:
  -velvet:          if specified, skips the blast steps and performs only velvet assembly on previously-generated intermediate files.
  -complete:        if specified, automatically quits when a complete homolog is recovered.

  optional velvet assembly parameters:
  -ins_length:	    the size of the fragments used in the short-read library (default 300).
  -exp_coverage:    the expected coverage of the region for velvetg (default 30).

  optional values for searching short reads:
  -max_target_seqs: default value is 10e8.
  -evalue:          default value is 10e-10.

  optional values for blast-filtering contigs:
  -bitscore:        default value is 70.
  -length:          default value is 100.

=cut
