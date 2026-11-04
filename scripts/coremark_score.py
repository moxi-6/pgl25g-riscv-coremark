"""Validate one complete CoreMark report without inferring board provenance."""
import argparse
import hashlib
import json
import math
import re
from pathlib import Path

KNOWN = {0xE9F5: ('2K performance', 0xE714, 0x1FD7, 0x8E3A),
         0x18F2: ('2K validation', 0xE3C1, 0x0747, 0x8D84)}
VALIDATED = 'Correct operation validated. See readme.txt for run and reporting rules.'
LABELS = ('CoreMark Size', 'Total ticks', 'Total time (secs)', 'Iterations',
          'seedcrc', '[0]crclist', '[0]crcmatrix', '[0]crcstate', '[0]crcfinal')


def evaluate(text, clock_hz=50_000_000, evidence_kind='Unknown', lut_count=None):
    if clock_hz <= 0 or (lut_count is not None and lut_count <= 0):
        raise ValueError('Clock and optional LUT count must be positive')
    lines, errors, fields = text.splitlines(), [], {}
    for label in LABELS:
        found = [m.group(1) for line in lines
                 if (m := re.fullmatch(re.escape(label) + r'\s*:\s*(.*?)\s*', line))]
        if len(found) != 1:
            errors.append(f'{label}: expected exactly one field, found {len(found)}')
        fields[label] = found[0] if len(found) == 1 else None

    def integer(label, maximum):
        value = fields[label]
        if value is None:
            return None
        if not re.fullmatch(r'[0-9]+', value) or not 0 < int(value) <= maximum:
            errors.append(f'{label}: invalid positive integer')
            return None
        return int(value)

    def crc(label):
        value = fields[label]
        if value is None:
            return None
        if not re.fullmatch(r'0x[0-9a-fA-F]{1,4}', value):
            errors.append(f'{label}: invalid 16-bit hexadecimal CRC')
            return None
        return int(value, 16)

    size = integer('CoreMark Size', 0xFFFFFFFF)
    ticks = integer('Total ticks', 0xFFFFFFFFFFFFFFFF)
    iterations = integer('Iterations', 0xFFFFFFFF)
    seed = crc('seedcrc')
    crcs = [crc(k) for k in ('[0]crclist', '[0]crcmatrix', '[0]crcstate')]
    final_crc = crc('[0]crcfinal')
    reported_seconds, raw_seconds = None, fields['Total time (secs)']
    if raw_seconds is not None:
        if not re.fullmatch(r'[0-9]+(?:\.[0-9]+)?', raw_seconds):
            errors.append('Total time (secs): invalid nonnegative number')
        else:
            reported_seconds = float(raw_seconds)
            if not math.isfinite(reported_seconds):
                errors.append('Total time (secs): nonfinite value')
    seconds = ticks / clock_hz if ticks is not None else None
    if seconds is not None and reported_seconds is not None:
        consistent = (reported_seconds == math.floor(seconds) if '.' not in raw_seconds
                      else abs(reported_seconds - seconds) <= 0.0001)
        if not consistent:
            errors.append('Printed seconds disagree with ticks/configured clock')
    validated = lines.count(VALIDATED) == 1
    short_banner = any(s.startswith('ERROR! Must execute for at least 10 secs') for s in lines)
    other_errors = any((s.startswith('ERROR!') and not s.startswith('ERROR! Must execute for at least 10 secs'))
                       or re.search(r'ERROR!.*crc', s, re.IGNORECASE) for s in lines)
    has_errors = 'Errors detected' in lines
    # Integer comparison BEFORE rounding prevents 9.99999998 seconds passing.
    long_enough = ticks is not None and ticks >= 10 * clock_hz
    profile = KNOWN.get(seed)
    crc_correct = profile is not None and tuple(crcs) == profile[1:]
    checks = {'complete_single_report': not errors, 'seedcrc_known': profile is not None,
              'size_666': size == 666,
              'crclist_match': profile is not None and crcs[0] == profile[1],
              'crcmatrix_match': profile is not None and crcs[1] == profile[2],
              'crcstate_match': profile is not None and crcs[2] == profile[3],
              'ran_at_least_10s': long_enough, 'validated_line_present': validated,
              'no_errors': not (has_errors or short_banner or other_errors)}
    if errors or size != 666:
        verdict = 'FAIL_REPORT'
    elif not crc_correct:
        verdict = 'FAIL_CRC'
    elif not long_enough:
        verdict = 'FAIL_TOO_SHORT'
    elif not validated or has_errors or short_banner or other_errors:
        verdict = 'FAIL_VALIDATION'
    else:
        verdict = 'PASS'
    score = iterations * clock_hz / ticks if iterations is not None and ticks is not None else None
    hex_crc = lambda x: f'0x{x:04x}' if x is not None else None
    return {'seedcrc': hex_crc(seed), 'profile': profile[0] if profile else None,
            'coremark_size': size, 'iterations': iterations, 'total_ticks': ticks,
            'clock_hz': clock_hz, 'seconds': seconds, 'reported_seconds': reported_seconds,
            'crclist': hex_crc(crcs[0]), 'crcmatrix': hex_crc(crcs[1]),
            'crcstate': hex_crc(crcs[2]), 'crcfinal': hex_crc(final_crc),
            'validated_line_present': validated, 'coremark_score': score,
            'coremark_per_mhz': score / (clock_hz / 1_000_000) if score is not None else None,
            'lut_count': lut_count, 'coremark_per_lut': score / lut_count if score is not None and lut_count else None,
            'checks': checks, 'errors': errors, 'verdict': verdict, 'evidence_kind': evidence_kind,
            'publishable': verdict == 'PASS' and evidence_kind == 'BoardCapture',
            'scope': 'Report validation only. BoardCapture is caller-supplied provenance; '
                     'this parser cannot authenticate hardware execution or measure clock frequency.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path)
    parser.add_argument('--clock-hz', type=int, default=50_000_000)
    parser.add_argument('--lut-count', type=int)
    parser.add_argument('--evidence-kind', choices=('Unknown', 'Simulation', 'Fixture', 'BoardCapture'), default='Unknown')
    args = parser.parse_args()
    raw = args.capture.read_bytes()
    report = evaluate(raw.decode('utf-8-sig'), args.clock_hz, args.evidence_kind, args.lut_count)
    report.update(capture=str(args.capture.resolve()), capture_sha256=hashlib.sha256(raw).hexdigest())
    output = args.output_dir or args.capture.parent
    output.mkdir(parents=True, exist_ok=True)
    (output / 'coremark_score.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    summary = (f"COREMARK_SCORE profile={report['profile']} verdict={report['verdict']}\n"
               f"  iterations={report['iterations']} ticks={report['total_ticks']} seconds={report['seconds']}\n"
               f"  score={report['coremark_score']} CoreMark/MHz={report['coremark_per_mhz']}\n"
               f"  evidence_kind={report['evidence_kind']} publishable={report['publishable']}\n")
    if report['errors']:
        summary += '\n'.join(report['errors']) + '\n'
    (output / 'coremark_score.txt').write_text(summary, encoding='utf-8')
    print(summary, end='')
    return 0 if report['verdict'] in ('PASS', 'FAIL_TOO_SHORT') else 1


if __name__ == '__main__':
    raise SystemExit(main())
