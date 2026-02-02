// Video timing generator for 960x544 @ ~60 Hz.
// NOTE: We use 544 lines instead of 540 to avoid displays thinking this is 1080i (interlaced).
//
// Known-good porches/syncs:
//   Horizontal: 960 + 16 + 96 + 48 = 1120 total
//   Vertical:   544 +  3 +  5 + 14 = 566 total
//
// Sync polarities are active-low (VGA-style negative sync).
//
module video_timing(
    input  logic        clk,
    input  logic        rst,
    output logic [10:0] h_count,
    output logic [9:0]  v_count,
    output logic        hsync,
    output logic        vsync,
    output logic        visible,
    output logic        line_start,   // 1-cycle pulse at start of every line (hc==0)
    output logic        frame_start   // 1-cycle pulse at start of frame (hc==0 && vc==0)
);
    localparam int H_VISIBLE = 960;
    localparam int H_FRONT   = 16;
    localparam int H_SYNC    = 96;
    localparam int H_BACK    = 48;
    localparam int H_TOTAL   = H_VISIBLE + H_FRONT + H_SYNC + H_BACK;   // 1120

    localparam int V_VISIBLE = 544;
    localparam int V_FRONT   = 3;
    localparam int V_SYNC    = 5;
    localparam int V_BACK    = 14;
    localparam int V_TOTAL   = V_VISIBLE + V_FRONT + V_SYNC + V_BACK;   // 566

    logic [10:0] hc;
    logic [9:0]  vc;

    always_ff @(posedge clk) begin
        if (rst) begin
            hc <= 11'd0;
            vc <= 10'd0;
        end
        else begin
            if (hc == (H_TOTAL - 1)) begin
                hc <= 11'd0;
                if (vc == (V_TOTAL - 1)) begin
                    vc <= 10'd0;
                end
                else begin
                    vc <= vc + 10'd1;
                end
            end
            else begin
                hc <= hc + 11'd1;
            end
        end
    end

    assign h_count = hc;
    assign v_count = vc;

    assign line_start  = (hc == 11'd0);
    assign frame_start = (hc == 11'd0) && (vc == 10'd0);

    always_comb begin
        visible = (hc < H_VISIBLE) && (vc < V_VISIBLE);

        // Active-low sync pulses (negative polarity).
        hsync = ~((hc >= (H_VISIBLE + H_FRONT)) && (hc < (H_VISIBLE + H_FRONT + H_SYNC)));
        vsync = ~((vc >= (V_VISIBLE + V_FRONT)) && (vc < (V_VISIBLE + V_FRONT + V_SYNC)));
    end
endmodule
