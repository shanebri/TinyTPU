module processing_element #(
    parameter int unsigned DATA_WIDTH = tpu_pkg::DATA_WIDTH,
    parameter int unsigned ACC_WIDTH  = tpu_pkg::ACC_WIDTH
) (
    input  logic                         clk,
    input  logic                         clear,
    input  logic                         accumulator_clear,
    input  logic                         compute_en,
    input  logic signed [DATA_WIDTH-1:0]  a_in,
    input  logic signed [DATA_WIDTH-1:0]  b_in,
    output logic signed [DATA_WIDTH-1:0]  a_out,
    output logic signed [DATA_WIDTH-1:0]  b_out,
    output logic signed [ACC_WIDTH-1:0]   accumulator
);
    // Output-stationary MAC: operands move, the partial sum stays here.
    logic signed [2*DATA_WIDTH-1:0] product;
    assign product = a_in * b_in;

    // Priority: synchronous reset, accumulator clear, then computation.
    // Assert clear for at least one rising edge before first use.
    always_ff @(posedge clk) begin
        if (clear) begin
            a_out       <= '0;
            b_out       <= '0;
            accumulator <= '0;
        end else if (accumulator_clear) begin
            // Operand registers hold. The tile controller flushes them
            // separately before starting a new operation.
            accumulator <= '0;
        end else if (compute_en) begin
            a_out       <= a_in;
            b_out       <= b_in;
            // The signed size cast extends or truncates to ACC_WIDTH.
            accumulator <= accumulator + ACC_WIDTH'(product);
        end
    end
endmodule : processing_element
