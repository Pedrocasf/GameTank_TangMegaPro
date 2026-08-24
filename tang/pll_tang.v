//============================================================================
//  Tang clock generator — Gowin Arora V PLL primitive.
//
//  Board input is 50 MHz (Tang Mega 138K Pro Dock, pin P16). We need the
//  console's 28.636364 MHz (8x NTSC colorburst, docs/HARDWARE.md §Clocks)
//  and its 5x TMDS serial clock for the DVI transmitter.
//
//    Fpfd = FCLKIN / IDIV            = 50 / 2          = 25 MHz
//    Fvco = Fpfd * FBDIV * MDIV      = 25 * 1 * 34.375 = 859.375 MHz
//    CLKOUT0 = Fvco / ODIV0(6)       = 143.229167 MHz  (TMDS serial, 5x)
//    CLKOUT1 = Fvco / ODIV1(30)      =  28.645833 MHz  (clk_sys / pixel)
//    CLKOUT2 = Fvco / ODIV2(10)      =  85.937500 MHz  (SDRAM, exactly 3x
//                                                       clk_sys — see
//                                                       tang/sdram.sv)
//
//  The exact console clock is unreachable from this board: 28.636364 =
//  50 * 63/110, and the 11 in that denominator would need IDIV = 11, i.e.
//  Fpfd = 4.5 MHz — below the PLL's 19 MHz floor (PnR: PA2078). The closest
//  legal setting is +331 ppm fast, using the 1/8 fractional feedback divider
//  (MDIV_FRAC_SEL). That is 60.21 Hz instead of 60.19, and CPU/audio 0.03%
//  fast: far below anything software or an ear can resolve, and an order of
//  magnitude closer than Sipeed's own 720p reference clock (-337 ppm).
//
//  If fractional-N jitter ever troubles the TMDS receiver, the best
//  integer-only setting is IDIV=1, FBDIV=1, MDIV=20, ODIV0=7, ODIV1=35
//  (Fvco 1000 MHz, -2268 ppm).
//
//  Fvco sits inside the 138K part's 650-1300 MHz window (UG306 §2.3).
//
//  This is a hand-written primitive instantiation rather than IP-generator
//  output so the divider arithmetic above stays reviewable in-tree; the
//  parameter set follows Gowin's generated template.
//============================================================================

module pll_tang
(
    input  wire clkin,          // 50 MHz board clock
    output wire clk_sys,        // 28.645833 MHz (console clock, +331 ppm)
    output wire clk_serial,     // 143.229167 MHz (5x clk_sys)
    output wire clk_sdram,      //  85.937500 MHz (3x clk_sys)
    output wire lock
);

wire clkout3, clkout4, clkout5, clkout6, clkfbout;
wire gnd = 1'b0;
wire vcc = 1'b1;

