# PDS 2022.2 SP4.2 flow. Never programs hardware.
set_arch -family Logos -device PGL25G -speedgrade -6 -package MBG324
puts "PDS_FLOW_BEGIN"
set root [file dirname [file normalize [info script]]]
cd $root
foreach variable {L50_TOP_MODULE L50_FLOW_STAGE L50_CONSTRAINT_FILE} {
    if {![info exists env($variable)]} {error "Missing environment variable $variable"}
}
add_design [file join $root pds_design.sv]
add_constraint [file join $root constraints $env(L50_CONSTRAINT_FILE)]
puts "CONSTRAINT_FILE $env(L50_CONSTRAINT_FILE)"
if {$env(L50_FLOW_STAGE) ne "Create"} {
    compile -system_verilog -top_module $env(L50_TOP_MODULE) -loop_limit 10000
}
if {$env(L50_FLOW_STAGE) in {Synthesize Map Route Timing}} {
    synthesize -ads
}
if {$env(L50_FLOW_STAGE) in {Map Route Timing}} {dev_map}
if {$env(L50_FLOW_STAGE) in {Route Timing}} {
    puts "EXPLORATORY_ROUTE: constraints=$env(L50_CONSTRAINT_FILE); not for board download."
    pnr
}
if {$env(L50_FLOW_STAGE) eq "Timing"} {
    report_timing -delay_type min_max -max_path 10
}
puts "PDS_FLOW_COMPLETE $env(L50_FLOW_STAGE)"

gen_bit_stream -create_bit_file TRUE -create_mask_file TRUE -write_drm_data TRUE -unused_io_status PULLDOWN -gouten_time_slot T2 -gwen_time_slot T3 -grsn_time_slot T4 -done_time_slot T1
puts "EXPLICIT_STARTUP_END"
