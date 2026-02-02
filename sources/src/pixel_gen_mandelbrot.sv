// Single Mandelbrot "engine" core computing the iterations count for one pixel.
// We instantiate multiple parallel instances, depending on the target FPGA resources.
// On Xilinx Artix 7, each engine uses 6 DSP48E1 resources. 
//
// Fixed-point format Q3.22:
//   - cx_q, cy_q, zx, zy are signed Q(FRAC) values (default FRAC=22).
//   - The escape test compares |z|^2 against 4.0 using full precision Q(2*FRAC).
//
// Handshake:
//   - 'start' asserted for 1 cycle when busy=0 launches a new pixel.
//   - 'busy' stays high while iterating; done pulses for 1 cycle on completion.
//   - 'iters' returns the number of iterations executed (0..max_it-1).
//   - 'is_inside' indicates "did not escape" (reached max_it).
//
module pixel_gen_mandelbrot #(
    parameter int MAX_ITERS = 4095,
    parameter int FRAC = 22
)(
    input  logic                  clk,
    input  logic                  rst,

    input  logic                  start,
    input  logic signed [24:0]    cx_q,       // complex C real, Q(FRAC)
    input  logic signed [24:0]    cy_q,       // complex C imag, Q(FRAC)
    //input  logic [31:0]           t,          // unused (kept for compatibility)
    input  logic [11:0]           max_iters,  // runtime max iters (16..4095), latched per pixel

    output logic                  busy,
    output logic                  done,
    output logic [11:0]           iters,
    output logic                  is_inside
);

    // Mandelbrot formula:
    //   z_{n+1} = z_n^2 + c, starting from z_0 = 0.
    //   Iterate until |z|^2 > 4 (escape) or iter reaches max_it.

    logic signed [24:0] zx;
    logic signed [24:0] zy;
    logic signed [24:0] cx;
    logic signed [24:0] cy;

    logic [15:0] iter;
    logic [11:0] max_it;

    logic signed [49:0] zx_zx_50;
    logic signed [49:0] zy_zy_50;
    logic signed [49:0] zx_zy_50;
    logic signed [50:0] mag2_full;   // zx*zx + zy*zy in Q(2*FRAC)

    logic signed [24:0] zx2;
    logic signed [24:0] zy2;
    logic signed [24:0] two_zxzy;

    logic signed [24:0] zx_next;
    logic signed [24:0] zy_next;
    // Truncated |z|^2 in Q(FRAC). Kept for debugging / experiments.
    logic signed [24:0] mag2_q;

    localparam int signed ESCAPE_Q = (4 <<< FRAC);   // 4.0 in Q(FRAC)
    // Use full-precision (Q(2*FRAC)) escape test to avoid wrap/truncation artifacts (probably overkill).
    localparam longint signed ESCAPE_Q2 = (64'sd4 <<< (2*FRAC));  // 4.0 in Q(2*FRAC)

    always_comb begin
        zx_zx_50 = $signed(zx) * $signed(zx);
        zy_zy_50 = $signed(zy) * $signed(zy);
        zx_zy_50 = $signed(zx) * $signed(zy);

        mag2_full = $signed(zx_zx_50) + $signed(zy_zy_50);
        zx2 = $signed(zx_zx_50 >>> FRAC);
        zy2 = $signed(zy_zy_50 >>> FRAC);
        two_zxzy = $signed(zx_zy_50 >>> (FRAC-1));          // 2*zx*zy

        zx_next = (zx2 - zy2) + cx;
        zy_next = $signed(two_zxzy + cy);

        mag2_q = $signed(zx2 + zy2);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            done <= 1'b0;
            iters <= 12'd0;
            is_inside <= 1'b0;

            zx <= 25'sd0;
            zy <= 25'sd0;
            cx <= 25'sd0;
            cy <= 25'sd0;

            iter <= 16'd0;
            max_it <= MAX_ITERS[11:0];
        end
        else begin
            done <= 1'b0;

            if (start && !busy) begin
                // Init core pixel calculation.
                busy <= 1'b1;
                cx <= cx_q;
                cy <= cy_q;
                // Latch runtime iteration limit for this pixel.
                // Note: Buttons already clamp to [16..4095]; but we defensively clamp min iters here too.
                max_it <= (max_iters < 12'd16) ? 12'd16 : max_iters;
                zx   <= 25'sd0;
                zy   <= 25'sd0;
                iter <= 16'd0;
            end
            else if (busy) begin
                // Core still busy.
                if (mag2_full > ESCAPE_Q2) begin
                    // DONE: Escaped.
                    busy <= 1'b0;
                    done <= 1'b1;
                    iters <= iter[11:0];
                    is_inside <= 1'b0;
                end
                else if (iter[11:0] == (max_it - 12'd1)) begin
                    // DONE: Inside Mandelbrot set.
                    busy <= 1'b0;
                    done <= 1'b1;
                    iters <= iter[11:0];
                    is_inside <= 1'b1;
                end
                else begin
                    // Continue pixel calculation.
                    zx <= zx_next;
                    zy <= zy_next;
                    iter <= iter + 16'd1;
                end
            end
        end
    end
endmodule
