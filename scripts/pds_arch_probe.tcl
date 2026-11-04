puts "ARCH_PROBE_BEGIN"
flush stdout
set_arch -family Logos -device PGL25G -speedgrade -6 -package MBG324
puts "ARCH_PROBE_SELECTED"
save_project
puts "ARCH_PROBE_END"
