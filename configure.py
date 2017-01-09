"""Handle configuration options and setup."""

# ??? Read the config file
# ??? Write the config file

import os
import argparse
# import tempfile
import configparser

DEFAULT = {
    'shard_size': 2.5e8,
    'evalue': 1e-9,
    'iterations': 5,
    'max_target_seqs': 100000000,
    'assembler': 'trinity',
}


def read_config_file(config, args):
    """Read in the config file and hoist the data into the config dict."""
    if not args.get('config_file', None):
        pass
    parser = configparser.ConfigParser()
    parser.read(args['config_file'])
    return config


def default_shard_count(config):
    """If we're not given an input shard count use the fasta file size / 250MB."""
    total_fasta_size = 0
    for sra_file in config['sra_files']:
        file_size = os.path.getsize(sra_file)
        if sra_file.lower().endswith('.fastq'):
            file_size /= 2  # Guessing that fastq files are about twice as big as fasta files
        total_fasta_size += file_size
    shard_count = int(total_fasta_size / DEFAULT['shard_size'])
    return shard_count if shard_count else 1  # We need at least one shard


def default_cpu_count():
    """If we're not given a default process count use the number of CPUs minus 2."""
    return os.cpu_count() - 2 if os.cpu_count() > 2 else 1


def setup_config_file():
    """Make our best guess for the configurations."""
    print('Not done yet!')


def parse_command_line(description='', args=None):
    """Build the command line parser and parse it."""
    args = args if args else []
    parser = argparse.ArgumentParser(description=description)
    add_arguments(parser, args)
    config = parse_args(parser)
    return config


def parse_args(parser):
    """Parse the commandline arguments and return a dict attribute object."""
    config = vars(parser.parse_args())

    # Default for shard count requires calulation after the args are parsed
    if 'shards' in config and config['shards'] < 1:
        config['shards'] = default_shard_count(config)

    return config


# pylint: disable=R0912
def add_arguments(parser, args):
    """Add command-line arguments. We want to keep them consistent between programs."""

    for arg in args:
        if arg == 'assembler':
            parser.add_argument(
                '-a', '--assembler', required=True,
                help='Which assembler to use. (Trinity, Abyss, Velvet)')

        elif arg == 'blast_db':
            parser.add_argument(
                '-b', '--blast-db', required=True,
                help=('SRA blast DB files (and others) will have this prefix. '
                      'This prefix may contain a directory to put the files into.'))

        elif arg == 'cpu':
            parser.add_argument(
                '-c', '--cpu', type=int, default=default_cpu_count(),
                help='Number of cpus to use.')

        elif arg == 'evalue':
            parser.add_argument(
                '-e', '--evalue', default=DEFAULT['evalue'], type=float,
                help='The default evalue is {}.'.format(DEFAULT['evalue']))

        elif arg == 'file_prefix':
            parser.add_argument(
                '-f', '--file-prefix', default=DEFAULT['iterations'],
                help=('This will get prepended to all of the . '
                      'The default is {}.').format(DEFAULT['iterations']))

        elif arg == 'iterations':
            parser.add_argument(
                '-i', '--iterations', default=DEFAULT['iterations'], type=int,
                help=('The number of pipline iterations. '
                      'The default is {}.').format(DEFAULT['iterations']))

        elif arg == 'max_target_seqs':
            parser.add_argument(
                '-M', '--max-target-seqs', type=int, default=DEFAULT['max_target_seqs'],
                help='Maximum hit sequences per shard. Default is {}.'.format(
                    DEFAULT['max_target_seqs']))

        elif arg == 'protein':
            parser.add_argument(
                '-p', '--protein', nargs='?', const=True, default=False,
                help='Are the target sequences protein?')

        elif arg == 'shards':
            parser.add_argument(
                '-s', '--shards', type=int, help='Number of SRA shards to create.', default=-1)

        elif arg == 'sra_files':
            parser.add_argument(
                'sra_files', nargs='+',
                help='Short read archives in fasta or fastq format. May contain wildcards.')

        elif arg == 'target':
            parser.add_argument(
                '-t', '--target', required=True,
                help='The path to the fasta file with sequences of interest.')

        elif arg == 'work_dir':
            parser.add_argument(
                '-w', '--work-dir',
                help='A directory to use as a temp dir. Default to a system temp dir.')
# pylint: enable=R0912


if __name__ == '__main__':
    setup_config_file()
