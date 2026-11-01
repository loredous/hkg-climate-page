#!/usr/bin/env python3
"""Run only pre.sh's firmware case against inert log/refuse functions.
No package hooks, Android commands, stock files or patch tool are executed.
"""
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]

class FirmwareMessageTests(unittest.TestCase):
    def gate(self, product):
        source = (ROOT / 'package/scripts/pre.sh').read_text()
        match = re.search(r'case "\$_p" in\n.*?\nesac', source, re.S)
        self.assertIsNotNone(match, 'pre.sh firmware case must be reviewed if its shape changes')
        script = 'log() { :; }; refuse() { echo "$1"; exit 1; }; _p=$1\n' + match.group(0)
        return subprocess.run(['/bin/sh', '-c', script, 'fixture', product], text=True, capture_output=True)

    def test_supported_build_still_passes_this_gate(self):
        # Only this gate, not the later stock-hash or install checks.
        self.assertEqual(self.gate('NEEV23.USA.0000.V015.012.260507').returncode, 0)

    def test_other_builds_refused_without_downgrade_or_update_advice(self):
        for product in ['NEEV23.USA.0000.V016.010.260903',
                        'NEEV23.USA.0000.V014.010.250818',
                        'NEEV23SE.USA.0000.V016.010.260903',
                        'NEEV.USA.0000.V016.010.260903', '', 'unknown']:
            with self.subTest(product=product):
                r = self.gate(product)
                self.assertEqual(r.returncode, 1)
                self.assertIn('not supported', r.stdout)
                self.assertIn('do not downgrade', r.stdout)
                self.assertNotIn('Update the head unit first', r.stdout)

if __name__ == '__main__':
    unittest.main(verbosity=2)
