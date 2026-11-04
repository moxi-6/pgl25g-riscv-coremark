"""Negative checks against real compiled ELF/BIN fixtures, never the originals."""
from pathlib import Path
import shutil
import struct
import tempfile
from verify_firmware import verify

source = Path('build')
for case in ('compressed_flag', 'mul_instruction', 'bin_mismatch'):
    with tempfile.TemporaryDirectory(prefix='firmware_guard_', dir=source) as folder:
        target = Path(folder)
        for name in ('firmware.elf', 'firmware.bin', 'toolchain.txt'):
            shutil.copyfile(source / name, target / name)
        elf = bytearray((target / 'firmware.elf').read_bytes())
        if case == 'compressed_flag':
            struct.pack_into('<I', elf, 36, 1)  # EF_RISCV_RVC
            (target / 'firmware.elf').write_bytes(elf)
        elif case == 'mul_instruction':
            shoff = struct.unpack_from('<I', elf, 32)[0]
            shsize, shnum = struct.unpack_from('<HH', elf, 46)
            for n in range(shnum):
                section = struct.unpack_from('<IIIIIIIIII', elf, shoff+n*shsize)
                if section[2] & 4:  # Executable section
                    struct.pack_into('<I', elf, section[4], 0x02000033)
                    break
            (target / 'firmware.elf').write_bytes(elf)
        else:
            binary = bytearray((target / 'firmware.bin').read_bytes())
            binary[-1] ^= 1
            (target / 'firmware.bin').write_bytes(binary)
        try:
            verify(target, 'main.c')
        except ValueError as error:
            print(f'[PASS] firmware_guard {case}: {error}')
        else:
            raise AssertionError(f'Corrupt fixture was accepted: {case}')
