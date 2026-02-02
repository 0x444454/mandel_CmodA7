// Debounce an active-low button input. Produces a debounced level (pressed=1) and a 1-cycle pulse on press.
//
// Notes:
// - 'in_n' should be pulled up (internal pullup in XDC). Press -> 0.
// - Synchronous, active-high reset.
//
module debounce_btn #(
    parameter int CLK_HZ         = 100_000_000,
    parameter int SAMPLE_HZ      = 1000,
    parameter int STABLE_SAMPLES = 8
)(
    input  logic clk,
    input  logic rst,

    input  logic in_n,       // raw active-low
    output logic pressed,    // debounced active-high
    output logic pulse       // 1 clk pulse on rising edge of pressed
);

    // 2FF synchronizer (avoid metastability).
    logic in_n_ff1, in_n_ff2;
    always_ff @(posedge clk) begin
        if (rst) begin
            in_n_ff1 <= 1'b1;
            in_n_ff2 <= 1'b1;
        end else begin
            in_n_ff1 <= in_n;
            in_n_ff2 <= in_n_ff1;
        end
    end

    localparam int SAMPLE_DIV = (CLK_HZ / SAMPLE_HZ);
    logic [$clog2(SAMPLE_DIV)-1:0] sample_cnt;
    logic sample_tick;

    always_ff @(posedge clk) begin
        if (rst) begin
            sample_cnt  <= '0;
            sample_tick <= 1'b0;
        end else begin
            sample_tick <= 1'b0;
            if (sample_cnt == SAMPLE_DIV-1) begin
                sample_cnt  <= '0;
                sample_tick <= 1'b1;
            end else begin
                sample_cnt <= sample_cnt + 1'b1;
            end
        end
    end

    // Shift register of sampled "pressed" state.
    logic [STABLE_SAMPLES-1:0] hist;

    always_ff @(posedge clk) begin
        if (rst) begin
            hist    <= '0;
            pressed <= 1'b0;
        end else if (sample_tick) begin
            hist <= {hist[STABLE_SAMPLES-2:0], ~in_n_ff2};

            if (&hist) begin
                pressed <= 1'b1;        // stable pressed
            end else if (~|hist) begin
                pressed <= 1'b0;        // stable released
            end
        end
    end

    // Rising-edge pulse of the debounced level.
    logic pressed_d;
    always_ff @(posedge clk) begin
        if (rst) begin
            pressed_d <= 1'b0;
            pulse     <= 1'b0;
        end else begin
            pressed_d <= pressed;
            pulse     <= pressed & ~pressed_d;
        end
    end

endmodule
