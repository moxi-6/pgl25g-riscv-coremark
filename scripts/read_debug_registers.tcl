# Supported read-only diagnostic modes; never write RDRDC or disable JTAG.
# Pin-output mode 5 needs an undocumented -value parameter and is not used.
puts "JTAG_IDENTIFY_BEGIN"
cfg_set_tcl_break -flag true
cfg_connect -ip 127.0.0.1 -port 65420
cfg_set_cable_property -index 0 -freq 1Mhz
cfg_scan_chain
cfg_read_device_property -mode 0 -device_index 0
puts "STATUS_BEFORE_DIAGNOSTICS"
cfg_read_device_property -mode 3 -device_index 0
puts "DEBUG_REGISTER_READ"
cfg_debug_operate -mode 2 -device_index 0
puts "INSTRUCTION_REGISTER_READ"
cfg_debug_operate -mode 3 -device_index 0
# Mode 4 is not supported on the connected PGL25G (JtagServer-4004).
puts "STATUS_AFTER_DIAGNOSTICS"
cfg_read_device_property -mode 3 -device_index 0
cfg_disconnect
puts "JTAG_IDENTIFY_END"
cfg_close
