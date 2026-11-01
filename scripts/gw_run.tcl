# Drives gw_sh through synthesis / place-and-route / bitstream without the GUI.
# STAGE (env): syn = synthesis only, pnr = place-and-route + bitstream, all = both.
# GPRJ (env): path to the .gprj. TOP (env, optional): top module override.
# Adapted from tang_nano_9K_ov7670/scripts/gw_run.tcl.

set gprj $::env(GPRJ)
set stage $::env(STAGE)

puts "Opening project: $gprj"
open_project $gprj

if {[info exists ::env(TOP)]} {
    puts "set_option -top_module $::env(TOP)"
    set_option -top_module $::env(TOP)
}

# Release the dual-purpose configuration pins (MSPI/CPU/SSPI) to fabric so the
# AE350's SPI-flash interface (FLASH_SPI_*) can use them. Without this PnR fails
# with PR2017 "dedicated pin (MSPI)". This mirrors CPU/MSPI/SSPI=true in the
# process config and keeps headless builds working even if that JSON is reset.
# Wrapped in catch: option names vary by IDE version, and a miss just falls back
# to the JSON setting rather than aborting the build.
catch { set_option -use_mspi_as_gpio 1 }
catch { set_option -use_cpu_as_gpio 1 }
catch { set_option -use_sspi_as_gpio 1 }

switch -- $stage {
    syn { run syn }
    pnr { run pnr }
    all { run all }
    default {
        puts "Unknown STAGE: $stage (expected syn|pnr|all)"
        exit 1
    }
}

exit
