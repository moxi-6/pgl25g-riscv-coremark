"""Synthetic controls test parsing behavior, never provide board scores."""
import unittest
from coremark_score import evaluate, VALIDATED

GOOD = f'''2K performance run parameters for coremark.
CoreMark Size    : 666
Total ticks      : 500000000
Total time (secs): 10
Iterations       : 168
seedcrc          : 0xe9f5
[0]crclist       : 0xe714
[0]crcmatrix     : 0x1fd7
[0]crcstate      : 0x8e3a
[0]crcfinal      : 0xabcd
{VALIDATED}
'''


class ReportTests(unittest.TestCase):
    def test_good_fixture_is_not_hardware_evidence(self):
        r = evaluate(GOOD, evidence_kind='Fixture', lut_count=2000)
        self.assertEqual(r['verdict'], 'PASS')
        self.assertFalse(r['publishable'])
        self.assertAlmostEqual(r['coremark_score'], 16.8)
        self.assertAlmostEqual(r['coremark_per_mhz'], 0.336)
        self.assertAlmostEqual(r['coremark_per_lut'], 0.0084)

    def test_board_label_is_explicit(self):
        self.assertFalse(evaluate(GOOD)['publishable'])
        self.assertTrue(evaluate(GOOD, evidence_kind='BoardCapture')['publishable'])

    def test_validation_profile(self):
        text=GOOD.replace('0xe9f5','0x18f2').replace('0xe714','0xe3c1').replace('0x1fd7','0x0747').replace('0x8e3a','0x8d84')
        self.assertEqual(evaluate(text)['verdict'],'PASS')

    def test_bad_crc(self):
        self.assertEqual(evaluate(GOOD.replace('0x1fd7','0xdead'))['verdict'],'FAIL_CRC')

    def test_missing_each_required_field(self):
        for line in GOOD.splitlines()[1:-1]:
            with self.subTest(line=line):
                self.assertEqual(evaluate(GOOD.replace(line+'\n',''))['verdict'],'FAIL_REPORT')

    def test_empty_and_multiple_runs(self):
        for text in ('',GOOD+GOOD):
            self.assertEqual(evaluate(text)['verdict'],'FAIL_REPORT')

    def test_duplicate_ticks(self):
        self.assertEqual(evaluate(GOOD+'Total ticks : 500000000\n')['verdict'],'FAIL_REPORT')

    def test_bad_numeric_fields(self):
        for old,new in [('500000000','0'),('500000000','-1'),('500000000','NaN'),
                        ('500000000','18446744073709551616'),('168','0'),('168','1.5'),
                        ('secs): 10','secs): NaN'),('666','665'),('0xe714','e714')]:
            with self.subTest(old=old,new=new):
                self.assertEqual(evaluate(GOOD.replace(old,new))['verdict'],'FAIL_REPORT')

    def test_validation_and_errors(self):
        for text in (GOOD.replace(VALIDATED,''),GOOD+'Errors detected\n',GOOD+'ERROR! other error\n'):
            self.assertEqual(evaluate(text)['verdict'],'FAIL_VALIDATION')

    def test_short_without_banner_rounding_boundary(self):
        for ticks in (1,499999999):
            text=GOOD.replace('500000000',str(ticks)).replace('secs): 10',f'secs): {ticks//50000000}')
            self.assertEqual(evaluate(text)['verdict'],'FAIL_TOO_SHORT')

    def test_short_simulation(self):
        text=GOOD.replace('500000000','2972310').replace('secs): 10','secs): 0').replace(VALIDATED,'ERROR! Must execute for at least 10 secs for a valid result!\nErrors detected')
        self.assertEqual(evaluate(text,evidence_kind='Simulation')['verdict'],'FAIL_TOO_SHORT')

    def test_time_and_clock_consistency(self):
        self.assertEqual(evaluate(GOOD.replace('secs): 10','secs): 11'))['verdict'],'FAIL_REPORT')
        self.assertEqual(evaluate(GOOD,clock_hz=25000000)['verdict'],'FAIL_REPORT')

    def test_case_sensitive_labels(self):
        self.assertEqual(evaluate(GOOD.replace('Total ticks','total ticks'))['verdict'],'FAIL_REPORT')


if __name__ == '__main__':
    unittest.main(verbosity=2)
