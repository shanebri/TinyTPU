// Compile tpu_pkg.sv, processing_element.sv, then this file.
//
// Loading: after clear, assert weights_loaded for ROWS rising edges.
// Present one row of weights on b_in each edge, bottom row first and top
// row last. Every column shifts independently. Deassert weights_loaded
// to hold those weights and begin computing; b_in is then ignored.
//
// Computation: a_in[r] enters row r from the left and advances one column
// per rising edge. Each PE accumulates its incoming activation times its
// own stored weight. Column c consumes an activation c cycles after column
// zero. Feed zeros for COLS-1 trailing cycles to drain the activation path,
// and keep feeding zeros to retain the result. No valid/done is generated.
//
// matrix_c exposes the local accumulators, with no reduction across rows.
// A full matrix-multiplication schedule/reduction is outside this module.
// clear resets accumulators AND stored weights, so reload after clearing.
module systolic_array #(
    parameter int unsigned ROWS       = tpu_pkg::ARRAY_ROWS,
    parameter int unsigned COLS       = tpu_pkg::ARRAY_COLS,
    parameter int unsigned DATA_WIDTH = tpu_pkg::DATA_WIDTH,
    parameter int unsigned ACC_WIDTH  = tpu_pkg::ACC_WIDTH
) (
    input  logic                         clk,
    input  logic                         clear,
    input  logic                         weights_loaded,
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
                    .weights_loaded (weights_loaded),
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
