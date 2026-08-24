# tang/syn.tcl — Gowin build for the Tang Mega 138K Pro video top (T2).
# Run from the repo root:  gw_sh tang/syn.tcl
# Device version is overridable:  gw_sh tang/syn.tcl 138C

set dev_ver "B"
if {$argc > 0} {
    set arg [lindex $argv 0]
    if {[string match "*138C*" $arg]} { set dev_ver "C" }
}

if {$dev_ver eq "C"} {
    set_device -name GW5AST-138C GW5AST-LV138FPG676AC1/I0
} else {
    set_device -name GW5AST-138B GW5AST-LV138FPG676AC1/I0
}

# --- macro definitions (must be first: see the file header) ---
add_file -type verilog tang/gowin_defines.v

# --- console core (shared verbatim with the MiSTer build) ---
add_file -type verilog rtl/gametank.sv
add_file -type verilog rtl/gtvideo.sv
add_file -type verilog rtl/mainbus.sv
add_file -type verilog rtl/acp.sv
add_file -type verilog rtl/pads.sv
add_file -type verilog rtl/vram.sv
add_file -type verilog rtl/frame_snapshot.sv
add_file -type verilog rtl/gram_ddr.sv
add_file -type verilog rtl/cart.sv
add_file -type verilog rtl/ddr_mux.sv
add_file -type verilog rtl/savectl.sv
add_file -type verilog rtl/blitter.sv
add_file -type verilog rtl/palette.sv
add_file -type verilog rtl/via/via6522.v
add_file -type verilog rtl/cpu/cpu_65c02.v
add_file -type verilog rtl/cpu/ALU.v

# --- Tang board layer ---
add_file -type verilog tang/gametank_tang.sv
add_file -type verilog tang/linedouble.sv
add_file -type verilog tang/tmds_encoder.sv
add_file -type verilog tang/dvi_tx.sv
add_file -type verilog tang/ddr_bram.sv
add_file -type verilog tang/pll_tang.v
add_file -type cst     tang/gametank_tang.cst
add_file -type sdc     tang/gametank_tang.sdc

set_option -top_module gametank_tang
set_option -verilog_std sysv2017
set_option -output_base_name gametank_tang

run all
