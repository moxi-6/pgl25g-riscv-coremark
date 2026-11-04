# Read-only configuration audit. Addresses are explicitly hexadecimal.
puts "JTAG_IDENTIFY_BEGIN"
cfg_set_tcl_break -flag true
cfg_connect -ip 127.0.0.1 -port 65420
cfg_set_cable_property -index 0 -freq 1Mhz
cfg_scan_chain
cfg_read_device_property -mode 0 -device_index 0
puts "STATUS_BY_PROPERTY"
cfg_read_device_property -mode 3 -device_index 0
puts "STATUS_REGISTER_0x09"
cfg_read_register -address 0x09 -device_index 0
puts "OPTION0_REGISTER_0x19"
cfg_read_register -address 0x19 -device_index 0
puts "CONTROL0_REGISTER_0x03"
cfg_read_register -address 0x03 -device_index 0
puts "CONTROL1_REGISTER_0x04"
cfg_read_register -address 0x04 -device_index 0
cfg_disconnect
puts "JTAG_IDENTIFY_END"
cfg_close
