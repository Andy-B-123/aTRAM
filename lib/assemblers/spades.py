"""The Spades assembler."""

import os
import shutil
from lib.assemblers.base import BaseAssembler


class SpadesAssembler(BaseAssembler):
    """Wrapper for the Spades assembler."""

    @property
    def work_path(self):
        """The output directory name has unique requirements."""

        return os.path.join(self.iter_dir, 'spades')

    def __init__(self, args):
        super().__init__(args)
        self.steps = [self.spades]

    def spades(self):
        """Build the command for assembly."""

        cmd = ['spades.py ',
               '--only-assembler',
               '--threads {}'.format(self.args.cpus),
               '--memory {}'.format(self.args.max_memory),
               '--cov-cutoff {}'.format(self.args.cov_cutoff),
               '-o {}'.format(self.work_path)]

        if self.file['paired_count']:
            cmd.append("--pe1-1 '{}'".format(self.file['paired_1']))
            cmd.append("--pe1-2 '{}'".format(self.file['paired_2']))

        if self.file['single_1_count']:
            cmd.append("--s1 '{}'".format(self.file['single_1']))
        if self.file['single_2_count']:
            cmd.append("--s1 '{}'".format(self.file['single_2']))
        if self.file['single_any_count']:
            cmd.append("--s1 '{}'".format(self.file['single_any']))

        return ' '.join(cmd)

    def post_assembly(self):
        """Copy the assembler output."""

        src = os.path.join(self.work_path, 'contigs.fasta')
        shutil.move(src, self.file['output'])