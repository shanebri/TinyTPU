module accumulation_buffer #(
    parameter int unsigned ROWS       = tpu_pkg::ARRAY_ROWS,
    parameter int unsigned COLS       = tpu_pkg::ARRAY_COLS,
    parameter int unsigned ACC_WIDTH  = tpu_pkg::ACC_WIDTH,
    parameter int unsigned TILE_COUNT = 4,
    parameter int unsigned ADDR_WIDTH =
        (TILE_COUNT <= 1) ? 1 : $clog2(TILE_COUNT)
) (
    input  logic clk,
    input  logic clear,

    input  logic write_en,
    input  logic accumulate,
    input  logic [ADDR_WIDTH-1:0] write_addr,
    input  logic signed [ACC_WIDTH-1:0]
        matrix_c [0:ROWS-1][0:COLS-1],

    input  logic read_en,
    input  logic [ADDR_WIDTH-1:0] read_addr,
    output logic signed [ACC_WIDTH-1:0]
        read_data [0:ROWS-1][0:COLS-1],
    output logic read_valid
);

    // Each address stores one complete tile. Parameters must be positive,
    // and ADDR_WIDTH must be wide enough to address TILE_COUNT entries.
    logic signed [ACC_WIDTH-1:0]
        tile_mem [0:TILE_COUNT-1][0:ROWS-1][0:COLS-1];

    // Synchronous clear has priority over reads and writes.
    // This small, fully parallel buffer is intended for register storage.
    always_ff @(posedge clk) begin
        if (clear) begin
            read_valid <= 1'b0;
            for (int tile = 0; tile < TILE_COUNT; tile++) begin
                for (int row = 0; row < ROWS; row++) begin
                    for (int col = 0; col < COLS; col++) begin
                        tile_mem[tile][row][col] <= '0;
                    end
                end
            end
            for (int row = 0; row < ROWS; row++) begin
                for (int col = 0; col < COLS; col++) begin
                    read_data[row][col] <= '0;
                end
            end
        end else begin
            // Invalid addresses are ignored, including unused encodings
            // when TILE_COUNT is not a power of two.
            if (write_en && (write_addr < TILE_COUNT)) begin
                for (int row = 0; row < ROWS; row++) begin
                    for (int col = 0; col < COLS; col++) begin
                        if (accumulate) begin
                            // Signed addition; overflow wraps at ACC_WIDTH.
                            tile_mem[write_addr][row][col] <=
                                tile_mem[write_addr][row][col]
                                + matrix_c[row][col];
                        end else begin
                            tile_mem[write_addr][row][col] <=
                                matrix_c[row][col];
                        end
                    end
                end
            end

            // Registered read. Without an accepted read, retain the data
            // and deassert valid. A simultaneous read/write to the same
            // address returns the OLD tile (nonblocking assignment rules).
            read_valid <= 1'b0;
            if (read_en && (read_addr < TILE_COUNT)) begin
                read_valid <= 1'b1;
                for (int row = 0; row < ROWS; row++) begin
                    for (int col = 0; col < COLS; col++) begin
                        read_data[row][col] <= tile_mem[read_addr][row][col];
                    end
                end
            end
        end
    end

endmodule : accumulation_buffer
