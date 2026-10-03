// Sequences one output-stationary tile. All controls are synchronous.
module tile_controller #(
    parameter int unsigned ROWS = tpu_pkg::ARRAY_ROWS,
    parameter int unsigned COLS = tpu_pkg::ARRAY_COLS,
    parameter int unsigned INNER_DIM = 4,
    parameter int unsigned TILE_COUNT = 4,
    parameter int unsigned ADDR_WIDTH = (TILE_COUNT <= 1) ? 1 : $clog2(TILE_COUNT),
    parameter int unsigned STEP_WIDTH =
        (INNER_DIM + ROWS + COLS <= 3) ? 1 : $clog2(INNER_DIM + ROWS + COLS - 2)
) (
    input logic clk,
    input logic clear,
    input logic start,
    input logic [ADDR_WIDTH-1:0] write_addr,
    output logic accept,
    output logic busy,
    output logic done,
    output logic array_clear,
    output logic compute_en,
    output logic store_en,
    output logic [STEP_WIDTH-1:0] step
);
    localparam int unsigned FEED_STEPS = INNER_DIM + ((ROWS > COLS) ? ROWS : COLS) - 1;
    localparam int unsigned TOTAL_STEPS = INNER_DIM + ROWS + COLS - 2;
    typedef enum logic [2:0] {IDLE, CLEAR, COMPUTE, DRAIN, STORE, DONE} state_t;
    state_t state;

    always_comb begin
        accept = !clear && (state == IDLE) && start && (write_addr < TILE_COUNT);
        busy = !clear && (state != IDLE);
        done = !clear && (state == DONE);
        array_clear = clear || (state == CLEAR);
        compute_en = !clear && ((state == COMPUTE) || (state == DRAIN));
        store_en = !clear && (state == STORE);
    end

    always_ff @(posedge clk) begin
        if (clear) begin
            state <= IDLE;
            step <= '0;
        end else begin
            case (state)
                IDLE: if (accept) begin
                    step <= '0;
                    state <= CLEAR;
                end
                CLEAR: state <= COMPUTE;
                COMPUTE: begin
                    if (step == STEP_WIDTH'(FEED_STEPS - 1)) begin
                        if (FEED_STEPS == TOTAL_STEPS)
                            state <= STORE;
                        else begin
                            step <= step + 1'b1;
                            state <= DRAIN;
                        end
                    end else step <= step + 1'b1;
                end
                DRAIN: begin
                    if (step == STEP_WIDTH'(TOTAL_STEPS - 1)) state <= STORE;
                    else step <= step + 1'b1;
                end
                STORE: state <= DONE;
                DONE: state <= IDLE;
                default: begin
                    state <= IDLE;
                    step <= '0;
                end
            endcase
        end
    end
endmodule : tile_controller
