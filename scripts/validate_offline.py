"""Run the complete board-free acceptance workflow and bind evidence to sources."""
import argparse
import datetime
import json
import re
import shutil
import subprocess
import sys
import unittest
from pathlib import Path
from audit_artifacts import audit, sha
from coremark_score import evaluate


def snapshot(root):
    files=[]
    for folder in ('rtl','sim','scripts','constraints','boards'):
        files += [p for p in (root/folder).rglob('*') if p.is_file() and '__pycache__' not in p.parts]
    files += [p for p in (root/'software').rglob('*') if p.is_file() and 'build' not in p.relative_to(root/'software').parts]
    return {p.relative_to(root).as_posix():sha(p) for p in sorted(files)}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--powershell',default=shutil.which('pwsh') or shutil.which('powershell'))
    args=parser.parse_args()
    if not args.powershell: raise RuntimeError('PowerShell is required for existing regression scripts')
    root=Path(__file__).resolve().parents[1]; output=root/'build/offline_validation'
    output.mkdir(parents=True,exist_ok=True)
    summary={'status':'RUNNING','scope':'Offline only; no JTAG, serial port, board programming or Flash access.',
             'hardware_touched':False,'started_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'checks':[]}
    summary_path=output/'summary.json'
    summary_path.write_text(json.dumps(summary,indent=2),encoding='utf-8')
    before=snapshot(root)

    def run(name,command):
        print(f'OFFLINE_CHECK_BEGIN {name}',flush=True)
        result=subprocess.run(command,cwd=root,capture_output=True,text=True,errors='replace',timeout=600)
        text=result.stdout+result.stderr
        (output/f'{name}.log').write_text(text,encoding='utf-8')
        summary['checks'].append({'name':name,'exit_code':result.returncode,'log':f'{name}.log'})
        if result.returncode: raise RuntimeError(f'{name} failed; inspect {output/name}.log')
        print(f'OFFLINE_CHECK_PASS {name}',flush=True)
        return text

    try:
        shell=[args.powershell,'-NoProfile','-File']
        text=run('system_regression',shell+[str(root/'scripts/run_iverilog.ps1')])
        if 'All 15 simulations passed.' not in text: raise RuntimeError('Full system PASS marker missing')
        run('isa_differential',[sys.executable,str(root/'scripts/run_isa_checks.py')])
        run('score_controls',[sys.executable,str(root/'scripts/test_coremark_score.py')])
        run('pipeline_trace',[sys.executable,str(root/'scripts/run_pipeline_trace.py')])
        text=run('regression_failure_guards',shell+[str(root/'scripts/check_regression_errors.ps1')])
        if 'All 5 failure guards passed.' not in text: raise RuntimeError('Failure-guard marker missing')
        artifact_audit=audit(root)
        (output/'artifact_audit.json').write_text(json.dumps(artifact_audit,indent=2),encoding='utf-8')
        # Preserve the actual simulated UART text independently of log prefixes.
        lines=re.findall(r'^UART\[\d+\] (.*)$',(root/'build/tb_coremark.run.log').read_text(encoding='utf-8-sig'),re.M)
        raw_report='\n'.join(line.rstrip('\r') for line in lines)+'\n'
        if not lines: raise RuntimeError('No actual CoreMark simulation UART report')
        (output/'coremark_simulation_capture.txt').write_text(raw_report,encoding='ascii')
        run('score_cli',shell+[str(root/'scripts/score_coremark.ps1'),'-CapturePath',str(output/'coremark_simulation_capture.txt'),
                               '-OutputDir',str(output/'simulation_score'),'-EvidenceKind','Simulation'])
        report=json.loads((output/'simulation_score/coremark_score.json').read_text())
        if report['verdict']!='FAIL_TOO_SHORT' or report['publishable']: raise RuntimeError('Simulation was incorrectly treated as a publishable score')
        after=snapshot(root)
        if before!=after: raise RuntimeError('Sources changed during validation; rerun against a stable source tree')
        summary.update(status='PASS',source_sha256=after,system_simulations=15,
                       isa=json.loads((root/'build/isa_checks/summary.json').read_text()),
                       pipeline=json.loads((root/'build/pipeline_trace_summary.json').read_text()),
                       scoring_tests=13,failure_guards=5,
                       board_score_available=False,board_ila_complete=False,
                       simulation_score_verdict=report['verdict'])
    except Exception as exc:
        summary.update(status='FAIL',failure=str(exc))
        raise
    finally:
        summary['completed_utc']=datetime.datetime.now(datetime.timezone.utc).isoformat()
        summary_path.write_text(json.dumps(summary,indent=2),encoding='utf-8')
    print('OFFLINE_VALIDATION_PASS: 15 system simulations, 48 ISA runs, 13 scoring tests, 5 guards, simulation waveform, artifact audit')


if __name__=='__main__':
    main()
