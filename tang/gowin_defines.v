//============================================================================
//  Compiled first by tang/syn.tcl so the rest of the sources see `GOWIN`.
//  GowinSynthesis has no command-line macro option (`set_option
//  -verilog_define` does not exist), and macros persist across files within
//  one synthesis run, so a leading file is the way to set one.
//
//  `GOWIN` currently selects the inferred ACP RAM in rtl/acp.sv instead of
//  the Quartus `altsyncram` primitive.
//============================================================================

`define GOWIN 1
