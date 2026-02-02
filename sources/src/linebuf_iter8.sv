// Dual-clock scanline double-buffer for iter8 values.
//
// Stores 2 scanlines (bank 0/1), each up to 1024 bytes.
// Address mapping: {bank, x[9:0]}.

module linebuf_iter8(
    input  logic       clk_wr,
    input  logic       we,
    input  logic       bank_wr,
    input  logic [9:0] addr_wr,
    input  logic [7:0] data_wr,

    input  logic       clk_rd,
    input  logic       bank_rd,
    input  logic [9:0] addr_rd,
    output logic [7:0] data_rd
);

    logic [7:0] doutb;

    // 2*1024 x 8-bit = 16384 bits (fits in 1 BRAM18).
    xpm_memory_tdpram #(
        .ADDR_WIDTH_A(11),
        .ADDR_WIDTH_B(11),
        .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(8),
        .BYTE_WRITE_WIDTH_B(8),
        .CASCADE_HEIGHT(0),
        .CLOCKING_MODE("independent_clock"),
        .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"),
        .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"),
        .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(2048 * 8),
        .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_A(8),
        .READ_DATA_WIDTH_B(8),
        .READ_LATENCY_A(1),
        .READ_LATENCY_B(1),
        .READ_RESET_VALUE_A("0"),
        .READ_RESET_VALUE_B("0"),
        .RST_MODE_A("SYNC"),
        .RST_MODE_B("SYNC"),
        .SIM_ASSERT_CHK(0),
        .USE_EMBEDDED_CONSTRAINT(0),
        .USE_MEM_INIT(0),
        .WAKEUP_TIME("disable_sleep"),
        .WRITE_DATA_WIDTH_A(8),
        .WRITE_DATA_WIDTH_B(8),
        .WRITE_MODE_A("write_first"),
        .WRITE_MODE_B("read_first")
    ) u_linebuf (
        .clka   (clk_wr),
        .ena    (1'b1),
        .wea    (we),
        .addra  ({bank_wr, addr_wr}),
        .dina   (data_wr),
        .douta  (),
        .regcea (1'b1),
        .rsta   (1'b0),

        .clkb   (clk_rd),
        .enb    (1'b1),
        .web    (1'b0),
        .addrb  ({bank_rd, addr_rd}),
        .dinb   (8'd0),
        .doutb  (doutb),
        .regceb (1'b1),
        .rstb   (1'b0),

        .sleep  (1'b0),
        .injectsbiterra(1'b0),
        .injectdbiterra(1'b0),
        .injectsbiterrb(1'b0),
        .injectdbiterrb(1'b0),
        .sbiterra(),
        .dbiterra(),
        .sbiterrb(),
        .dbiterrb()
    );

    assign data_rd = doutb;

endmodule
