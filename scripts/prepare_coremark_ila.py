"""Stage a separate CPU image with a registered, one-cycle-delayed debug probe."""
import argparse
import hashlib
import json
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--work-dir', type=Path, required=True)
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
work = a.work_dir.resolve()
assert str(work).isascii(), 'PDS requires an ASCII work path'
work.mkdir(parents=True, exist_ok=True)
sources = [s.strip() for s in (root / 'boards/atk_l50/cpu.f').read_text().splitlines()
           if s.strip() and not s.startswith('#')]
texts, hashes = [], {}
for relative in sources:
    raw = (root / relative).read_bytes()
    hashes[relative] = hashlib.sha256(raw).hexdigest()
    texts.append(f'// Source: {relative}\n' + raw.decode('utf-8-sig') + '\n')
design = '\n'.join(texts)
fields = [('commit_pc', 32), ('commit_instr', 32), ('commit_valid', 1),
          ('ex_valid', 1), ('ex_wait', 1), ('redirect', 1),
          ('dmem_valid', 1), ('dmem_ready', 1), ('dmem_write', 1),
          ('imem_valid', 1), ('imem_ready', 1), ('imem_rvalid', 1),
          ('fetch_valid', 1), ('fetch_take', 1), ('cycle_low', 8), ('retire_low', 8)]
offset = 0
schema = []
for name, width in fields:
    schema.append({'name': name, 'lsb': offset, 'width': width})
    offset += width
instrument = f'''
    // Debug image only. All fields below have the same one-cycle observation delay.
    // These registers feed no functional CPU inputs.
    (* syn_preserve=1 *) logic [7:0] ila_cycle_q, ila_retire_q;
    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            ila_probe_q <= '0;
            ila_cycle_q <= '0;
            ila_retire_q <= '0;
        end else begin
            ila_cycle_q <= ila_cycle_q + 8'd1;
            if (commit_valid_o) ila_retire_q <= ila_retire_q + 8'd1;
            ila_probe_q <= {{ila_retire_q, ila_cycle_q, fetch_take, fetch_valid,
                imem_rvalid_i, imem_ready_i, imem_valid_o,
                dmem_write_o, dmem_ready_i, dmem_valid_o,
                redirect, ex_wait, ex_valid_q, commit_valid_o,
                commit_instr_o, commit_pc_o}};
        end
    end
'''
core_start = design.index('module rv32i_core_3stage')
import_end = design.index('import rv32i_pkg::*;', core_start) + len('import rv32i_pkg::*;')
design = design[:import_end] + instrument + design[import_end:]

# ADS flattens the design and drops any register that has no load, so a probe
# declared inside the core never reached the ADF and Fabric Core Inserter
# reported Inserter-0005 for all 92 channels. Promote the probe bus to real
# hierarchy outputs and give it a live load in the top level (reduction XOR on
# one LED). Every probe net then survives synthesis. These edits exist only in
# the staged debug copy; the functional RTL files are untouched.
design = design.replace('\r\n', '\n')
probe_msb = offset - 1
core_ports = ('    output logic        halted_o,\n'
              '    output logic        trap_o\n);')
soc_ports = ('    output logic       halted_o,\n'
             '    output logic       trap_o\n);')
soc_inst = ('        .halted_o          (halted_o),\n'
            '        .trap_o            (trap_o)\n    );')
top_decl = '    logic halted, trap;\n'
top_inst = '        .gpio_o(gpio), .halted_o(halted), .trap_o(trap)\n'
top_led = '    assign led = gpio[3:0];\n'
for needle, label in ((core_ports, 'core ports'), (soc_ports, 'soc ports'),
                      (soc_inst, 'soc instance'), (top_decl, 'top decl'),
                      (top_inst, 'top instance'), (top_led, 'top led')):
    assert design.count(needle) == 1, f'{label} anchor count={design.count(needle)}'
design = design.replace(
    core_ports,
    f'    output logic        halted_o,\n'
    f'    output logic        trap_o,\n'
    f'    output logic [{probe_msb}:0] ila_probe_q\n);')
