# UG020005 V2.3, pp.73-75: CMDR address 2, SWAKEUP command 7.
# Restarts volatile wakeup sequencing only. No bitstream, Flash or eFuse write.
puts "JTAG_IDENTIFY_BEGIN"
cfg_set_tcl_break -flag true
cfg_connect -ip 127.0.0.1 -port 65420
cfg_set_cable_property -index 0 -freq 1Mhz
cfg_scan_chain
cfg_read_device_property -mode 0 -device_index 0
puts "WAKEUP_STATUS_BEFORE"
cfg_read_device_property -mode 3 -device_index 0
puts "OPTION0_BEFORE"
cfg_read_register -address 0x19 -device_index 0
cfg_write_register -address 2 -value 7 -device_index 0
cfg_set_delay_time -time 1
puts "WAKEUP_STATUS_AFTER"
cfg_read_device_property -mode 3 -device_index 0
cfg_disconnect
puts "JTAG_IDENTIFY_END"
cfg_close
