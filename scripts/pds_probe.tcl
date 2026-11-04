puts "PDS_PROBE_BEGIN"
foreach command {set_arch add_design add_constraint compile synthesize dev_map pnr report_timing gen_bit_stream} {
    puts "COMMAND_HELP $command"
    if {[llength [info commands $command]]} {
        catch {$command -help} result
        puts $result
    } else {
        puts "NOT_AVAILABLE"
    }
}
puts "PDS_PROBE_END"
