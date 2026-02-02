// Async SRAM access scheduler for the Cmod A7 512KB SRAM (8-bit data).
//
// Per video line (FB_W bytes, clk domain = clk100):
//   1) Prefetch (burst-read) one framebuffer scanline (iter8) from SRAM into the BRAM display line buffer.
//      - 1 byte / clk (after the initial address) by keeping CE/OE asserted.
//   2) After the prefetch, if one of the 2 render write-buffer lines is FULL, commit exactly one full line to SRAM.
//      - 1 byte / clk by holding WE asserted through the burst (try-fast mode).
//
// The SRAM bus never interleaves reads and writes within a line.
// This avoids possible corruption caused by rapid read/write turnarounds.
//
module sram_line_dma #(
    parameter int FB_W      = 960,
    parameter int FB_H      = 544,
    parameter int V_VISIBLE = 544,
    parameter int V_TOTAL   = 566
)(
    input  logic        clk,
    input  logic        rst,
    input  logic        line_pulse,
    input  logic        frame_pulse,

    // External SRAM pins (active-low control signals).
    output logic [18:0] MemAdr,
    inout  wire  [7:0]  MemDB,
    output logic        RamOEn,
    output logic        RamWEn,
    output logic        RamCEn,

    // Display line buffer write port.
    output logic        lb_we,
    output logic        lb_bank,
    output logic [9:0]  lb_addr,
    output logic [7:0]  lb_data,

    // Render write-buffer read port (sequential during commit).
    output logic        rb_bank,
    output logic [9:0]  rb_addr,
    input  logic [7:0]  rb_data,

    // Write-buffer status.
    input  logic        wb_full0,
    input  logic        wb_full1,
    input  logic [9:0]  wb_y0,
    input  logic [9:0]  wb_y1,

    // Commit handshake to the writer.
    output logic        commit_take,
    output logic        commit_done,
    output logic        commit_bank
);

    localparam int LINE_W = $clog2(FB_W);      // 10 for 960
    localparam int SCAN_W = $clog2(V_TOTAL);   // 10 for 566

    // Tri-state data bus.
    logic [7:0] db_out;
    logic       db_oe;
    wire  [7:0] db_in;
    assign MemDB = db_oe ? db_out : 8'bz;
    assign db_in = MemDB;

    // -------------------------------------------------------------------------
    // Scan line counter and prefetch line selection (same policy as inc9).
    // -------------------------------------------------------------------------
    // We prefetch *ahead* of scanout so the HDMI pixel pipeline never waits on SRAM.
    // The policy is:
    //   - During visible lines, prefetch the *next* visible line (v+1).
    //   - At the last visible line, wrap to line 0.
    //   - During vertical blank, prefetch a line that will be needed soon after
    //     the next wrap, so the line buffer stays warm.
    logic [SCAN_W-1:0] scan_line;
    logic [9:0]        pref_line;

    function automatic [9:0] calc_pref_line(input logic [SCAN_W-1:0] sl);
        begin
            if (sl < (V_VISIBLE - 1)) begin
                calc_pref_line = sl + 1'b1;
            end
            else if (sl == (V_VISIBLE - 1)) begin
                calc_pref_line = 10'd0;
            end
            else begin
                calc_pref_line = sl - V_VISIBLE;
            end
        end
    endfunction

    always_comb begin
        pref_line = calc_pref_line(scan_line);

        // Bank parity: the BRAM line buffer is ping-pong (bank0/bank1) based on line LSB.
        // The video path reads bank_rd = v_count[0] for the *current* visible line.
        // Here we prefetch pref_line (typically scan_line+1) into bank = pref_line[0],
        // i.e. the bank that will be read on the next visible line.

    end

    always_ff @(posedge clk) begin
        if (rst) begin
            scan_line <= '0;
        end else begin
            if (frame_pulse) begin
                scan_line <= '0;
            end
            else if (line_pulse) begin
                if (scan_line == (V_TOTAL - 1)) begin
                    scan_line <= '0;
                end else begin
                    scan_line <= scan_line + 1'b1;
                end
            end
        end
    end

    function automatic [18:0] mul960(input logic [9:0] v);
        logic [19:0] tmp;
        begin
            // 960 = 1024 - 64
            tmp = ({10'd0, v} << 10) - ({10'd0, v} << 6);
            mul960 = tmp[18:0];
        end
    endfunction

    // -------------------------------------------------------------------------
    // Burst read state (SRAM -> display linebuf)
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        ST_IDLE      = 3'd0,
        ST_RD_RUN    = 3'd1,
        ST_RD_FLUSH1 = 3'd2,
        ST_RD_FLUSH2 = 3'd3,
        ST_WR_PRIME  = 3'd4,
        ST_WR_P0     = 3'd5,
        ST_TURN      = 3'd6
    } state_t;

    state_t state;

    logic [18:0] rd_base;
    logic [10:0] rd_i;          // 0..FB_W
    logic        rd_bank;
    logic        hold_valid;
    logic [9:0]  hold_addr;
    logic [7:0]  hold_data;

    // -------------------------------------------------------------------------
    // Commit state (renderbuf -> SRAM)
    // -------------------------------------------------------------------------
    logic        wr_bank;
    logic [9:0]  wr_y;
    logic [18:0] wr_base;
    logic [10:0] wr_i;          // 0..FB_W-1

    // Select a bank to commit (fixed priority).
    logic        have_commit;
    logic        sel_bank;
    logic [9:0]  sel_y;
    always_comb begin
        have_commit = 1'b0;
        sel_bank    = 1'b0;
        sel_y       = 10'd0;
        if (wb_full0) begin
            have_commit = 1'b1;
            sel_bank    = 1'b0;
            sel_y       = wb_y0;
        end else if (wb_full1) begin
            have_commit = 1'b1;
            sel_bank    = 1'b1;
            sel_y       = wb_y1;
        end
    end

    // -------------------------------------------------------------------------
    // Main FSM.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            state <= ST_IDLE;

            MemAdr <= 19'd0;
            RamCEn <= 1'b1;
            RamOEn <= 1'b1;
            RamWEn <= 1'b1;
            db_oe  <= 1'b0;
            db_out <= 8'd0;

            lb_we   <= 1'b0;
            lb_bank <= 1'b0;
            lb_addr <= 10'd0;
            lb_data <= 8'd0;

            rb_bank <= 1'b0;
            rb_addr <= 10'd0;

            commit_take <= 1'b0;
            commit_done <= 1'b0;
            commit_bank <= 1'b0;

            rd_base <= 19'd0;
            rd_i    <= 11'd0;
            rd_bank <= 1'b0;
            hold_valid <= 1'b0;
            hold_addr  <= 10'd0;
            hold_data  <= 8'd0;

            wr_bank <= 1'b0;
            wr_y    <= 10'd0;
            wr_base <= 19'd0;
            wr_i    <= 11'd0;
        end else begin
            // Defaults.
            RamCEn <= 1'b1;
            RamOEn <= 1'b1;
            RamWEn <= 1'b1;
            db_oe  <= 1'b0;
            lb_we  <= 1'b0;
            commit_take <= 1'b0;
            commit_done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    hold_valid <= 1'b0;

                    // Start a prefetch at the beginning of each video line.
                    if (line_pulse) begin
                        rd_base <= mul960(pref_line);
                        rd_i    <= 11'd0;
                        rd_bank <= pref_line[0];
                        lb_bank <= pref_line[0];
                        state   <= ST_RD_RUN;
                    end
                end

                // Present address 0..FB_W-1, 1 address per clk.
                // The async SRAM has an 8 ns access time; at ~100 MHz clk we can safely sample db_in one cycle after presenting the address.
                // Data is sampled one cycle later and written to BRAM using a 1-cycle pipeline (hold_*).
                ST_RD_RUN: begin
                    // SRAM read strobes asserted continuously.
                    RamCEn <= 1'b0;
                    RamOEn <= 1'b0;
                    RamWEn <= 1'b1;
                    db_oe  <= 1'b0;

                    // rd_i is only 11 bits; some Vivado versions reject part-selects
                    // larger than the prefix width. Let normal sizing/casting handle it.
                    MemAdr <= rd_base + rd_i;

                    // Write previous sampled data.
                    if (hold_valid) begin
                        lb_we   <= 1'b1;
                        lb_bank <= rd_bank;
                        lb_addr <= hold_addr;
                        lb_data <= hold_data;
                    end

                    // Capture data for the previous address.
                    if (rd_i != 0) begin
                        hold_valid <= 1'b1;
                        hold_addr  <= rd_i[9:0] - 10'd1;
                        hold_data  <= db_in;
                    end else begin
                        hold_valid <= 1'b0;
                    end

                    if (rd_i == (FB_W - 1)) begin
                        // Last address has been presented this cycle.
                        rd_i  <= rd_i + 11'd1;
                        state <= ST_RD_FLUSH1;
                    end else begin
                        rd_i <= rd_i + 11'd1;
                    end
                end

                // Flush stage 1:
                // - Write the last *previous* captured byte.
                // - Capture the final byte (for address FB_W-1).
                ST_RD_FLUSH1: begin
                    // Keep SRAM in read mode for this cycle so db_in is the data for the last address.
                    RamCEn <= 1'b0;
                    RamOEn <= 1'b0;
                    RamWEn <= 1'b1;
                    db_oe  <= 1'b0;

                    // Write the last pending captured byte.
                    if (hold_valid) begin
                        lb_we   <= 1'b1;
                        lb_bank <= rd_bank;
                        lb_addr <= hold_addr;
                        lb_data <= hold_data;
                    end

                    // Capture final byte (for address FB_W-1).
                    hold_valid <= 1'b1;
                    hold_addr  <= (FB_W - 1);
                    hold_data  <= db_in;

                    state <= ST_RD_FLUSH2;
                end

                // Flush stage 2: write the final byte (captured in flush1).
                ST_RD_FLUSH2: begin
                    if (hold_valid) begin
                        lb_we   <= 1'b1;
                        lb_bank <= rd_bank;
                        lb_addr <= hold_addr;
                        lb_data <= hold_data;
                    end
                    hold_valid <= 1'b0;

                    // After prefetch, optionally commit one full render line.
                    if (have_commit) begin
                        wr_bank <= sel_bank;
                        wr_y    <= sel_y;
                        wr_base <= mul960(sel_y);
                        wr_i    <= 11'd0;

                        rb_bank <= sel_bank;
                        rb_addr <= 10'd0;

                        commit_take <= 1'b1;
                        commit_bank <= sel_bank;

                        state <= ST_WR_PRIME;
                    end else begin
                        state <= ST_TURN;
                    end
                end

                // Prime renderbuf read latency (rb_data is registered).
                ST_WR_PRIME: begin
                    // Hold rb_bank, rb_addr=0. Next cycle rb_data = byte0.
                    state <= ST_WR_P0;
                end

                // Burst write: one byte per clk (renderbuf -> SRAM).
                // Fast mode: keep CE asserted and hold WE low for the entire burst.
                // Address/data update once per clk; SRAM sees stable values for the full cycle.
                // Note: there is no per-byte recovery cycle; bus is released in ST_TURN.
                ST_WR_P0: begin
                    RamCEn <= 1'b0;
                    RamOEn <= 1'b1;
                    RamWEn <= 1'b0;
                    db_oe  <= 1'b1;

                    MemAdr <= wr_base + wr_i;
                    db_out <= rb_data;

                    if (wr_i == (FB_W - 1)) begin
                        // Done writing the full line.
                        commit_done <= 1'b1;
                        commit_bank <= wr_bank;
                        state <= ST_TURN;
                    end else begin
                        // Advance to next byte. rb_data is registered, so request the next address now and it will be available next cycle.
                        wr_i <= wr_i + 11'd1;
                        rb_addr <= (wr_i[9:0] + 10'd1);
                        state <= ST_WR_P0;
                    end
                end

                // One idle cycle with bus released.

                ST_TURN: begin
                    state <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
