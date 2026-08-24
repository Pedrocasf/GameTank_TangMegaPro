// SDRAM interface timing (T3). Added alongside tang/gametank_tang.sdc when the
// build selects the `sdram` option.
//
// Numbers are for a 143 MHz-rated 16-bit part (W9825G6KH class) with ~0.5 ns
// added each way for the ribbon out to the module:
//   FPGA -> module   tSU 1.5 ns, tH 0.8 ns
//   module -> FPGA   tAC 5.4 ns, tOH 2.5 ns
//
// Simplification worth knowing: these are written against clk_sdram rather
// than against the forwarded sdram_clk as a proper source-synchronous
// constraint would be. That is honest only because the forwarded clock leaves
// through an ODDR on the same clock (tang/sdram_io.sv) — revisit it if reads
// need more margin than tang/sdram.sv's RD_EXTRA can give them.

set_input_delay  -clock clk_sdram -max 6.0 [get_ports {sdram_dq[*]}]
set_input_delay  -clock clk_sdram -min 2.0 [get_ports {sdram_dq[*]}]

set_output_delay -clock clk_sdram -max  2.0 [get_ports {sdram_dq[*]}]
set_output_delay -clock clk_sdram -min -0.8 [get_ports {sdram_dq[*]}]

set_output_delay -clock clk_sdram -max  2.0 [get_ports {sdram_a[*] sdram_ba[*] sdram_dqm[*]}]
set_output_delay -clock clk_sdram -min -0.8 [get_ports {sdram_a[*] sdram_ba[*] sdram_dqm[*]}]

set_output_delay -clock clk_sdram -max  2.0 [get_ports {sdram_cs_n sdram_ras_n sdram_cas_n sdram_we_n sdram_cke}]
set_output_delay -clock clk_sdram -min -0.8 [get_ports {sdram_cs_n sdram_ras_n sdram_cas_n sdram_we_n sdram_cke}]
