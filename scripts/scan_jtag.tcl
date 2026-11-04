# Identification only: no programming, erase, reset or Flash commands.
puts "JTAG_IDENTIFY_BEGIN"
cfg_set_tcl_break -flag true
cfg_connect -ip 127.0.0.1 -port 65420
cfg_set_cable_property -index 0 -freq 1Mhz
cfg_scan_chain
cfg_read_device_property -mode 0 -device_index 0
cfg_disconnect
puts "JTAG_IDENTIFY_END"
cfg_close
