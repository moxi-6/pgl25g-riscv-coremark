# Third-party notices

The repository MIT license applies to original project contributions. It does not replace licenses, trademark terms or redistribution conditions belonging to third parties.

## EEMBC CoreMark

`software/coremark/` contains EEMBC benchmark sources and a local bare-metal port. Preserve the copyright and attribution headers in the upstream algorithm files. CoreMark and EEMBC are marks of their respective owners.

The checked-in algorithm files carry the 2009 EEMBC/CoreMark release headers. Their accompanying `software/coremark/LICENSE.md` is titled **COREMARK® ACCEPTABLE USE AGREEMENT** and contains the benchmark/trademark conditions. This repository preserves that upstream text and does not relicense those files under MIT or assert an Apache-2.0 license for this source snapshot.

Source reference: <https://github.com/eembc/coremark>. Follow the license and reporting rules belonging to the exact upstream revision being used. Benchmark algorithms and expected CRCs remain identifiable separately from the board port. Single-iteration simulation projections are not official scores meeting the minimum execution-time rule.

Local integration files include `core_portme.c`, `core_portme.h`, `board_coremark_config.h`, `ee_printf.c` and `softmath.c`; their presence does not relicense the upstream algorithm files.

## Chinese display glyphs

The existing `rtl/periph/mine_font.hex` and `shooter_font.hex` were rasterized from **Microsoft YaHei**, using the installed Windows font `msyh.ttc`. The generation scripts use Pillow. The font binaries are not bundled.

Microsoft YaHei is not covered by the repository MIT license. The generated glyph arrays and FPGA images embedding them are distributed as application data; the font binaries are not bundled. Regenerating the glyphs from a font with an explicit redistributable license changes the display ROM and requires rebuilding the affected FPGA release.

The procedural 5×7 numeric glyphs and gameplay rendering logic are separate from the rasterized Chinese font assets.

## Build and verification tools

RISC-V GCC/binutils, Python, Pillow, Icarus Verilog, PowerShell, Pango Design Suite, vendor simulation primitives and USB drivers are external dependencies. They are not sublicensed by the project MIT license. Tool installers, proprietary primitive libraries, license files and driver packages are not part of the source release.

PDS-generated bitstreams and reports are engineering outputs; distribution of the vendor tools or their libraries remains governed by the vendor's terms.
