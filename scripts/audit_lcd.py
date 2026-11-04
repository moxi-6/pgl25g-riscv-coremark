"""Cross-check released LCD pin locations, IO properties and source provenance."""
import hashlib
import json
import re
import argparse
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--target', choices=['lcd', 'lcd_game', 'shooter', 'mine'], default='lcd')
args = parser.parse_args()
target = args.target
root = Path(__file__).resolve().parents[1]
release = root / 'build/board_release' / target
if target in ('lcd_game', 'shooter', 'mine'):
    release /= 'game' if target == 'lcd_game' else target
vendor = (root.parent / "3_开发板原理图/ATK-L50_IO.fdc").read_text(encoding="gb18030")
official = dict(re.findall(r"define_attribute \{p:(lcd_[^}]+)\} \{PAP_IO_LOC\} \{([^}]+)\}", vendor))
pcf = (release / "pins.pcf").read_text(encoding="utf-8-sig")
implemented = {}
touch_implemented = {}
touch_locations = {'tp_scl': 'L4', 'tp_sda': 'K3', 'tp_rst': 'L7', 'tp_int': 'L5'}
locations = set()
for name, attrs in re.findall(r"def_port \{([^}]+)\} ([^\n]+)", pcf):
    fields = dict(re.findall(r"(\w+)=([^\s]+)", attrs))
    assert fields["LOC"] not in locations, f"Duplicate pin: {fields['LOC']}"
    locations.add(fields["LOC"])
    if name.startswith("lcd_"):
        assert fields["LOC"] == official[name], name
        assert fields["VCCIO"] == "3.3", name
        assert fields["IOSTANDARD"] == "LVCMOS33", name
        assert fields["DRIVE"] == "4", name
        implemented[name] = fields
    if target == 'mine' and name in touch_locations:
        assert fields['LOC'] == touch_locations[name], name
        assert fields['VCCIO'] == '3.3' and fields['IOSTANDARD'] == 'LVCMOS33', name
        touch_implemented[name] = fields
assert len(implemented) == len(official) == 30
if target == 'mine':
    assert len(touch_implemented) == 4, 'Missing touch pins'
manifest = json.loads((release / "release.json").read_text(encoding="utf-8-sig"))
for entry in manifest["files"]:
    digest = hashlib.sha256((release / entry["file"]).read_bytes()).hexdigest()
    assert digest == entry["sha256"].lower(), entry["file"]
inputs = json.loads((release / "run_inputs.json").read_text(encoding="utf-8-sig"))
constraint_hash = hashlib.sha256((root / f"constraints/atk_l50_{target}.fdc").read_bytes()).hexdigest()
assert constraint_hash == inputs["constraint_sha256"].lower()
# Match packaged RTL against live files and reconstruct the compilation unit.
package = root / f"build/atk_l50_{target}"
sources = (root / f"boards/atk_l50/{target}.f").read_text().splitlines()
if target in ('lcd_game', 'shooter', 'mine'):
    assert hashlib.sha256((release / 'pds_design.sv').read_bytes()).hexdigest() == inputs['combined_source_sha256'].lower()
    assert hashlib.sha256((release / 'firmware.hex').read_bytes()).hexdigest() == inputs['firmware_hex_sha256'].lower()
    app = 'game' if target == 'lcd_game' else target
    assert (release / 'firmware.hex').read_bytes() == (root / f'software/build/{app}/firmware.hex').read_bytes()
    if target == 'shooter':
        assert (release / 'shooter_font.hex').read_bytes() == (root / 'rtl/periph/shooter_font.hex').read_bytes()
    if target == 'mine':
        for font in ('mine_font.hex', 'mine_font_map.json'):
            assert (release / font).read_bytes() == (root / 'rtl/periph' / font).read_bytes(), font
        firmware = json.loads((release / 'firmware.json').read_text(encoding='utf-8-sig'))
        assert firmware['app'] == 'mine.c' and firmware['isa'] == 'rv32i'
        assert firmware['ram_bytes'] == 16384
        checks = json.loads((release / 'implementation_checks.json').read_text(encoding='utf-8-sig'))
        assert checks['timing_checked'] and checks['active_clocks']
        assert all(checks['mapped_resources'][kind] > 0 for kind in ('LUT', 'FF', 'DRM'))
source_hashes = {}
for relative in sources:
    if not relative or relative.startswith("#"):
        continue
    content = (root / relative).read_bytes()
    assert content == (package / relative).read_bytes(), f"Stale source: {relative}"
    source_hashes[relative] = hashlib.sha256(content).hexdigest()
summary = {
    "passed": True,
    "lcd_pins_checked": len(implemented),
    "all_ports_unique": len(locations),
    "touch_pins_checked": touch_implemented,
    "touch_pin_scope": 'Configured guide-derived pin map; no physical touch verification' if target == 'mine' else None,
    "source_sha256": source_hashes,
    "constraint_sha256": constraint_hash,
    "panel": "ATK-MD0700R, 800x480 (user photograph)",
    "target": target,
    "physical_display_verified": target == 'lcd',
    "physical_display_evidence": "User confirmed normal image and moving green square on 2026-11-03" if target == 'lcd' else "Pending user confirmation",
}
out = root / f"build/{target}_audit.json"
out.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print("[PASS] LCD: 30 official pin locations, unique pins, 3.3V/4mA, release hashes and staged RTL")
