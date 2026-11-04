#!/usr/bin/env sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="$ROOT_DIR/build"
mkdir -p "$BUILD_DIR"
cd "$ROOT_DIR"

run_test() {
    rm -f "$BUILD_DIR/$1.vvp"
    iverilog -g2012 -s "$1" -o "$BUILD_DIR/$1.vvp" \
        -c boards/atk_l50/cpu.f rtl/top/atk_l50_bringup.sv "sim/$1.sv" \
        2> "$BUILD_DIR/$1.compile.log"
    vvp "$BUILD_DIR/$1.vvp" > "$BUILD_DIR/$1.run.log" 2>&1
    cat "$BUILD_DIR/$1.run.log"
    if ! grep -F -q "$2" "$BUILD_DIR/$1.run.log"; then
        echo "[FAIL] $1: missing PASS marker" >&2
        exit 1
    fi
}

if command -v riscv32-unknown-elf-gcc >/dev/null 2>&1; then
    RISCV_TOOLCHAIN=riscv32-unknown-elf-
elif command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then
    RISCV_TOOLCHAIN=riscv64-unknown-elf-
elif [ -f software/build/firmware.hex ] && [ -f software/build/runtime_test/firmware.hex ] && [ -f software/build/perf_test/firmware.hex ]; then
    RISCV_TOOLCHAIN=
    echo "[INFO] Using existing main/runtime/perf HEX; firmware NOT rebuilt." >&2
else
    echo "[FAIL] No RISC-V toolchain and no existing firmware.hex." >&2
    exit 1
fi
if [ -n "$RISCV_TOOLCHAIN" ]; then
    make -C "$ROOT_DIR/software" RISCV_PREFIX="$RISCV_TOOLCHAIN"
    make -C "$ROOT_DIR/software" RISCV_PREFIX="$RISCV_TOOLCHAIN" APP=runtime_test.c BUILD_DIR=build/runtime_test
    make -C "$ROOT_DIR/software" RISCV_PREFIX="$RISCV_TOOLCHAIN" APP=perf_test.c BUILD_DIR=build/perf_test
fi

run_test tb_alu '[PASS] rv32i_alu'
run_test tb_core '[PASS] rv32i_core_3stage'
run_test tb_core_wait '[PASS] rv32i_core_wait'
run_test tb_sync_memory '[PASS] sync_memory'
run_test tb_core_sync '[PASS] rv32i_core_sync'
run_test tb_soc_memory '[PASS] rv32i_soc_memory'
run_test tb_soc_perf '[PASS] soc_perf'
run_test tb_bringup '[PASS] atk_l50_bringup'
run_test tb_soc '[PASS] rv32i_soc'
run_test tb_board_cpu '[PASS] atk_l50_cpu'
run_test tb_runtime '[PASS] c_runtime'
run_test tb_perf_firmware '[PASS] perf_firmware'
echo "All 12 simulations passed."
