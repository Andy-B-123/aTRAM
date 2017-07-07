"""The Trinity assembler."""

import os
import shutil
from lib.assemblers.base import BaseAssembler


class TrinityAssembler(BaseAssembler):
    """Wrapper for the trinity assembler."""

    @property
    def work_path(self):
        """The output directory name has unique requirements."""

        return os.path.join(self.iter_dir, 'trinity')

    def __init__(self, args):
        super().__init__(args)
        self.steps = [self.trinity]

    def trinity(self):
        """Build the command for assembly."""

        cmd = ['Trinity',
               '--seqType fa',
               '--max_memory {}G'.format(self.args.max_memory),
               '--CPU {}'.format(self.args.cpus),
               "--output '{}'".format(self.work_path),
               '--full_cleanup']

        if not self.args.bowtie2:
            cmd.append('--no_bowtie')

        if self.file['paired_count']:
            cmd.append("--left '{}'".format(self.file['paired_1']))
            cmd.append("--right '{}'".format(self.file['paired_2']))
        else:
            single_ends = []
            if self.file['single_1_count']:
                single_ends.append(self.file['single_1'])
            if self.file['single_2_count']:
                single_ends.append(self.file['single_2'])
            if self.file['single_any_count']:
                single_ends.append(self.file['single_any'])
            if single_ends:
                cmd.append("-single '{}'".format(','.join(single_ends)))

        if self.file['long_reads'] and not self.args.no_long_reads:
            cmd.append("--long_reads '{}'".format(self.file['long_reads']))

        return ' '.join(cmd)

    def post_assembly(self):
        """Copy the assembler output."""

        src = os.path.join(self.iter_dir, 'trinity.Trinity.fasta')
        shutil.move(src, self.file['output'])