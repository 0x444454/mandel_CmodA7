// tmds_serdes_10to1.sv
// 7-series OSERDESE2 10:1 DDR serializer (DATA_WIDTH=10).
// Bit order: data[0] is sent first (D1), then data[1] (D2) ... data[9] (slave D4).

module tmds_serdes_10to1 (
    input  wire        clk_5x,   // 5x pixel clock (e.g. 125 MHz for 25 MHz pix)
    input  wire        clk_pix,  // pixel clock / CLKDIV (e.g. 25 MHz)
    input  wire        rst,       // active-high reset
    input  wire [9:0]  data,
    output wire        out
);

    wire shift1;
    wire shift2;
    wire tfb_m;
    wire tfb_s;

    // Master (bits 0..7 + shift-in bits 8..9 from slave)
    OSERDESE2 #(
        .DATA_RATE_OQ("DDR"),
        .DATA_RATE_TQ("SDR"),
        .DATA_WIDTH(10),
        .INIT_OQ(1'b0),
        .INIT_TQ(1'b0),
        .SERDES_MODE("MASTER"),
        .SRVAL_OQ(1'b0),
        .SRVAL_TQ(1'b0),
        .TBYTE_CTL("FALSE"),
        .TBYTE_SRC("FALSE"),
        .TRISTATE_WIDTH(1)
    ) u_oserdes_m (
        .OQ         (out),
        .OFB        (),
        .TQ         (),
        .TFB        (tfb_m),
        .SHIFTOUT1  (),
        .SHIFTOUT2  (),
        .TBYTEOUT   (),

        .CLK        (clk_5x),
        .CLKDIV     (clk_pix),

        .D1         (data[0]),
        .D2         (data[1]),
        .D3         (data[2]),
        .D4         (data[3]),
        .D5         (data[4]),
        .D6         (data[5]),
        .D7         (data[6]),
        .D8         (data[7]),

        .SHIFTIN1   (shift1),
        .SHIFTIN2   (shift2),

        .OCE        (1'b1),

        .T1         (1'b0),
        .T2         (1'b0),
        .T3         (1'b0),
        .T4         (1'b0),
        .TCE        (1'b1),

        .TBYTEIN    (1'b0),

        .RST        (rst)
    );

    // Slave (provides bits 8..9 through shift chain)
    OSERDESE2 #(
        .DATA_RATE_OQ("DDR"),
        .DATA_RATE_TQ("SDR"),
        .DATA_WIDTH(10),
        .INIT_OQ(1'b0),
        .INIT_TQ(1'b0),
        .SERDES_MODE("SLAVE"),
        .SRVAL_OQ(1'b0),
        .SRVAL_TQ(1'b0),
        .TBYTE_CTL("FALSE"),
        .TBYTE_SRC("FALSE"),
        .TRISTATE_WIDTH(1)
    ) u_oserdes_s (
        .OQ         (),
        .OFB        (),
        .TQ         (),
        .TFB        (tfb_s),
        .SHIFTOUT1  (shift1),
        .SHIFTOUT2  (shift2),
        .TBYTEOUT   (),

        .CLK        (clk_5x),
        .CLKDIV     (clk_pix),

        // Per Xilinx 7-series OSERDESE2 10-bit mode: use D3/D4 on SLAVE.
        .D1         (1'b0),
        .D2         (1'b0),
        .D3         (data[8]),
        .D4         (data[9]),
        .D5         (1'b0),
        .D6         (1'b0),
        .D7         (1'b0),
        .D8         (1'b0),

        .SHIFTIN1   (1'b0),
        .SHIFTIN2   (1'b0),

        .OCE        (1'b1),

        .T1         (1'b0),
        .T2         (1'b0),
        .T3         (1'b0),
        .T4         (1'b0),
        .TCE        (1'b1),

        .TBYTEIN    (1'b0),

        .RST        (rst)
    );

endmodule
