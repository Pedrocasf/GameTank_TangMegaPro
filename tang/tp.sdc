// Timing for the bring-up test pattern (tang/tp_top.sv).
//
// 50 MHz board clock -> PLL -> 125.625 MHz serial (50 * 201/80) -> CLKDIV /5
// -> 25.125 MHz pixel. Same structure as the console build, standard VGA
// rates instead of the native raster.

create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}] -add

create_generated_clock -name clk_serial -source [get_ports {clk}] -master_clock clk -divide_by 80 -multiply_by 201 [get_pins {pll/pll_inst/CLKOUT0}]

create_generated_clock -name clk_pix -source [get_pins {pll/pll_inst/CLKOUT0}] -master_clock clk_serial -divide_by 5 [get_pins {pll/pix_div/CLKOUT}]

set_clock_groups -asynchronous -group [get_clocks {clk}] -group [get_clocks {clk_pix clk_serial}]

// The reset lands on the serializer synchronizer from the pixel domain; its
// first stage is an intentional asynchronous crossing.
set_false_path -to [get_regs {dvi/rst_ser*}]

// ...and out of it into the serializers: an asynchronous reset release,
// held for thousands of cycles, which no setup window describes.
set_false_path -from [get_regs {dvi/rst_ser*}]
