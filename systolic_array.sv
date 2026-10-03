// Compile tpu_pkg.sv, processing_element.sv, then this file.
//
// Output-stationary dataflow: A travels right, B travels down.
// At enabled step t, feed A[r][t-r] and B[t-c][c], using zero for
// out-of-range indices. Run K + ROWS + COLS - 2 enabled steps for
// matrix_c[r][c] = sum(k=0..K-1) A[r][k] * B[k][c].
// compute_en freezes operands and sums together; pause the input schedule
// too. clear resets operands and sums. accumulator_clear resets only sums.
// Flush operand registers with clear before an independent tile operation.
module systolic_array #(
    parameter int unsigned ROWS       = tpu_pkg::ARRAY_ROWS,
    parameter int unsigned COLS       = tpu_pkg::ARRAY_COLS,
    parameter int unsigned DATA_WIDTH = tpu_pkg::DATA_WIDTH,
    parameter int unsigned ACC_WIDTH  = tpu_pkg::ACC_WIDTH
) (
    input  logic                         clk,
    input  logic                         clear,
    input  logic                         accumulator_clear,
    input  logic                         compute_en,
    input  logic signed [DATA_WIDTH-1:0]  a_in [0:ROWS-1],
    input  logic signed [DATA_WIDTH-1:0]  b_in [0:COLS-1],
    output wire signed [ACC_WIDTH-1:0]    matrix_c [0:ROWS-1][0:COLS-1]
);
    // The extra boundary slot makes edge and interior wiring uniform.
    wire signed [DATA_WIDTH-1:0] a_bus [0:ROWS-1][0:COLS];
    wire signed [DATA_WIDTH-1:0] b_bus [0:ROWS][0:COLS-1];

    generate
        for (genvar col = 0; col < COLS; col++) begin : gen_top_edge
            assign b_bus[0][col] = b_in[col];
        end

        for (genvar row = 0; row < ROWS; row++) begin : gen_rows
            assign a_bus[row][0] = a_in[row];

            for (genvar col = 0; col < COLS; col++) begin : gen_cols
                processing_element #(
                    .DATA_WIDTH (DATA_WIDTH),
                    .ACC_WIDTH  (ACC_WIDTH)
                ) pe (
                    .clk            (clk),
                    .clear          (clear),
                    .accumulator_clear (accumulator_clear),
                    .compute_en     (compute_en),
                    .a_in           (a_bus[row][col]),
                    .b_in           (b_bus[row][col]),
                    .a_out          (a_bus[row][col+1]),
                    .b_out          (b_bus[row+1][col]),
                    .accumulator    (matrix_c[row][col])
                );
            end
        end
    endgenerate
endmodule : systolic_array
