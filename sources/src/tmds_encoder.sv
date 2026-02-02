//------------------------------------------------------------------------------
// tmds_encoder.sv
//
// 8b/10b TMDS encoder (DVI/HDMI-style).
//
// Implements the standard two-stage algorithm:
//   1) transition-minimized XOR/XNOR stage (q_m) based on input popcount
//   2) running-disparity stage (q_out) to balance DC with minimal extra flips
//
// During blanking (vde=0), outputs one of four fixed control tokens based on cd.
// In this project cd is {VSYNC,HSYNC} on channel 0 and 2'b00 on channels 1/2.
//------------------------------------------------------------------------------

module tmds_encoder(
    input  logic       clk,
    input  logic       rst,     // active-high synchronous reset

    input  logic [7:0] vd,      // video data
    input  logic [1:0] cd,      // control data (hsync/vsync on channel 0)
    input  logic       vde,     // video data enable

    output logic [9:0] tmds
);
    // Control period codes (DVI/HDMI TMDS), per DVI 1.0.
    localparam logic [9:0] CTL0 = 10'b1101010100; // CD=00
    localparam logic [9:0] CTL1 = 10'b0010101011; // CD=01
    localparam logic [9:0] CTL2 = 10'b0101010100; // CD=10
    localparam logic [9:0] CTL3 = 10'b1010101011; // CD=11

    // Keep these narrow so synthesis won't waste DSP48s on arithmetic.
    logic signed [6:0] rd; // running disparity (small magnitude)

    function automatic logic [3:0] popcount8(input logic [7:0] v);
        logic [3:0] n;
        begin
            n = 4'd0;
            for (int i = 0; i < 8; i++) begin
                n = n + v[i];
            end
            return n;
        end
    endfunction

    function automatic logic [4:0] popcount10(input logic [9:0] v);
        logic [4:0] n;
        begin
            n = 5'd0;
            for (int i = 0; i < 10; i++) begin
                n = n + v[i];
            end
            return n;
        end
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            tmds <= 10'd0;
            rd   <= '0;
        end else begin
            if (!vde) begin
                // Control period: output fixed code, reset disparity.
                unique case (cd)
                    2'b00: tmds <= CTL0;
                    2'b01: tmds <= CTL1;
                    2'b10: tmds <= CTL2;
                    default: tmds <= CTL3;
                endcase
                rd <= '0;
            end else begin
                // Video period.
                logic [8:0] q_m;
                logic [9:0] q_out;

                logic [3:0]        n1d;
                logic [3:0]        n1qm;
                logic signed [4:0] balance;   // -4..+4

                logic [4:0]        ones10;
                logic signed [5:0] ones10x2;
                logic signed [5:0] disp;      // -10..+10

                logic use_xnor;
                logic invert;

                n1d = popcount8(vd);

                // Decide XOR vs XNOR stage.
                use_xnor = (n1d > 4) || ((n1d == 4) && (vd[0] == 1'b0));

                // Build q_m[0..7] (transition minimized), and q_m[8].
                q_m[0] = vd[0];
                for (int i = 1; i < 8; i++) begin
                    if (use_xnor) begin
                        q_m[i] = ~(q_m[i-1] ^ vd[i]);
                    end else begin
                        q_m[i] =  (q_m[i-1] ^ vd[i]);
                    end
                end
                q_m[8] = ~use_xnor;

                n1qm    = popcount8(q_m[7:0]);
                balance = $signed({1'b0, n1qm}) - 5'sd4;

                if ((rd == 0) || (balance == 0)) begin
                    // Special case: choose based on q_m[8]
                    q_out[9] = ~q_m[8];
                    q_out[8] =  q_m[8];
                    if (q_m[8]) begin
                        q_out[7:0] = q_m[7:0];
                    end else begin
                        q_out[7:0] = ~q_m[7:0];
                    end
                end else begin
                    invert = ((rd > 0) && (balance > 0)) || ((rd < 0) && (balance < 0));
                    if (invert) begin
                        q_out[9]   = 1'b1;
                        q_out[8]   = q_m[8];
                        q_out[7:0] = ~q_m[7:0];
                    end else begin
                        q_out[9]   = 1'b0;
                        q_out[8]   = q_m[8];
                        q_out[7:0] = q_m[7:0];
                    end
                end

                tmds <= q_out;

                // Update running disparity using the actual 10-bit output.
                ones10   = popcount10(q_out);
                ones10x2 = $signed({1'b0, ones10}) <<< 1;
                disp     = ones10x2 - 6'sd10;
                rd <= rd + disp;
            end
        end
    end

endmodule
