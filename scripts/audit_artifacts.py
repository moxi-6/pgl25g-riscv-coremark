"""Read-only consistency audit for existing firmware and CPU release artifacts."""
import hashlib
import json
import re
from pathlib import Path


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def audit(root):
    software=root/'software'; firmware=[]; releases=[]
    for name in ('main','runtime_test','perf_test','perf_report','coremark','coremark_sim','game','game_sim'):
        directory=software/'build' if name=='main' else software/'build'/name
        manifest=load(directory/'firmware.json')
        for relative,expected in manifest['source_sha256'].items():
            if sha(software/relative)!=expected.lower(): raise RuntimeError(f'Stale {name} source: {relative}')
        for relative,expected in manifest['artifact_sha256'].items():
            if sha(directory/relative)!=expected.lower(): raise RuntimeError(f'Corrupt {name} artifact: {relative}')
        firmware.append({'app':name,'hex_sha256':sha(directory/'firmware.hex'),
                         'rom_bytes':manifest['rom_bytes'],'data_bytes':manifest['data_bytes'],
                         'bss_bytes':manifest['bss_bytes'],'toolchain':manifest['toolchain']})
    if sha(software/'build/coremark/sim_firmware.hex')!=sha(software/'build/coremark_sim/firmware.hex'):
        raise RuntimeError('Dedicated CoreMark simulation image differs from its verified build')
    for app in ('coremark','perf_report','game'):
        directory=root/'build/board_release/cpu'/app
        release=load(directory/'release.json')
        if release['firmware_app']!=app or release['device']!='PGL25G': raise RuntimeError('Unexpected release identity')
        for entry in release['files']:
            if sha(directory/entry['file'])!=entry['sha256'].lower(): raise RuntimeError(f'Release hash mismatch: {app}/{entry["file"]}')
        inputs=load(directory/'run_inputs.json')
        if inputs.get('firmware_hex_sha256','').lower()!=sha(software/'build'/app/'firmware.hex'):
            raise RuntimeError(f'{app}: release lacks matching firmware provenance')
        timing=(directory/'timing.rtr').read_text(encoding='utf-8-sig')
        if 'All Constraints Met.' not in timing: raise RuntimeError(f'{app}: timing did not pass')
        log=(directory/'pds_bitstream.log').read_text(encoding='utf-8-sig')
        resources={}
        for label,capacity in (('LUT',22560),('FF',33840),('DRM',60)):
            match=re.search(r'\|\s*'+label+r'\s*\|\s*(\d+)\s*\|\s*'+str(capacity)+r'\s*\|',log)
            resources[label]=int(match[1]) if match else None
        releases.append({'app':app,'bitstream_sha256':sha(directory/'atk_l50_top.sbit'),
                         'firmware_hex_sha256':inputs['firmware_hex_sha256'].lower(),
                         'device':'PGL25G','constraint_profile':release['constraint_profile'],
                         'timing_report_pass':True,'resources':resources,
                         'board_validated_in_this_audit':False})
    return {'status':'PASS','firmware':firmware,'releases':releases,
            'scope':'Read-only file consistency and existing PDS reports; no synthesis rerun or hardware execution.'}


if __name__=='__main__':
    print(json.dumps(audit(Path(__file__).resolve().parents[1]),indent=2))
