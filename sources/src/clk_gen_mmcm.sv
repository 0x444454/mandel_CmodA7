// Clock generator for the Cmod A7 design (12 MHz input oscillator).
//
// Produces three clocks:
//   clk100 : Mandelbrot engines + scheduler (nominal 100 MHz)
//   clk_pix: Video pixel clock (drives timing + TMDS encoder)
//   clk_5x : TMDS serializer clock (5x pixel, DDR => 10:1)
//
// Note: this project uses a reduced 960x544 mode to keep TMDS rates within a comfortable margin on Cmod A7 + PMOD-HDMI adapters.
//
module clk_gen_mmcm(
    input  logic clk12,
    input  logic rst,          // Active-high (optional; can tie low).
    output logic clk_pix,
    output logic clk100,
    output logic clk_5x,
    output logic locked
);
    // Cmod A7 has a 12 MHz onboard oscillator.
    //
    // We generate:
    //   - clk100 : Mandel/scheduler clock (~99.74 MHz)
    //   - clk_5x : TMDS serializer clock (5x pixel clock, DDR => 10:1) = 187.5 MHz
    //   - clk_pix: Pixel clock (clk_5x/5), generated directly by the MMCM
    //
    // MMCM plan:
    //   fVCO   = 12 MHz * 63.375 = 760.5 MHz
    //   clk_5x = 760.5 / 4       = 190.125 MHz
    //   clk_pix = 760.5 / 20     = 38.025 MHz
    //   clk100 = 760.5 / 7.625   = ~99.738 MHz

    logic clkfb_mmcm;
    logic clkfb;

    logic clk100_i;
    logic clk_5x_i;
    logic clk_pix_i;

    // Route feedback through a BUFG for proper compensation.
    BUFG u_bufg_fb (.I(clkfb_mmcm), .O(clkfb));

    // Use MMCME2_ADV so we can explicitly connect all ports (avoids confusing port-count warnings in some Vivado configurations).
    MMCME2_ADV #(
        .BANDWIDTH("OPTIMIZED"),
        .COMPENSATION("ZHOLD"),
        .STARTUP_WAIT("FALSE"),

        .CLKIN1_PERIOD(83.333),      // 12 MHz
        .DIVCLK_DIVIDE(1),

        .CLKFBOUT_MULT_F(63.375),    // 760.5 MHz VCO
        .CLKFBOUT_PHASE(0.0),
        .CLKFBOUT_USE_FINE_PS("FALSE"),

        .CLKOUT0_DIVIDE_F(7.625),    // ~99.738 MHz
        .CLKOUT0_PHASE(0.0),
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT0_USE_FINE_PS("FALSE"),

        .CLKOUT1_DIVIDE(4),          // 190.125 MHz
        .CLKOUT1_PHASE(0.0),
        .CLKOUT1_DUTY_CYCLE(0.5),
        .CLKOUT1_USE_FINE_PS("FALSE"),

        .CLKOUT2_DIVIDE(20),         // 38.025 MHz
        .CLKOUT2_PHASE(0.0),
        .CLKOUT2_DUTY_CYCLE(0.5),
        .CLKOUT2_USE_FINE_PS("FALSE"),

        // Unused outputs.
        .CLKOUT3_DIVIDE(1),
        .CLKOUT3_PHASE(0.0),
        .CLKOUT3_DUTY_CYCLE(0.5),
        .CLKOUT3_USE_FINE_PS("FALSE"),

        .CLKOUT4_DIVIDE(1),
        .CLKOUT4_PHASE(0.0),
        .CLKOUT4_DUTY_CYCLE(0.5),
        .CLKOUT4_USE_FINE_PS("FALSE"),

        .CLKOUT5_DIVIDE(1),
        .CLKOUT5_PHASE(0.0),
        .CLKOUT5_DUTY_CYCLE(0.5),
        .CLKOUT5_USE_FINE_PS("FALSE"),

        .CLKOUT6_DIVIDE(1),
        .CLKOUT6_PHASE(0.0),
        .CLKOUT6_DUTY_CYCLE(0.5),
        .CLKOUT6_USE_FINE_PS("FALSE")
    ) u_mmcm (
        // Clock in + feedback
        .CLKIN1      (clk12),
        .CLKIN2      (1'b0),
        .CLKINSEL    (1'b1),

        .CLKFBIN     (clkfb),
        .CLKFBOUT    (clkfb_mmcm),
        .CLKFBOUTB   (),

        // Clocks out
        .CLKOUT0     (clk100_i),
        .CLKOUT0B    (),
        .CLKOUT1     (clk_5x_i),
        .CLKOUT1B    (),
        .CLKOUT2     (clk_pix_i),
        .CLKOUT2B    (),
        .CLKOUT3     (),
        .CLKOUT3B    (),
        .CLKOUT4     (),
        .CLKOUT5     (),
        .CLKOUT6     (),

        // DRP (unused)
        .DADDR       (7'd0),
        .DCLK        (clk12),
        .DEN         (1'b0),
        .DI          (16'd0),
        .DWE         (1'b0),
        .DO          (),
        .DRDY        (),

        // Phase shift (unused)
        .PSCLK       (clk12),
        .PSEN        (1'b0),
        .PSINCDEC    (1'b0),
        .PSDONE      (),

        // Status
        .LOCKED      (locked),
        .CLKFBSTOPPED(),
        .CLKINSTOPPED(),

        // Control
        .PWRDWN      (1'b0),
        .RST         (rst)
    );

    // Note: BUFIO can be preferable for very high-speed serializers, but it requires the MMCM and BUFIO to be placed in the same clock region.
    // On the Cmod A7 this can fail placement depending on the clocking column chosen by the placer.
    // Using BUFG is reliable at ~190 MHz for this design.
    BUFG u_bufg_5x  (.I(clk_5x_i),  .O(clk_5x));

    BUFG u_bufg_100 (.I(clk100_i),  .O(clk100));

    BUFG u_bufg_pix (.I(clk_pix_i), .O(clk_pix));

endmodule
