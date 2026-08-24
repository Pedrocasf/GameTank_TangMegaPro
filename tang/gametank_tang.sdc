// Tang Mega 138K Pro — T2 timing constraints.
//
// One 50 MHz board clock feeds tang/pll_tang.v, which produces the console
// clock (28.645833 MHz = 50 * 55/96) and its 5x TMDS serial clock
// (143.229167 MHz = 50 * 275/96). Both are declared against the board clock so
// the tool relates them; everything console-side is synchronous to clk_sys.
// On the +331 ppm offset from the console's true 28.636364 MHz, see
// tang/pll_tang.v.

create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}] -add

create_generated_clock -name clk_sys -source [get_ports {clk}] -master_clock clk     -divide_by 96 -multiply_by 55 [get_pins {pll/pll_inst/CLKOUT1}]

create_generated_clock -name clk_serial -source [get_ports {clk}] -master_clock clk     -divide_by 96 -multiply_by 275 [get_pins {pll/pll_inst/CLKOUT0}]

// The board clock domain holds nothing but the PLL input.
set_clock_groups -asynchronous -group [get_clocks {clk}]                                -group [get_clocks {clk_sys clk_serial}]

// The console reset is generated against clk_sys and lands on the DVI
// serializers through a two-flop synchronizer in tang/dvi_tx.sv. The first
// stage is an intentional asynchronous crossing, so its setup/pulse-width
// analysis is meaningless — exclude it rather than letting PnR chase a path
// that has no timing relationship to honour.
set_false_path -from [get_regs {rst_cnt*}] -to [get_regs {dvi/rst_ser*}]
