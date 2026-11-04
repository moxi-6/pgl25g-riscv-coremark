puts "PROJECT_COMMANDS [info commands *project*]"
foreach command {open_project load_project project_open} {
    if {[llength [info commands $command]]} {catch {$command -help} result; puts $result}
}