design = design.replace(
    soc_ports,
    f'    output logic       halted_o,\n'
    f'    output logic       trap_o,\n'
    f'    output logic [{probe_msb}:0] dbg_probe_o\n);')
design = design.replace(
    soc_inst,
    f'        .halted_o          (halted_o),\n'
    f'        .trap_o            (trap_o),\n'
    f'        .ila_probe_q       (dbg_probe_o)\n    );')
design = design.replace(
    top_decl,
    f'    logic halted, trap;\n    logic [{probe_msb}:0] dbg_probe;\n')
design = design.replace(
    top_inst,
    f'        .gpio_o(gpio), .halted_o(halted), .trap_o(trap),\n'
    f'        .dbg_probe_o(dbg_probe)\n')
design = design.replace(
    top_led,
    f'    assign led = gpio[3:0] ^ {{3\'b0, ^dbg_probe}};\n')
(work / 'pds_design.sv').write_text(design, encoding='utf-8')
firmware = root / 'software/build/coremark/firmware.hex'
expected = json.loads((root / 'build/board_release/cpu/coremark/run_inputs.json').read_text(encoding='utf-8-sig'))
assert hashlib.sha256(firmware.read_bytes()).hexdigest().upper() == expected['firmware_hex_sha256']
(work / 'software/build').mkdir(parents=True, exist_ok=True)
(work / 'software/build/firmware.hex').write_bytes(firmware.read_bytes())
constraint = root / 'constraints/atk_l50_vcc33.fdc'
(work / 'fixed_pins.fdc').write_bytes(constraint.read_bytes())
fic = f'''#Fabric Core Inserter Project File
Project.type=inserter
Project.device.designInputFile={work.as_posix()}/synthesize/atk_l50_top_syn.adf
Project.device.ScanChain=1
Project.device.UserJtag=0
Project.Architecture=1 1 1
Project.unit.dimension=1
Project.unit<0>.clockChannel=nt_sys_clk
Project.unit<0>.clockEdge=Rising
Project.unit<0>.ramType=1
Project.unit<0>.dataDepth=512
Project.unit<0>.dataEqualsTrigger=true
Project.unit<0>.enablePowerOnInitData=false
Project.unit<0>.enableStorageQualification=false
Project.unit<0>.triggerSequencerLevels=1
Project.unit<0>.enableMultiWindow=false
Project.unit<0>.triggerPortCount=1
Project.unit<0>.triggerMatchCount<0>=1
Project.unit<0>.triggerMatchCountWidth<0>=0
Project.unit<0>.triggerMatchType<0>=1
Project.unit<0>.triggerPortIsData<0>=true
Project.unit<0>.triggerPortWidth<0>={offset}
'''
fic += ''.join(f'Project.unit<0>.triggerChannel<0><{i}>=dbg_probe[{i}]\n' for i in range(offset))
(work / 'coremark_ila.fic').write_text(fic, encoding='ascii')
tcl = f'''set_arch -family Logos -device PGL25G -speedgrade -6 -package MBG324
add_design {work.as_posix()}/pds_design.sv
add_constraint {work.as_posix()}/fixed_pins.fdc
add_fic {work.as_posix()}/coremark_ila.fic
compile -system_verilog -top_module atk_l50_top -loop_limit 10000
synthesize -ads
dev_map
pnr
report_timing -delay_type min_max -max_path 10
puts COREMARK_ILA_TIMING_COMPLETE
'''
(work / 'build.tcl').write_text(tcl, encoding='ascii')
manifest = {'source_hashes': hashes, 'debug_probe_width': offset, 'fields': schema,
            'observation_delay_cycles': 1, 'depth': 512,
            'firmware_hex_sha256': hashlib.sha256(firmware.read_bytes()).hexdigest(),
            'constraint_sha256': hashlib.sha256(constraint.read_bytes()).hexdigest(),
            'combined_debug_source_sha256': hashlib.sha256((work / 'pds_design.sv').read_bytes()).hexdigest(),
            'description': 'Separate instrumented image; functional RTL files unchanged.'}
(work / 'probe_schema.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
print(f'ILA_STAGED width={offset} depth=512 work={work}')
