"""Generate and summarize a bounded simulation waveform, not a hardware ILA trace."""
import csv
import hashlib
import json
import shutil
import subprocess
from pathlib import Path


def main():
    root=Path(__file__).resolve().parents[1]
    build=root/'build'; build.mkdir(exist_ok=True)
    local=root.parent/'tools/iverilog/bin'
    cc=str(local/'iverilog.exe') if (local/'iverilog.exe').exists() else shutil.which('iverilog')
    vvp=str(local/'vvp.exe') if (local/'vvp.exe').exists() else shutil.which('vvp')
    sources=[f'rtl/core/{n}.sv' for n in ('rv32i_pkg','rv32i_alu','rv32i_imm_gen','rv32i_regfile','rv32i_decoder','rv32i_core_3stage')]
    sources+=['sim/tb_pipeline_trace.sv']
    binary=build/'tb_pipeline_trace.vvp'
    result=subprocess.run([cc,'-g2012','-s','tb_pipeline_trace','-o',str(binary),*sources],cwd=root,capture_output=True,text=True)
    (build/'tb_pipeline_trace.compile.log').write_text(result.stdout+result.stderr,encoding='utf-8')
    if result.returncode: raise RuntimeError('Pipeline trace compile failed')
    result=subprocess.run([vvp,str(binary)],cwd=root,capture_output=True,text=True,timeout=60)
    (build/'tb_pipeline_trace.run.log').write_text(result.stdout+result.stderr,encoding='utf-8')
    if result.returncode or '[PASS] rv32i_core_sync' not in result.stdout: raise RuntimeError('Pipeline trace test failed')
    rows=list(csv.DictReader((build/'pipeline_trace.csv').open()))
    modes=[]
    for mode in range(3):
        selected=[r for r in rows if r['rst_n']=='1' and r['scenario']=='0' and r['mode']==str(mode) and r['halted']=='0']
        commits=sum(r['commit']=='1' for r in selected)
        if commits!=28: raise RuntimeError(f'Unexpected trace commits in mode {mode}: {commits}')
        modes.append({'mode':mode,'sampled_active_cycles':len(selected),'commits':commits,
                      'cpi_including_start_and_stop':len(selected)/commits,
                      'data_wait_cycles':sum(r['data_wait']=='1' for r in selected),
                      'fetch_backpressure_cycles':sum(r['fetch_request']=='1' and r['fetch_ready']=='0' for r in selected),
                      'redirect_events':sum(r['redirect']=='1' for r in selected)})
    files=('pipeline_trace.csv','pipeline_trace.vcd')
    summary={'status':'PASS','evidence_kind':'Simulation','program':'tb_core_sync scenario 0, not CoreMark',
             'window':'negedge samples after reset release and before halt; includes startup/termination overhead',
             'modes':modes,'files_sha256':{n:hashlib.sha256((build/n).read_bytes()).hexdigest() for n in files},
             'scope':'Waiting categories may overlap. These are simulation cycles, not board frequency or hardware ILA measurements.'}
    (build/'pipeline_trace_summary.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
    print(json.dumps(summary,indent=2))


if __name__=='__main__':
    main()
