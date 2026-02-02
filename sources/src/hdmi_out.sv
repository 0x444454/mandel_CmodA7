// DVI-D / HDMI TMDS output (no Data Islands / InfoFrames / audio).
//
// Inputs are 8-bit RGB plus HSYNC/VSYNC/DE in the pixel clock domain.
// Each channel is TMDS-encoded to a 10-bit symbol at clk_pix, then serialized
// with OSERDESE2 (10:1 DDR) using clk_5x.
//
// Channel mapping follows DVI/HDMI convention:
//   TMDS0 = Blue  (carries control bits {VSYNC,HSYNC} during blanking)
//   TMDS1 = Green
//   TMDS2 = Red
//   TMDS Clock = forwarded pixel clock pattern
//
module hdmi_out(
    input  logic       clk_pix,   // pixel clock
    input  logic       clk_5x,    // 5x pixel clock
    input  logic       rst_pix,   // reset for pixel domain (active-high)
    input  logic       rst_ser,   // reset for serializer domain (active-high)

    input  logic [7:0] red,
    input  logic [7:0] green,
    input  logic [7:0] blue,
    input  logic       hsync,
    input  logic       vsync,
    input  logic       de,

    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_d_p,
    output wire [2:0]  tmds_d_n
);
    logic [9:0] tmds0, tmds1, tmds2;

    // Channel mapping:
    //   D0: Blue  + control bits (hsync/vsync) during blanking
    //   D1: Green
    //   D2: Red
    tmds_encoder u_enc0(
        .clk(clk_pix),
        .rst(rst_pix),
        .vd(blue),
        .cd({vsync, hsync}),
        .vde(de),
        .tmds(tmds0)
    );

    tmds_encoder u_enc1(
        .clk(clk_pix),
        .rst(rst_pix),
        .vd(green),
        .cd(2'b00),
        .vde(de),
        .tmds(tmds1)
    );

    tmds_encoder u_enc2(
        .clk(clk_pix),
        .rst(rst_pix),
        .vd(red),
        .cd(2'b00),
        .vde(de),
        .tmds(tmds2)
    );

    // Serialize 10-bit symbols at 10x pixel rate using DDR at 5x clock.
    logic s0, s1, s2, sclk;

    tmds_serdes_10to1 u_ser0 (.clk_5x(clk_5x), .clk_pix(clk_pix), .rst(rst_ser), .data(tmds0), .out(s0));
    tmds_serdes_10to1 u_ser1 (.clk_5x(clk_5x), .clk_pix(clk_pix), .rst(rst_ser), .data(tmds1), .out(s1));
    tmds_serdes_10to1 u_ser2 (.clk_5x(clk_5x), .clk_pix(clk_pix), .rst(rst_ser), .data(tmds2), .out(s2));

    // Clock channel: 5 ones then 5 zeros (any phase is OK as long as 50% duty).
    tmds_serdes_10to1 u_serclk(
        .clk_5x(clk_5x),
        .clk_pix(clk_pix),
        .rst(rst_ser),
        .data(10'b1111100000),
        .out(sclk)
    );

    // Differential outputs (TMDS_33).
    OBUFDS #(.IOSTANDARD("TMDS_33")) u_obuf_clk(.I(sclk), .O(tmds_clk_p), .OB(tmds_clk_n));
    OBUFDS #(.IOSTANDARD("TMDS_33")) u_obuf_d0 (.I(s0),   .O(tmds_d_p[0]),  .OB(tmds_d_n[0]));
    OBUFDS #(.IOSTANDARD("TMDS_33")) u_obuf_d1 (.I(s1),   .O(tmds_d_p[1]),  .OB(tmds_d_n[1]));
    OBUFDS #(.IOSTANDARD("TMDS_33")) u_obuf_d2 (.I(s2),   .O(tmds_d_p[2]),  .OB(tmds_d_n[2]));

endmodule
