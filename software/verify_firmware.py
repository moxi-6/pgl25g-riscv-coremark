"""Validate a bare-metal ELF32 RV32I image and emit little-endian word HEX.

Uses only Python's standard library. LMA is ROM, while .data VMA is RAM.
This is an instruction-encoding/build check, not an ISA compliance test.
"""
import argparse
import hashlib
import json
import re
from pathlib import Path
import struct


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(build, app, extra_sources=(), isa='rv32i', ram_bytes=None):
    require(isa in ('rv32i', 'rv32i_zmmul','rv32i_zba_zbb_zmmul'), 'Unsupported ISA configuration')
    elf = (build / 'firmware.elf').read_bytes()
    binary = (build / 'firmware.bin').read_bytes()
    require(elf[:7] == b'\x7fELF\x01\x01\x01', 'Expected little-endian ELF32')
    fields = struct.unpack_from('<HHIIIIIHHHHHH', elf, 16)
    etype, machine, _, entry, phoff, shoff, flags, _, phsize, phnum, shsize, shnum, shstr = fields
    require(etype == 2 and machine == 243 and entry == 0, 'Expected executable RISC-V ELF, entry=0')
    require(flags == 0, f'Expected RV32I soft-float ABI, no compressed instructions; ELF flags={flags:#x}')
    require(0 < len(binary) <= 65536 and len(binary) % 4 == 0, 'ROM image must fit aligned 64 KiB')
    sections = [struct.unpack_from('<IIIIIIIIII', elf, shoff + i*shsize) for i in range(shnum)]
    names_section = sections[shstr]
    names = elf[names_section[4]:names_section[4] + names_section[5]]

    def string(table, offset):
        return table[offset:table.index(b'\0', offset)].decode('utf-8')

    named = {string(names, s[0]): s for s in sections}
    text = named['.text']
    require(text[3] == 0 and text[5] % 4 == 0, 'Invalid text layout')
    code = elf[text[4]:text[4] + text[5]]
    allowed = {0x03, 0x0f, 0x13, 0x17, 0x23, 0x33, 0x37, 0x63, 0x67, 0x6f, 0x73}
    for offset in range(0, len(code), 4):
        word = struct.unpack_from('<I', code, offset)[0]
        op, f3, f7 = word & 127, (word >> 12) & 7, word >> 25
        rs2=(word>>20)&31
        bitmanip = isa=='rv32i_zba_zbb_zmmul' and (
            (op==0x33 and ((f7==0x10 and f3 in (2,4,6)) or
                (f7==0x20 and f3 in (4,6,7)) or (f7==5 and f3 in (4,5,6,7)) or
                (f7==0x30 and f3 in (1,5)) or (f7==4 and f3==4 and rs2==0))) or
            (op==0x13 and ((f3==1 and word>>20 in (0x600,0x601,0x602,0x604,0x605)) or
                (f3==5 and (word>>20 in (0x287,0x698) or f7==0x30)))))
        require(word & 3 == 3 and op in allowed, f'Unsupported instruction {word:08x} at {offset:#x}')
        if op == 0x33:
            require(f7 == 0 or (f7 == 0x20 and f3 in (0, 5)) or
                    ('zmmul' in isa and f7 == 1 and f3 in (0, 1, 2, 3)) or bitmanip,
                    'Unsupported multiply/divide or reserved OP instruction')
        if op == 0x13 and f3 in (1, 5):
            require(f7 == 0 or (f3 == 5 and f7 == 0x20) or bitmanip, 'Reserved shift instruction')
        if op == 0x03:
            require(f3 in (0, 1, 2, 4, 5), 'Unsupported load size')
        if op == 0x23:
            require(f3 in (0, 1, 2), 'Unsupported store size')
        if op == 0x63:
            require(f3 in (0, 1, 4, 5, 6, 7), 'Reserved branch instruction')
        if op in (0x67, 0x0f):
            require(f3 == 0, 'Unsupported JALR/FENCE variant')
        if op == 0x73:
            require(word == 0x00100073, 'Only EBREAK is implemented, not ECALL/CSR')

    symbols = {}
    for s in sections:
        if s[1] == 2:  # SHT_SYMTAB
            strings = sections[s[6]]
            table = elf[strings[4]:strings[4] + strings[5]]
            for pos in range(s[4], s[4] + s[5], s[9]):
                name, value, _, _, _, _ = struct.unpack_from('<IIIBBH', elf, pos)
                if name:
                    symbols[string(table, name)] = value
    needed = ('__data_start', '__data_end', '__data_load_start', '__bss_start', '__bss_end', '_stack_top', '_stack_bottom')
    build_flags = (build / 'build_flags.txt').read_text().strip()
    # This GCC's LTO output drops C STT_FILE names (including ltrans names).
    # For LTO, source identity comes from the freshly generated build manifest;
    # the ELF still must contain the executable entry and main. Non-LTO keeps
    # the stronger original translation-unit-name check.
    require(Path(app).name in symbols or
            ('-flto' in build_flags.split() and 'main' in symbols and '_start' in symbols),
            'ELF source file differs from selected APP/LTO build')
    require(all(n in symbols for n in needed), 'Missing startup/linker symbols')
    data_start, data_end, data_load, bss_start, bss_end, stack_top, stack_bottom = (symbols[n] for n in needed)
    # The ELF, requested build size, and physical data-memory alias must agree.
    # Reading the linker symbol also catches a defsym placed after the script,
    # which GNU ld could otherwise resolve too late to affect MEMORY LENGTH.
    ram_base = 0x40000000
    linked_ram_bytes = symbols.get('__ram_size')
    require(linked_ram_bytes in (8192, 16384), 'Missing/unsupported __ram_size linker symbol')
    require(ram_bytes is None or linked_ram_bytes == ram_bytes, 'ELF RAM size differs from RAM_BYTES')
    require(data_start == ram_base and stack_top - data_start == linked_ram_bytes,
            'RAM alias or stack top differs from declared RAM size')
    require(ram_base <= data_start <= data_end <= bss_start <= bss_end <= stack_bottom < stack_top,
            'RAM layout/stack reservation invalid')
    require(all(symbols[n] % 4 == 0 for n in needed), 'Startup copy/clear bounds must be word aligned')
    require(stack_top % 16 == 0 and stack_top - stack_bottom == 1024, 'Stack ABI alignment/reservation invalid')
    data_lma = data_load - 0x20000000
    require(text[5] <= data_lma and data_lma + data_end - data_start <= len(binary), 'Invalid ROM data LMA')
    for i in range(phnum):
        ptype, pos, vaddr, paddr, size, _, _, _ = struct.unpack_from('<IIIIIIII', elf, phoff + i*phsize)
        if ptype == 1 and size:
            require(paddr + size <= len(binary), 'Loadable section outside ROM image')
            require(binary[paddr:paddr+size] == elf[pos:pos+size], 'BIN does not match ELF load segment')
    if data_end > data_start:
        data = named['.data']
        require(data[3] == data_start and data[5] == data_end - data_start, 'Data symbols/section differ')
        require(binary[data_lma:data_lma+data[5]] == elf[data[4]:data[4]+data[5]], 'Data initializer mismatch')

    (build / 'firmware.hex').write_text('@00000000\n' + ''.join(
        f'{struct.unpack_from("<I", binary, i)[0]:08x}\n' for i in range(0, len(binary), 4)), encoding='ascii')
    # Every input that can change the image must appear here, otherwise the
    # packaging step could accept stale artifacts for a multi-file image.
    sources = ['start.S', 'linker.ld', 'Makefile', 'verify_firmware.py', app]
    sources += [str(name) for name in extra_sources]
    sources += sorted(str(path) for path in Path('.').glob('*.h'))
    # Headers for a multi-file image can live outside the software root, so the
    # directory of every extra source is swept as well. Without this, the
    # coremark image would pin coremark/*.c but not coremark/*.h, and editing a
    # port header would leave the manifest's hashes looking valid.
    for extra in extra_sources:
        extra_dir = Path(extra).parent
        if str(extra_dir) not in ('', '.'):
            sources += sorted(str(path) for path in extra_dir.glob('*.h'))
    sources = list(dict.fromkeys(sources))
    for source in sources:
        require(Path(source).is_file(), f'Missing firmware source: {source}')
    result = {
        'app': app, 'isa': isa, 'abi': 'ilp32', 'entry': entry,
        'rom_bytes': len(binary), 'text_instructions': len(code)//4,
        'ram_bytes': linked_ram_bytes, 'ram_base': ram_base,
        'stack_reserved_bytes': stack_top-stack_bottom,
        'ram_free_before_stack_bytes': stack_bottom-bss_end,
        'data_bytes': data_end-data_start, 'bss_bytes': bss_end-bss_start,
        'symbols': {n: symbols[n] for n in (*needed, '__ram_size')},
        'toolchain': (build / 'toolchain.txt').read_text().splitlines()[0],
        'compiler_flags': build_flags,
        'source_sha256': {s: sha256(Path(s)) for s in sources},
        'artifact_sha256': {n: sha256(build / n) for n in ('firmware.elf', 'firmware.bin', 'firmware.hex')},
    }
    if app == 'coremark/core_main.c':
        clock_match = re.search(r'^#define\s+BOARD_CLOCK_HZ\s+(\d+)u?\s*$',
                               Path('coremark/board_coremark_config.h').read_text(), re.M)
        require(clock_match is not None, 'Missing literal CoreMark board clock configuration')
        result['clock_hz'] = int(clock_match[1])
    (build / 'firmware.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'[PASS] firmware app={app} rom={len(binary)} bytes ram={linked_ram_bytes} data={data_end-data_start} bss={bss_end-bss_start} {isa}/ILP32')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--app', required=True)
    parser.add_argument('--isa', choices=('rv32i', 'rv32i_zmmul','rv32i_zba_zbb_zmmul'), default='rv32i')
    parser.add_argument('--ram-bytes', type=int, choices=(8192, 16384))
    parser.add_argument('--sources', default='',
                        help='Whitespace-separated extra inputs (paths relative to the software root).')
    args = parser.parse_args()
    verify(args.build_dir, args.app, args.sources.split(), args.isa, args.ram_bytes)
