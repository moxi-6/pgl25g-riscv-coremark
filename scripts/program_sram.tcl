# SRAM configuration only. Never erases/programs external Flash or eFuse.
puts "SRAM_PROGRAM_BEGIN"
cfg_set_tcl_break -flag true
cfg_connect -ip 127.0.0.1 -port 65420
cfg_set_cable_property -index 0 -freq $env(L50_JTAG_FREQUENCY)
cfg_scan_chain
cfg_read_device_property -mode 0 -device_index 0
cfg_assign_file -file $env(L50_SRAM_FILE) -device_index 0
# Non-ISC readback avoids the same stateful output-disable path as ISC program.
# Set it explicitly even for VerifyOnly; do not inherit a tool/session default.
cfg_set_device_property -device_index 0 -readback 1
if {$env(L50_SRAM_VERIFY_ONLY) ne "1"} {
    cfg_set_device_property -device_index 0 -program $env(L50_SRAM_PROGRAM_MODE)
    cfg_program -device_index 0
}
puts "STATUS_BEFORE_VERIFY"
if {$env(L50_SRAM_SKIP_STATUS) ne "1"} {
    cfg_read_device_property -mode 3 -device_index 0
}
if {$env(L50_SRAM_SKIP_VERIFY) ne "1"} {
    cfg_verify -device_index 0
}
puts "STATUS_AFTER_OPERATION"
if {$env(L50_SRAM_SKIP_STATUS) ne "1"} {
    cfg_read_device_property -mode 3 -device_index 0
    # STATUSR is also reachable as raw register address 9. That path reports the
    # same 32-bit word, and it is the channel that exposes the gouten bit
    # independently of the high-level property read. Read-only: writes to address
    # 9 are silently ignored by the device, so this cannot disturb the config.
    if {$env(L50_SRAM_READ_REGISTER) eq "1"} {
        puts "RAW_STATUS_REGISTER"
        cfg_read_register -address 9
    }
}
cfg_disconnect
puts "SRAM_OPERATION_COMPLETE"
cfg_close
