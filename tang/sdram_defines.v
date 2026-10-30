//============================================================================
//  Selects the SDRAM memory back end. Added by tang/syn.tcl when the build is
//  invoked with the `sdram` option; without it the top instantiates
//  tang/ddr_bram.sv instead and needs no module attached to the 40-pin header.
//============================================================================

`define TANG_SDRAM 1
