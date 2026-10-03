// Register-backed complete-tile interface; see README for transaction timing.
module tile_engine #(
    parameter int unsigned ROWS = tpu_pkg::ARRAY_ROWS,
    parameter int unsigned COLS = tpu_pkg::ARRAY_COLS,
    parameter int unsigned INNER_DIM = 4,
    parameter int unsigned DATA_WIDTH = tpu_pkg::DATA_WIDTH,
    parameter int unsigned ACC_WIDTH = tpu_pkg::ACC_WIDTH,
    parameter int unsigned TILE_COUNT = 4,
    parameter int unsigned ADDR_WIDTH = (TILE_COUNT <= 1) ? 1 : $clog2(TILE_COUNT)
) (
    input logic clk,
    input logic clear,
    input logic start,
    input logic signed [DATA_WIDTH-1:0] matrix_a [0:ROWS-1][0:INNER_DIM-1],
    input logic signed [DATA_WIDTH-1:0] matrix_b [0:INNER_DIM-1][0:COLS-1],
    input logic [ADDR_WIDTH-1:0] write_addr,
    input logic accumulate,
    output wire accept,
    output wire busy,
    output wire done,
    input logic read_en,
    input logic [ADDR_WIDTH-1:0] read_addr,
    output wire signed [ACC_WIDTH-1:0] read_data [0:ROWS-1][0:COLS-1],
    output wire read_valid
);
    localparam int unsigned STEP_WIDTH =
        (INNER_DIM + ROWS + COLS <= 3) ? 1 : $clog2(INNER_DIM + ROWS + COLS - 2);
    logic signed [DATA_WIDTH-1:0] a_tile [0:ROWS-1][0:INNER_DIM-1];
    logic signed [DATA_WIDTH-1:0] b_tile [0:INNER_DIM-1][0:COLS-1];
    logic [ADDR_WIDTH-1:0] destination;
    logic add_to_tile;
    wire array_clear, compute_en, store_en;
    wire [STEP_WIDTH-1:0] step;
    logic signed [DATA_WIDTH-1:0] a_edge [0:ROWS-1];
    logic signed [DATA_WIDTH-1:0] b_edge [0:COLS-1];
    wire signed [ACC_WIDTH-1:0] result [0:ROWS-1][0:COLS-1];

    // Capture the full transaction. Inputs may change after acceptance.
    // These registers need no reset: they are read only after accept.
    always_ff @(posedge clk) begin
        if (accept) begin
            destination <= write_addr;
            add_to_tile <= accumulate;
            for (int r = 0; r < ROWS; r++)
                for (int k = 0; k < INNER_DIM; k++)
                    a_tile[r][k] <= matrix_a[r][k];
            for (int k = 0; k < INNER_DIM; k++)
                for (int c = 0; c < COLS; c++)
                    b_tile[k][c] <= matrix_b[k][c];
        end
    end

    // Row/column skew makes operands with the same k meet at each PE.
    always_comb begin
        for (int r = 0; r < ROWS; r++) begin
            a_edge[r] = '0;
            if (compute_en && (int'(step) >= r) && (int'(step) - r < INNER_DIM))
                a_edge[r] = a_tile[r][int'(step) - r];
        end
        for (int c = 0; c < COLS; c++) begin
            b_edge[c] = '0;
            if (compute_en && (int'(step) >= c) && (int'(step) - c < INNER_DIM))
                b_edge[c] = b_tile[int'(step) - c][c];
        end
    end

    tile_controller #(
        .ROWS(ROWS), .COLS(COLS), .INNER_DIM(INNER_DIM),
        .TILE_COUNT(TILE_COUNT), .ADDR_WIDTH(ADDR_WIDTH), .STEP_WIDTH(STEP_WIDTH)
    ) controller (
        .clk(clk), .clear(clear), .start(start), .write_addr(write_addr),
        .accept(accept), .busy(busy), .done(done), .array_clear(array_clear),
        .compute_en(compute_en), .store_en(store_en), .step(step)
    );

    systolic_array #(
        .ROWS(ROWS), .COLS(COLS), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)
    ) array_core (
        .clk(clk), .clear(array_clear), .accumulator_clear(1'b0),
        .compute_en(compute_en), .a_in(a_edge), .b_in(b_edge), .matrix_c(result)
    );

    accumulation_buffer #(
        .ROWS(ROWS), .COLS(COLS), .ACC_WIDTH(ACC_WIDTH),
        .TILE_COUNT(TILE_COUNT), .ADDR_WIDTH(ADDR_WIDTH)
    ) buffer_core (
        .clk(clk), .clear(clear), .write_en(store_en), .accumulate(add_to_tile),
        .write_addr(destination), .matrix_c(result), .read_en(read_en),
        .read_addr(read_addr), .read_data(read_data), .read_valid(read_valid)
    );
endmodule : tile_engine
