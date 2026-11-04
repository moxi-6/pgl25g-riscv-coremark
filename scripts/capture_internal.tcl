# Official Fabric Debugger script: read-only after loading the SRAM diagnostic.
dbg_connect -ip 127.0.0.1 -port 65420
dbg_scan_chain
dbg_read_device_id
dbg_read_status_register
dbg_list -device *
dbg_list -core *
dbg_set_cur_core -device 0 -core 0
dbg_import_fic -file C:/fpga/riscv_l50/debug_audit/instrumented/probe_internal.fic -devid 0
dbg_add_bus -name counter -channel 0-24
dbg_add_bus -name reset_n -channel 25
dbg_add_bus -name led3_logic -channel 26
dbg_add_all_to_waveform
dbg_add_all_to_listing
dbg_set_capture -type w -windows 1
dbg_set_capture -type w -depth 512 -position 0
dbg_trig_immd
dbg_delay -time 3
dbg_save_project -file C:/fpga/riscv_l50/debug_audit/capture_512.dprj
dbg_read_status_register
dbg_disconnect
dbg_close
