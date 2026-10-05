// AXI4-Lite peripheral for an Arty A7 MicroBlaze block design.
// Fixed workload: C[4][4] = A[4][4] * B[4][4], signed int8 -> int32.
// No board pins or UART here. See docs/benchmarking.md for register map.
module arty_top #(
    parameter int unsigned CLK_HZ = 100_000_000,
    parameter int unsigned MAX_REPETITIONS = 1_000_000
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK",
       X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET s_axi_aresetn" *)
    input logic s_axi_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST",
       X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input logic s_axi_aresetn,
    input logic [7:0] s_axi_awaddr,
    input logic [2:0] s_axi_awprot,
    input logic s_axi_awvalid,
    output wire s_axi_awready,
    input logic [31:0] s_axi_wdata,
    input logic [3:0] s_axi_wstrb,
    input logic s_axi_wvalid,
    output wire s_axi_wready,
    output logic [1:0] s_axi_bresp,
    output logic s_axi_bvalid,
    input logic s_axi_bready,
    input logic [7:0] s_axi_araddr,
    input logic [2:0] s_axi_arprot,
    input logic s_axi_arvalid,
    output wire s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0] s_axi_rresp,
    output logic s_axi_rvalid,
    input logic s_axi_rready
);
    // PROT is intentionally unused; this peripheral has no security domains.
    wire clk = s_axi_aclk;
    wire reset = !s_axi_aresetn;
    typedef enum logic [2:0] {IDLE, LAUNCH, RUN, READ_TILE, WAIT_TILE} state_t;
    state_t state;
    logic [31:0] a_words [0:3], b_words [0:3], result_words [0:15];
    wire signed [7:0] a [0:3][0:3], b [0:3][0:3];
    wire signed [31:0] tile_result [0:3][0:3];
    logic [31:0] repetitions, completed, kernel_cycles;
    logic [63:0] ticks, first_accept, last_accept, batch_cycles;
    logic done_flag, error_flag, abort_pulse;
    wire accept, engine_done, read_valid;
    wire running = state != IDLE;
    for (genvar r = 0; r < 4; r++) begin : unpack_rows
        for (genvar c = 0; c < 4; c++) begin : unpack_cols
            assign a[r][c] = a_words[r][c*8 +: 8];
            assign b[r][c] = b_words[r][c*8 +: 8];
        end
    end
    tile_engine #(.ROWS(4), .COLS(4), .INNER_DIM(4), .DATA_WIDTH(8),
                  .ACC_WIDTH(32), .TILE_COUNT(1), .ADDR_WIDTH(1)) engine (
        .clk(clk), .clear(reset || abort_pulse), .start(state == LAUNCH),
        .matrix_a(a), .matrix_b(b), .write_addr(1'b0), .accumulate(1'b0),
        .accept(accept), .busy(), .done(engine_done),
        .read_en(state == READ_TILE), .read_addr(1'b0),
        .read_data(tile_result), .read_valid(read_valid)
    );
    // Independent AW/W buffering supports either arrival order. Responses
    // remain stable under backpressure. One outstanding read and write each.
    logic aw_pending, w_pending;
    logic [7:0] write_address;
    logic [31:0] write_data;
    logic [3:0] write_strobes;
    assign s_axi_awready = s_axi_aresetn && !aw_pending && !s_axi_bvalid;
    assign s_axi_wready = s_axi_aresetn && !w_pending && !s_axi_bvalid;
    assign s_axi_arready = s_axi_aresetn && !s_axi_rvalid;
    function automatic logic [31:0] merge_bytes(
        input logic [31:0] old_value, new_value, input logic [3:0] strobes);
        logic [31:0] merged;
        merged = old_value;
        for (int j = 0; j < 4; j++)
            if (strobes[j]) merged[j*8 +: 8] = new_value[j*8 +: 8];
        return merged;
    endfunction
    always_ff @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            aw_pending <= 0;
            w_pending <= 0;
            write_address <= 0;
            write_data <= 0;
            write_strobes <= 0;
            s_axi_bvalid <= 0;
            s_axi_bresp <= 0;
            s_axi_rvalid <= 0;
            s_axi_rresp <= 0;
            s_axi_rdata <= 0;
            repetitions <= 1;
            completed <= 0;
            kernel_cycles <= 0;
            batch_cycles <= 0;
            ticks <= 0;
            first_accept <= 0;
            last_accept <= 0;
            done_flag <= 0;
            error_flag <= 0;
            abort_pulse <= 0;
            for (int j = 0; j < 4; j++) begin a_words[j] <= 0; b_words[j] <= 0; end
            for (int j = 0; j < 16; j++) result_words[j] <= 0;
        end else begin
            ticks <= ticks + 1'b1;
            abort_pulse <= 0;
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 0;
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 0;
            if (s_axi_awvalid && s_axi_awready) begin
                write_address <= s_axi_awaddr;
                aw_pending <= 1;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                write_data <= s_axi_wdata;
                write_strobes <= s_axi_wstrb;
                w_pending <= 1;
            end
            case (state)
                LAUNCH: if (accept) begin
                    if (completed == 0) first_accept <= ticks;
                    last_accept <= ticks;
                    state <= RUN;
                end
                RUN: if (engine_done) begin
                    // Registered observer sees DONE one edge after commit.
                    kernel_cycles <= 32'(ticks - last_accept - 1);
                    completed <= completed + 1'b1;
                    if (completed + 1 == repetitions) begin
                        batch_cycles <= ticks - first_accept - 1;
                        state <= READ_TILE;
                    end else state <= LAUNCH;
                end
                READ_TILE: state <= WAIT_TILE;
                WAIT_TILE: if (read_valid) begin
                    for (int r = 0; r < 4; r++)
                        for (int c = 0; c < 4; c++) result_words[r*4+c] <= tile_result[r][c];
                    done_flag <= 1;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
            if (aw_pending && w_pending && !s_axi_bvalid) begin
                aw_pending <= 0;
                w_pending <= 0;
                s_axi_bvalid <= 1;
                s_axi_bresp <= 2'b00;
                if (write_address[1:0] != 0) begin
                    s_axi_bresp <= 2'b11;
                    error_flag <= 1;
                end else if (write_address == 8'h00) begin
                    // CLEAR takes precedence and may abort an active batch.
                    if (write_strobes[0] && write_data[1]) begin
                        state <= IDLE;
                        abort_pulse <= 1;
                        completed <= 0;
                        kernel_cycles <= 0;
                        batch_cycles <= 0;
                        done_flag <= 0;
                        error_flag <= 0;
                        for (int j = 0; j < 16; j++) result_words[j] <= 0;
                    end else if (write_strobes[0] && write_data[0]) begin
                        if (running || repetitions == 0 || repetitions > MAX_REPETITIONS) begin
                            s_axi_bresp <= 2'b10;
                            error_flag <= 1;
                        end else begin
                            state <= LAUNCH;
                            completed <= 0;
                            kernel_cycles <= 0;
                            batch_cycles <= 0;
                            done_flag <= 0;
                            error_flag <= 0;
                            for (int j = 0; j < 16; j++) result_words[j] <= 0;
                        end
                    end
                end else if (write_address == 8'h08 ||
                             (write_address >= 8'h40 && write_address <= 8'h5c)) begin
                    if (running) begin
                        s_axi_bresp <= 2'b10;
                        error_flag <= 1;
                    end else if (write_address == 8'h08)
                        repetitions <= merge_bytes(repetitions, write_data, write_strobes);
                    else if (write_address < 8'h50)
                        a_words[write_address[3:2]] <= merge_bytes(a_words[write_address[3:2]], write_data, write_strobes);
                    else b_words[write_address[3:2]] <= merge_bytes(b_words[write_address[3:2]], write_data, write_strobes);
                end else begin
                    s_axi_bresp <= 2'b11;
                    error_flag <= 1;
                end
            end
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1;
                s_axi_rresp <= 0;
                s_axi_rdata <= 0;
                if (s_axi_araddr[1:0] != 0) s_axi_rresp <= 2'b11;
                else case (s_axi_araddr)
                    8'h00: s_axi_rdata <= 0;
                    8'h04: s_axi_rdata <= {29'b0, error_flag, done_flag, running};
                    8'h08: s_axi_rdata <= repetitions;
                    8'h0c: s_axi_rdata <= CLK_HZ;
                    8'h10: s_axi_rdata <= kernel_cycles;
                    8'h14: s_axi_rdata <= batch_cycles[31:0];
                    8'h18: s_axi_rdata <= batch_cycles[63:32];
                    8'h1c: s_axi_rdata <= completed;
                    8'h20: s_axi_rdata <= 32'h20080404; // acc/data/cols/rows, 8 bits each
                    8'h24: s_axi_rdata <= 32'h00010004; // version16/inner16
                    8'h28: s_axi_rdata <= MAX_REPETITIONS;
                    default: begin
                        if (s_axi_araddr >= 8'h40 && s_axi_araddr <= 8'h4c)
                            s_axi_rdata <= a_words[s_axi_araddr[3:2]];
                        else if (s_axi_araddr >= 8'h50 && s_axi_araddr <= 8'h5c)
                            s_axi_rdata <= b_words[s_axi_araddr[3:2]];
                        else if (s_axi_araddr >= 8'h80 && s_axi_araddr <= 8'hbc)
                            s_axi_rdata <= result_words[s_axi_araddr[5:2]];
                        else s_axi_rresp <= 2'b11;
                    end
                endcase
            end
        end
    end
endmodule
