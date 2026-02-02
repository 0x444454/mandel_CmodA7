// Digital joystick handler for generic switch-to-ground joysticks.
//
// Inputs are active-low (COM=GND). Use internal pull-ups in XDC.
// All buttons are debounced (debounce_btn.sv).
//
// Behavior:
// - When SET (action) NOT pressed: UP/DOWN/LEFT/RIGHT generate pan direction levels, and move_tick provides a repeat cadence.
// - When SET (action) IS pressed:
//     - Tap UP/DOWN -> zoom_in_pulse / zoom_out_pulse (one-shot)
//     - Hold LEFT/RIGHT -> iters_dec_pulse / iters_inc_pulse (repeat cadence)
// - RST produces zoom_reset_pulse (one-shot) and rst_zoom level.
//
module joystick_buttons #(
    parameter int CLK_HZ     = 100_000_000,
    parameter int SAMPLE_HZ  = 1000,
    parameter int MOVE_HZ    = 256,
    parameter int ITERS_HZ   = 128
)(
    input  logic clk,
    input  logic rst,           // active-high synchronous reset

    // Raw joystick inputs (active-low, pulled up internally).
    input  logic joy_up_n,
    input  logic joy_down_n,
    input  logic joy_left_n,
    input  logic joy_right_n,
    input  logic joy_set_n,     // SET (button 1).
    input  logic joy_mid_n,     // MID (button 2).
    input  logic joy_rst_n,     // RST (button 3).

    // Debounced levels (active-high).
    output logic up,
    output logic down,
    output logic left,
    output logic right,
    output logic action,
    output logic mid,
    output logic rst_zoom,

    // Pan request + repeat tick.
    output logic move_up,
    output logic move_down,
    output logic move_left,
    output logic move_right,
    output logic move_tick,

    // Action-mode pulses.
    output logic zoom_in_pulse,
    output logic zoom_out_pulse,

    output logic iters_dec_pulse,
    output logic iters_inc_pulse,

    // One-shot reset zoom.
    output logic zoom_reset_pulse
);

    logic up_pulse, down_pulse, left_pulse, right_pulse, action_pulse, mid_pulse, rst_pulse;

    debounce_btn #(.CLK_HZ(CLK_HZ), .SAMPLE_HZ(SAMPLE_HZ)) u_db_up (
        .clk(clk), .rst(rst),
        .in_n(joy_up_n),
        .pressed(up),
        .pulse(up_pulse)
    );

    debounce_btn #(.CLK_HZ(CLK_HZ), .SAMPLE_HZ(SAMPLE_HZ)) u_db_down (
        .clk(clk), .rst(rst),
        .in_n(joy_down_n),
        .pressed(down),
        .pulse(down_pulse)
    );

    debounce_btn #(.CLK_HZ(CLK_HZ), .SAMPLE_HZ(SAMPLE_HZ)) u_db_left (
        .clk(clk), .rst(rst),
        .in_n(joy_left_n),
        .pressed(left),
        .pulse(left_pulse)
    );

    debounce_btn #(.CLK_HZ(CLK_HZ), .SAMPLE_HZ(SAMPLE_HZ)) u_db_right (
        .clk(clk), .rst(rst),
        .in_n(joy_right_n),
        .pressed(right),
        .pulse(right_pulse)
    );

    debounce_btn #(.CLK_HZ(CLK_HZ), .SAMPLE_HZ(SAMPLE_HZ)) u_db_set (
        .clk(clk), .rst(rst),
        .in_n(joy_set_n),
        .pressed(action),
        .pulse(action_pulse)
    );

    debounce_btn #(.CLK_HZ(CLK_HZ), .SAMPLE_HZ(SAMPLE_HZ)) u_db_mid (
        .clk(clk), .rst(rst),
        .in_n(joy_mid_n),
        .pressed(mid),
        .pulse(mid_pulse)
    );

    debounce_btn #(.CLK_HZ(CLK_HZ), .SAMPLE_HZ(SAMPLE_HZ)) u_db_rst (
        .clk(clk), .rst(rst),
        .in_n(joy_rst_n),
        .pressed(rst_zoom),
        .pulse(rst_pulse)
    );

    // Repeat ticks for panning and for iters adjust.
    localparam int MOVE_DIV  = (CLK_HZ / MOVE_HZ);
    localparam int ITERS_DIV = (CLK_HZ / ITERS_HZ);

    logic [$clog2(MOVE_DIV)-1:0]  move_cnt;
    logic [$clog2(ITERS_DIV)-1:0] iters_cnt;
    logic iters_tick;

    always_ff @(posedge clk) begin
        if (rst) begin
            move_cnt  <= '0;
            move_tick <= 1'b0;
        end else begin
            move_tick <= 1'b0;
            if (move_cnt == MOVE_DIV-1) begin
                move_cnt  <= '0;
                move_tick <= 1'b1;
            end else begin
                move_cnt <= move_cnt + 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            iters_cnt  <= '0;
            iters_tick <= 1'b0;
        end else begin
            iters_tick <= 1'b0;
            if (iters_cnt == ITERS_DIV-1) begin
                iters_cnt  <= '0;
                iters_tick <= 1'b1;
            end else begin
                iters_cnt <= iters_cnt + 1'b1;
            end
        end
    end

    // Pan directions only when Action is not pressed.
    always_comb begin
        move_up    = up    & ~action;
        move_down  = down  & ~action;
        move_left  = left  & ~action;
        move_right = right & ~action;
    end

    // When Action IS pressed:
    //   - tap Up/Down to zoom in/out
    //   - hold Left/Right to dec/inc iters (repeat)
    assign zoom_in_pulse   = action & up_pulse;
    assign zoom_out_pulse  = action & down_pulse;

    assign iters_dec_pulse = action & left  & iters_tick;
    assign iters_inc_pulse = action & right & iters_tick;

    // One-shot zoom reset.
    assign zoom_reset_pulse = rst_pulse;

endmodule
