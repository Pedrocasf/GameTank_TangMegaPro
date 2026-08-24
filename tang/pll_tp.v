//============================================================================
//  Clock generator for the bring-up test pattern (tang/tp_top.sv).
//
//  Same structure as tang/pll_tang.v — PLL makes the serial clock, CLKDIV
//  divides it by five for the pixel clock — but at VGA 640x480@60 rates
//  instead of the console's native raster:
//
//    Fpfd = 50 / 1                     = 50 MHz
//    Fvco = 50 * 1 * 25.125            = 1256.25 MHz   (650-1300 window)
//    CLKOUT0 = Fvco / ODIV0(10)        = 125.625 MHz   (TMDS serial)
//    clk_pix = CLKOUT0 / 5 (CLKDIV)    = 25.125 MHz
//
//  25.125 against the nominal 25.175 MHz is -0.2%: 31.41 kHz line rate and
//  59.9 Hz frame rate, well inside what any sink accepts.
//============================================================================

module pll_tp
(
    input  wire clkin,          // 50 MHz board clock
    output wire clk_pix,        // 25.125 MHz
    output wire clk_serial,     // 125.625 MHz
    output wire lock
);

wire clkout1, clkout2, clkout3, clkout4, clkout5, clkout6, clkfbout;
wire gnd = 1'b0;
wire vcc = 1'b1;

PLL pll_inst
(
    .LOCK      (lock),
    .CLKOUT0   (clk_serial),
    .CLKOUT1   (clkout1),
    .CLKOUT2   (clkout2),
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
defparam pll_inst.IDIV_SEL = 1;
defparam pll_inst.FBDIV_SEL = 1;
defparam pll_inst.MDIV_SEL = 25;
defparam pll_inst.MDIV_FRAC_SEL = 1;
defparam pll_inst.ODIV0_SEL = 10;
defparam pll_inst.ODIV0_FRAC_SEL = 0;
defparam pll_inst.ODIV1_SEL = 8;
defparam pll_inst.ODIV2_SEL = 8;
defparam pll_inst.ODIV3_SEL = 8;
defparam pll_inst.ODIV4_SEL = 8;
defparam pll_inst.ODIV5_SEL = 8;
defparam pll_inst.ODIV6_SEL = 8;
defparam pll_inst.CLKOUT0_EN = "TRUE";
defparam pll_inst.CLKOUT1_EN = "FALSE";
defparam pll_inst.CLKOUT2_EN = "FALSE";
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

CLKDIV pix_div
(
    .CLKOUT (clk_pix),
    .HCLKIN (clk_serial),
    .RESETN (lock),
    .CALIB  (1'b0)
);
defparam pix_div.DIV_MODE = "5";

endmodule