PLL pll_inst
(
    .LOCK      (lock),
    .CLKOUT0   (clk_serial),
    .CLKOUT1   (clk_sys),
    .CLKOUT2   (clk_sdram),
    .CLKOUT3   (clkout3),
    .CLKOUT4   (clkout4),
    .CLKOUT5   (clkout5),
    .CLKOUT6   (clkout6),
    .CLKFBOUT  (clkfbout),
    .CLKIN     (clkin),
    .CLKFB     (gnd),
    .RESET     (gnd),
    .PLLPWD    (gnd),
    .RESET_I   (gnd),
    .RESET_O   (gnd),
    .FBDSEL    (6'b0),
    .IDSEL     (6'b0),
    .MDSEL     (7'b0),
    .MDSEL_FRAC(3'b0),
    .ODSEL0    (7'b0),
    .ODSEL0_FRAC(3'b0),
    .ODSEL1    (7'b0),
    .ODSEL2    (7'b0),
    .ODSEL3    (7'b0),
    .ODSEL4    (7'b0),
    .ODSEL5    (7'b0),
    .ODSEL6    (7'b0),
    .DT0       (4'b0),
    .DT1       (4'b0),
    .DT2       (4'b0),
    .DT3       (4'b0),
    .ICPSEL    (6'b0),
    .LPFRES    (3'b0),
    .LPFCAP    (2'b0),
    .PSSEL     (3'b0),
    .PSDIR     (gnd),
    .PSPULSE   (gnd),
    .ENCLK0    (vcc),
    .ENCLK1    (vcc),
    .ENCLK2    (vcc),
    .ENCLK3    (vcc),
    .ENCLK4    (vcc),
    .ENCLK5    (vcc),
    .ENCLK6    (vcc),
    .SSCPOL    (gnd),
    .SSCON     (gnd),
    .SSCMDSEL  (7'b0),
    .SSCMDSEL_FRAC(3'b0)
);

defparam pll_inst.FCLKIN = "50";
defparam pll_inst.IDIV_SEL = 2;
defparam pll_inst.FBDIV_SEL = 1;
defparam pll_inst.MDIV_SEL = 34;
defparam pll_inst.MDIV_FRAC_SEL = 3;
defparam pll_inst.ODIV0_SEL = 6;
defparam pll_inst.ODIV0_FRAC_SEL = 0;
defparam pll_inst.ODIV1_SEL = 30;
defparam pll_inst.ODIV2_SEL = 10;
defparam pll_inst.ODIV3_SEL = 8;
defparam pll_inst.ODIV4_SEL = 8;
defparam pll_inst.ODIV5_SEL = 8;
defparam pll_inst.ODIV6_SEL = 8;
defparam pll_inst.CLKOUT0_EN = "TRUE";
defparam pll_inst.CLKOUT1_EN = "TRUE";
defparam pll_inst.CLKOUT2_EN = "TRUE";
defparam pll_inst.CLKOUT3_EN = "FALSE";
defparam pll_inst.CLKOUT4_EN = "FALSE";
defparam pll_inst.CLKOUT5_EN = "FALSE";
defparam pll_inst.CLKOUT6_EN = "FALSE";
defparam pll_inst.CLKFB_SEL = "INTERNAL";
defparam pll_inst.DYN_IDIV_SEL = "FALSE";
defparam pll_inst.DYN_FBDIV_SEL = "FALSE";
defparam pll_inst.DYN_MDIV_SEL = "FALSE";
defparam pll_inst.DYN_ODIV0_SEL = "FALSE";
defparam pll_inst.DYN_ODIV1_SEL = "FALSE";
defparam pll_inst.DYN_ODIV2_SEL = "FALSE";
defparam pll_inst.DYN_ODIV3_SEL = "FALSE";
defparam pll_inst.DYN_ODIV4_SEL = "FALSE";
defparam pll_inst.DYN_ODIV5_SEL = "FALSE";
defparam pll_inst.DYN_ODIV6_SEL = "FALSE";
defparam pll_inst.DYN_DPA_EN = "FALSE";
defparam pll_inst.CLK0_IN_SEL = 1'b0;
defparam pll_inst.CLK0_OUT_SEL = 1'b0;
defparam pll_inst.CLK1_IN_SEL = 1'b0;
defparam pll_inst.CLK1_OUT_SEL = 1'b0;
defparam pll_inst.CLK2_IN_SEL = 1'b0;
defparam pll_inst.CLK2_OUT_SEL = 1'b0;
defparam pll_inst.CLK3_IN_SEL = 1'b0;
defparam pll_inst.CLK3_OUT_SEL = 1'b0;
defparam pll_inst.CLK4_IN_SEL = 2'b00;
defparam pll_inst.CLK4_OUT_SEL = 1'b0;
defparam pll_inst.CLK5_IN_SEL = 1'b0;
defparam pll_inst.CLK5_OUT_SEL = 1'b0;
defparam pll_inst.CLK6_IN_SEL = 1'b0;
defparam pll_inst.CLK6_OUT_SEL = 1'b0;

endmodule
