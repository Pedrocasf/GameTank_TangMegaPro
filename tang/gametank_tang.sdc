// Tang Mega 138K Pro — T2 timing constraints.
//
// One 50 MHz board clock feeds tang/pll_tang.v, which produces the console
// clock (28.645833 MHz = 50 * 55/96) and its 5x TMDS serial clock
// (143.229167 MHz = 50 * 275/96). Both are declared against the board clock so
// the tool relates them; everything console-side is synchronous to clk_sys.
// On the +331 ppm offset from the console's true 28.636364 MHz, see
// tang/pll_tang.v.

create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}] -add

// clk_sys is the serial clock divided by five in a CLKDIV, not a PLL output:
// see the header of tang/pll_tang.v for why that matters to the serializers.
create_generated_clock -name clk_sys -source [get_pins {pll/pll_inst/CLKOUT0}] -master_clock clk_serial -divide_by 5 [get_pins {pll/pix_div/CLKOUT}]

create_generated_clock -name clk_serial -source [get_ports {clk}] -master_clock clk     -divide_by 96 -multiply_by 275 [get_pins {pll/pll_inst/CLKOUT0}]

// SDRAM clock, exactly 3x clk_sys off the same VCO. It shares a group with
// clk_sys below on purpose: tang/sdram.sv hands data between the two domains
// directly, and that transfer is only safe because STA times it. Moving this
// clock into its own asynchronous group would silently un-time those paths.
create_generated_clock -name clk_sdram -source [get_ports {clk}] -master_clock clk     -divide_by 32 -multiply_by 55 [get_pins {pll/pll_inst/CLKOUT2}]

// The board clock domain holds nothing but the PLL input.
set_clock_groups -asynchronous -group [get_clocks {clk}]                                -group [get_clocks {clk_sys clk_serial clk_sdram}]

// The console reset lands on the DVI serializers through a two-flop
// synchronizer in tang/dvi_tx.sv. Its first stage is an intentional
// asynchronous crossing, so setup analysis on it is meaningless — exclude it
// rather than letting PnR chase a path with no timing relationship to honour.
//
// Constrained by destination, not source: reset is assembled from the PLL
// lock, the button, and (with the SDRAM back end) init_done out of the
// clk_sdram domain, so naming sources would have to change every time
// something new gates reset.
set_false_path -to [get_regs {dvi/rst_ser*}]
