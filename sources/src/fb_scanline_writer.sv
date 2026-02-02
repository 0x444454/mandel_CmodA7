// Out-of-order Mandelbrot renderer and scanline scheduler.
//
// Summary:
//   - Issues pixels coordinates in scanline order to free NCORES.
//   - NCORES engines run in parallel; results can complete out-of-order.
//   - Retires results into a 2-line BRAM write buffer (iter8).
//   - External SRAM writes are performed by sram_line_dma.sv on whole-line boundaries.
//

module fb_scanline_writer #(
    // Notes:
    //   - NCORES=15 fits the XC7A35T DSP budget (each core uses 6 DSP48E1). Change to 7 for XC7A15T.
    //   - The video path does palette lookup during scanout; we store only iter8 (lowest 8 bits of pixel iteration count).
    //   - Pixels are issued in scanline order, but retired out-of-order.
    //   - At most two render lines are in-flight (bank 0/1).
    //     If both are full, pixel issue stalls until a bank is committed to the SRAM framebuffer and freed.
    parameter int NCORES = 15,
    parameter int FB_W   = 960,
    parameter int FB_H   = 544,
    parameter int FRAC   = 22
)(
    input  logic                    clk,
    input  logic                    rst,

    // Write buffer port (iter8). One pixel retired per cycle max.
    output logic                    wb_we,
    output logic                    wb_bank,
    output logic [9:0]              wb_addr,
    output logic [7:0]              wb_data,

    // Per-bank status (visible to the SRAM DMA).
    output logic                    wb_full0,
    output logic                    wb_full1,
    output logic [9:0]              wb_y0,
    output logic [9:0]              wb_y1,

    // Commit handshake from SRAM DMA.
    input  logic                    commit_take, // DMA is starting a commit of wb_bank.
    input  logic                    commit_done, // DMA finished commit of wb_bank and the bank can be reused.
    input  logic                    commit_bank, // Bank to commit [0 or 1].

    input  logic [31:0]             t,
    input  logic signed [24:0]      center_x_q,
    input  logic signed [24:0]      center_y_q,
    input  logic signed [24:0]      scale_q,
    input  logic                    restart,
    input  logic [11:0]             iters_q,

    output logic [$clog2(FB_H)-1:0] cur_y,
    output logic                    render_busy
);

    localparam int ADDR_W = $clog2(FB_W*FB_H);
    localparam int X_W    = $clog2(FB_W);
    localparam int Y_W    = $clog2(FB_H);

    // -------------------------------------------------------------------------
    // Multiply scale by (FB_W/2) or (FB_H/2) to find the upper-left corner.
    // Shift/add only (no '*') to avoid consuming DSP resources.
    // -------------------------------------------------------------------------
    localparam logic [9:0] HALF_W = (FB_W / 2);
    localparam logic [9:0] HALF_H = (FB_H / 2);

    function automatic logic signed [24:0] mul_const_u10(input logic signed [24:0] s, input logic [9:0] k);
        logic signed [39:0] s40;
        logic signed [39:0] acc;
        int b;
        begin
            s40 = {{(40-25){s[24]}}, s};
            acc = 40'sd0;
            for (b = 0; b < 10; b = b + 1) begin
                if (k[b]) acc = acc + (s40 <<< b);
            end
            mul_const_u10 = $signed(acc[24:0]);
        end
    endfunction

    // -------------------------------------------------------------------------
    // Bank tracking.
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        B_FREE   = 2'd0,
        B_FILL   = 2'd1,
        B_FULL   = 2'd2,
        B_COMMIT = 2'd3
    } bank_state_t;

    bank_state_t bank_state [2];
    logic [9:0]  bank_y     [2];
    logic [10:0] bank_done  [2];   // 0..FB_W

    // Expose status.
    assign wb_full0 = (bank_state[0] == B_FULL);
    assign wb_full1 = (bank_state[1] == B_FULL);
    assign wb_y0    = bank_y[0];
    assign wb_y1    = bank_y[1];

    // -------------------------------------------------------------------------
    // Render control / coordinate generator (scanline order)
    // -------------------------------------------------------------------------
    logic rendering;
    logic need_render;

    logic [X_W-1:0]       issue_x;
    logic [Y_W-1:0]       issue_y;

    logic signed [24:0]   ax_q;
    logic signed [24:0]   ay_q;
    logic signed [24:0]   cur_cx_q;
    logic signed [24:0]   cur_cy_q;

    logic signed [24:0]   center_x_prev;
    logic signed [24:0]   center_y_prev;
    logic signed [24:0]   scale_prev;

    // -------------------------------------------------------------------------
    // Mandelbrot cores + handling logic
    // -------------------------------------------------------------------------
    logic [NCORES-1:0] core_start;
    logic [NCORES-1:0] core_launched;
    logic [NCORES-1:0] core_busy;
    logic [NCORES-1:0] core_done;

    logic signed [24:0] core_cx_q   [NCORES];
    logic signed [24:0] core_cy_q   [NCORES];
    logic [11:0]        core_iters  [NCORES];
    logic [NCORES-1:0]  core_is_inside;

    // Render generation tag (prevents committing stale pixels after a restart).
    logic [1:0]         gen;
    logic [1:0]         core_gen [NCORES];

    // Request metadata (where to store the result).
    logic [X_W-1:0]     core_req_x   [NCORES];
    logic [Y_W-1:0]     core_req_y   [NCORES];
    logic               core_req_bank[NCORES];

    // Completed results latch.
    logic [NCORES-1:0]  res_valid;
    logic [X_W-1:0]     res_x    [NCORES];
    logic               res_bank [NCORES];
    logic [7:0]         res_iter8[NCORES];

    // Create Mandel cores.
    genvar gi;
    generate
        for (gi = 0; gi < NCORES; gi = gi + 1) begin : G_PX
            pixel_gen_mandelbrot #(
                .MAX_ITERS(4095),
                .FRAC(FRAC)
            ) u_px (
                .clk(clk),
                .rst(rst),

                .start(core_start[gi]),
                .cx_q(core_cx_q[gi]),
                .cy_q(core_cy_q[gi]),
                //.t(t),
                .max_iters(iters_q),

                .busy(core_busy[gi]),
                .done(core_done[gi]),
                .iters(core_iters[gi]),
                .is_inside(core_is_inside[gi])
            );
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Pick one completed result to retire (lowest index wins).
    // -------------------------------------------------------------------------
    logic                      cand_any;
    logic [$clog2(NCORES)-1:0] cand_sel;

    integer k;
    always_comb begin
        cand_any = 1'b0;
        cand_sel = '0;
        for (k = 0; k < NCORES; k = k + 1) begin
            if (!cand_any && res_valid[k]) begin
                cand_any = 1'b1;
                cand_sel = k[$clog2(NCORES)-1:0];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Main control.
    // -------------------------------------------------------------------------
    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            // Reset cores.
            rendering   <= 1'b0;
            need_render <= 1'b1;

            issue_x <= '0;
            issue_y <= '0;

            ax_q     <= 25'sd0;
            ay_q     <= 25'sd0;
            cur_cx_q <= 25'sd0;
            cur_cy_q <= 25'sd0;

            center_x_prev <= 25'sd0;
            center_y_prev <= 25'sd0;
            scale_prev    <= 25'sd0;

            core_start    <= '0;
            core_launched <= '0;

            gen <= 2'd0;

            wb_we   <= 1'b0;
            wb_bank <= 1'b0;
            wb_addr <= 10'd0;
            wb_data <= 8'd0;

            bank_state[0] <= B_FREE;
            bank_state[1] <= B_FREE;
            bank_y[0]     <= 10'd0;
            bank_y[1]     <= 10'd0;
            bank_done[0]  <= 11'd0;
            bank_done[1]  <= 11'd0;

            for (i = 0; i < NCORES; i = i + 1) begin
                core_cx_q[i]      <= 25'sd0;
                core_cy_q[i]      <= 25'sd0;
                core_req_x[i]     <= '0;
                core_req_y[i]     <= '0;
                core_req_bank[i]  <= 1'b0;
                res_valid[i]      <= 1'b0;
                res_x[i]          <= '0;
                res_bank[i]       <= 1'b0;
                res_iter8[i]      <= 8'd0;
                core_gen[i]       <= 2'd0;
            end
        end else begin
            // Default.
            core_start <= '0;
            wb_we      <= 1'b0;

            // Bank state updates from the SRAM commit side.
            //
            // The DMA (sram_line_dma) asserts:
            // - commit_take when it starts consuming a full bank.
            // - commit_done when that bank has been written to external SRAM.
            // Once commit_done is observed the bank is safe to reuse for new rendering.

            if (commit_take) begin
                bank_state[commit_bank] <= B_COMMIT;
            end
            if (commit_done) begin
                bank_state[commit_bank] <= B_FREE;
                bank_y[commit_bank]     <= 10'd0;
                bank_done[commit_bank]  <= 11'd0;
            end

            // core_launched is a 1-cycle helper that prevents double-launching a core (race-condition) before its busy flag is observed.
            // Once busy goes high we can clear launched.

            for (i = 0; i < NCORES; i = i + 1) begin
                if (core_launched[i] && core_busy[i]) begin
                    core_launched[i] <= 1'b0;
                end
            end

            // Latch completed results.
            //
            // Each core has request metadata captured at launch time (x, y, bank).
            // When done pulses, capture the result into a per-core holding register (res_*). 
            // A later stage retires at most one res_* per clk into WB.
            //
            // gen/core_gen is a small generation tag: when we restart (pan/zoom/iters),
            // we bump gen and ignore any late completions from the previous generation.

            for (i = 0; i < NCORES; i = i + 1) begin
                if (core_done[i] && (core_gen[i] == gen)) begin
                    res_valid[i] <= 1'b1;
                    res_x[i]     <= core_req_x[i];
                    res_bank[i]  <= core_req_bank[i];
                    if (core_is_inside[i]) begin
                        res_iter8[i] <= 8'd0; // Black.
                    end else begin
                        // +1 so low iteration counts don't map to Black.
                        if (core_iters[i][7:0] != 8'hFF) begin
                            res_iter8[i] <= core_iters[i][7:0] + 8'd1;
                        end else begin
                            res_iter8[i] <= 8'hFF;
                        end
                    end
                end
            end

            // Retire [at most] one completed result into the write buffer per cycle.
            // Retire policy:
            // - At most one pixel per clk.
            // - We pick the lowest-index core that has res_valid=1 and write its iter8 value into the BRAM write buffer
            // at address {bank, x}.

            if (cand_any) begin
                wb_we   <= 1'b1;
                wb_bank <= res_bank[cand_sel];
                wb_addr <= {{(10-X_W){1'b0}}, res_x[cand_sel]};
                wb_data <= res_iter8[cand_sel];

                // Mark retired.
                res_valid[cand_sel] <= 1'b0;

                // Update per-bank completion count.
                // bank_done[] counts how many pixels have been retired for that bank.
                // When it reaches FB_W, the bank becomes FULL and waits for DMA commit.

                if (bank_state[res_bank[cand_sel]] == B_FILL) begin
                    if (bank_done[res_bank[cand_sel]] == (FB_W - 1)) begin
                        bank_done[res_bank[cand_sel]]  <= bank_done[res_bank[cand_sel]] + 11'd1;
                        bank_state[res_bank[cand_sel]] <= B_FULL;
                    end else begin
                        bank_done[res_bank[cand_sel]] <= bank_done[res_bank[cand_sel]] + 11'd1;
                    end
                end
            end

            // Start a new render if parameters changed or user action requested.
            if (restart || (center_x_q != center_x_prev) || (center_y_q != center_y_prev) || (scale_q != scale_prev)) begin
                // Restart render.
                need_render <= 1'b1;
                rendering   <= 1'b0;

                gen <= gen + 2'd1;

                // Flush in-flight work/results (cores may still be running; we'll ignore mismatched gen).
                for (i = 0; i < NCORES; i = i + 1) begin
                    res_valid[i]      <= 1'b0;
                    core_launched[i]  <= 1'b0;
                end

                // Reset banks state.
                bank_state[0] <= B_FREE;
                bank_state[1] <= B_FREE;
                bank_done[0]  <= 11'd0;
                bank_done[1]  <= 11'd0;
                bank_y[0]     <= 10'd0;
                bank_y[1]     <= 10'd0;

                center_x_prev <= center_x_q;
                center_y_prev <= center_y_q;
                scale_prev    <= scale_q;
            end else begin
                // Continue render.
                center_x_prev <= center_x_q;
                center_y_prev <= center_y_q;
                scale_prev    <= scale_q;
            end

            // (Re)initialize render if needed and we're not currently rendering.
            if (need_render && !rendering) begin
                ax_q <= center_x_q - mul_const_u10(scale_q, HALF_W);
                ay_q <= center_y_q - mul_const_u10(scale_q, HALF_H);

                cur_cx_q <= center_x_q - mul_const_u10(scale_q, HALF_W);
                cur_cy_q <= center_y_q - mul_const_u10(scale_q, HALF_H);

                issue_x <= '0;
                issue_y <= '0;

                rendering   <= 1'b1;
                need_render <= 1'b0;
            end

            // Schedule at most 1 new pixel per cycle.
            if (rendering) begin
                // Allocate a bank for the current issue_y if needed.
                // NOTE: All block-scoped declarations must appear before any statements in this scope (Vivado is strict about this).
                logic have_bank;
                logic bank_sel;
                logic have_free;
                logic [$clog2(NCORES)-1:0] free_idx;

                have_bank = 1'b0;
                bank_sel  = 1'b0;
                have_free = 1'b0;
                free_idx  = '0;

                if (bank_state[0] != B_FREE && bank_y[0][Y_W-1:0] == issue_y) begin
                    have_bank = 1'b1;
                    bank_sel  = 1'b0;
                end else if (bank_state[1] != B_FREE && bank_y[1][Y_W-1:0] == issue_y) begin
                    have_bank = 1'b1;
                    bank_sel  = 1'b1;
                end else begin
                    // Need a new bank for this line (issue_y). Prefer bank0, then bank1.
                    if (bank_state[0] == B_FREE) begin
                        bank_state[0] <= B_FILL;
                        bank_y[0]     <= {{(10-Y_W){1'b0}}, issue_y};
                        bank_done[0]  <= 11'd0;
                        have_bank     = 1'b1;
                        bank_sel      = 1'b0;
                    end else if (bank_state[1] == B_FREE) begin
                        bank_state[1] <= B_FILL;
                        bank_y[1]     <= {{(10-Y_W){1'b0}}, issue_y};
                        bank_done[1]  <= 11'd0;
                        have_bank     = 1'b1;
                        bank_sel      = 1'b1;
                    end
                end

                // Find first free core.
                for (i = 0; i < NCORES; i = i + 1) begin
                    if (!have_free && (!core_busy[i]) && (!core_launched[i]) && (!res_valid[i]) && (!core_done[i])) begin
                        have_free = 1'b1;
                        free_idx  = i[$clog2(NCORES)-1:0];
                    end
                end

                // Launch one pixel if we still have work left and a bank is available.
                if (have_bank && have_free && (issue_y < FB_H)) begin
                    core_start[free_idx]    <= 1'b1;
                    core_launched[free_idx] <= 1'b1;
                    core_gen[free_idx]      <= gen;

                    core_cx_q[free_idx]     <= cur_cx_q;
                    core_cy_q[free_idx]     <= cur_cy_q;
                    core_req_x[free_idx]    <= issue_x;
                    core_req_y[free_idx]    <= issue_y;
                    core_req_bank[free_idx] <= bank_sel;

                    // Advance to next pixel in scanline order.
                    if (issue_x == (FB_W - 1)) begin
                        issue_x  <= '0;
                        issue_y  <= issue_y + 1'b1;
                        cur_cx_q <= ax_q;
                        cur_cy_q <= cur_cy_q + $signed(scale_q);
                    end else begin
                        issue_x  <= issue_x + 1'b1;
                        cur_cx_q <= cur_cx_q + $signed(scale_q);
                    end
                end

                // Done condition: once we have issued the last pixel, wait for all cores and any pending res_* slots to drain before deasserting rendering.
                if (issue_y >= FB_H) begin
                    logic any_active;
                    any_active = (|core_busy) | (|core_launched) | (|res_valid);
                    if (!any_active) begin
                        rendering <= 1'b0; // Frame calculation completed.
                    end
                end
            end
        end
    end

    assign cur_y = issue_y;

    // Busy indicator for UI/debug (e.g. RGB LED): asserted while any work is pending for the current view, including full lines waiting to be committed to SRAM.
    logic any_active;
    assign any_active = (|core_busy) | (|core_launched) | (|res_valid);
    assign render_busy = need_render | rendering | any_active | wb_full0 | wb_full1;

endmodule
