RISCV_PREFIX ?= riscv64-unknown-elf-
APP ?= main.c
# Multi-file images (CoreMark) pass their extra translation units and any
# headers outside the software root through these two variables.
EXTRA_SRCS ?=
EXTRA_HDRS ?=
# Extra -D flags for a specific build. Only the simulation uses this, to pin
# CoreMark to a small fixed iteration count; the board image leaves it empty so
# the image takes CoreMark's own ~10 s auto-calibrated run.
DEFS ?=
BUILD_DIR ?= build
MARCH ?= rv32i
RAM_BYTES ?= 16384
OPT ?= -O2
RELAX ?= 0
EXTRA_CFLAGS ?=
RELAX_FLAG := $(if $(filter 1,$(RELAX)),-mrelax,-mno-relax)
LINK_RELAX_FLAG := $(if $(filter 1,$(RELAX)),--relax,--no-relax)
CC := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy
OBJDUMP := $(RISCV_PREFIX)objdump
PYTHON ?= python3

CFLAGS := -march=$(MARCH) -mabi=ilp32 $(RELAX_FLAG) -msmall-data-limit=0 $(OPT) $(EXTRA_CFLAGS) \
    -ffreestanding -fno-builtin -fno-pic -fno-pie -fno-stack-protector \
    -ffunction-sections -fdata-sections -fno-asynchronous-unwind-tables -Wall -Wextra -Werror
# EEMBC's core_list_join.c reads info.data16 in core_list_find() along a path GCC
# cannot prove is initialised, which trips -Werror=maybe-uninitialized. It is
# unmodified upstream source, so the warning is relaxed for that translation
# unit alone; the exemption is keyed to the exact filename so it cannot silently
# cover a new warning in project code.
ifneq (,$(findstring coremark/core_list_join.c,$(EXTRA_SRCS)))
CFLAGS += -Wno-error=maybe-uninitialized
endif
LDFLAGS := -nostdlib -nostartfiles -Wl,--defsym,__ram_bytes=$(RAM_BYTES) -Wl,-T,linker.ld -Wl,$(LINK_RELAX_FLAG),--gc-sections,--build-id=none \
    -Wl,-Map,$(BUILD_DIR)/firmware.map

# Multi-file images place their headers outside the software root, so the
# include path has to reach into that tree. $(dir ...) yields "coremark/",
# which is what -I wants. The software root itself is added first so that
# shared headers such as perf.h resolve from the same place for every image.
CFLAGS += -I. $(sort $(addprefix -I,$(dir $(EXTRA_HDRS))))
CFLAGS += $(DEFS)
BUILD_FLAGS := $(CFLAGS)
CFLAGS += -DFLAGS_STR='"$(BUILD_FLAGS)"'

.PHONY: all verify clean FORCE
all: verify

$(BUILD_DIR):
	mkdir -p "$@"

# These small firmware images are always rebuilt, avoiding stale output when
# callers switch APP or toolchain while retaining the same BUILD_DIR.
$(BUILD_DIR)/firmware.elf: start.S $(APP) $(EXTRA_SRCS) $(EXTRA_HDRS) $(wildcard *.h) linker.ld Makefile FORCE | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) start.S "$(APP)" $(EXTRA_SRCS) -o "$@"
	$(CC) --version > "$(BUILD_DIR)/toolchain.txt"
	printf '%s\n' '$(BUILD_FLAGS)' > "$(BUILD_DIR)/build_flags.txt"

$(BUILD_DIR)/firmware.bin: $(BUILD_DIR)/firmware.elf
	$(OBJCOPY) -O binary "$<" "$@"

$(BUILD_DIR)/firmware.dis: $(BUILD_DIR)/firmware.elf
	$(OBJDUMP) -d -M no-aliases,numeric "$<" > "$@"

verify: $(BUILD_DIR)/firmware.bin $(BUILD_DIR)/firmware.dis verify_firmware.py
	$(PYTHON) verify_firmware.py --build-dir "$(BUILD_DIR)" --app "$(APP)" --sources "$(EXTRA_SRCS) $(EXTRA_HDRS)" --isa "$(MARCH)" --ram-bytes "$(RAM_BYTES)"

clean:
	rm -f "$(BUILD_DIR)/firmware.elf" "$(BUILD_DIR)/firmware.bin" "$(BUILD_DIR)/firmware.hex" \
        "$(BUILD_DIR)/firmware.dis" "$(BUILD_DIR)/firmware.map" "$(BUILD_DIR)/firmware.json" "$(BUILD_DIR)/toolchain.txt"
