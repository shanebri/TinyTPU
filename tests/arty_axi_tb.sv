`timescale 1ns/1ps
// User-run testbench: sources from arty.f plus this file, top arty_axi_tb.
module arty_axi_tb;
    logic clk = 0;
    always #5 clk = ~clk;
    logic resetn = 0;
    logic [7:0] awaddr = 0, araddr = 0;
    logic awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    logic [31:0] wdata = 0;
    logic [3:0] wstrb = 0;
    wire awready, wready, bvalid, arready, rvalid;
    wire [1:0] bresp, rresp;
    wire [31:0] rdata;
    arty_top dut (
        .s_axi_aclk(clk), .s_axi_aresetn(resetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready)
    );
    int signed a [0:15], b [0:15];
    task automatic write_register(input logic [7:0] address, input logic [31:0] data,
                                  input logic [3:0] strobes = 4'hf,
                                  input int order = 0, input logic [1:0] expected_resp = 0);
        logic [1:0] held;
        // order 1: AW first; order 2: W first; order 0: simultaneous.
        fork
            begin
                if (order == 2) repeat (4) @(negedge clk);
                @(negedge clk); awaddr = address; awvalid = 1;
                do @(posedge clk); while (!awready);
                @(negedge clk); awvalid = 0;
            end
            begin
                if (order == 1) repeat (4) @(negedge clk);
                @(negedge clk); wdata = data; wstrb = strobes; wvalid = 1;
                do @(posedge clk); while (!wready);
                @(negedge clk); wvalid = 0;
            end
        join
        wait (bvalid);
        held = bresp;
        repeat (3) begin
            @(negedge clk);
            if (!bvalid || bresp !== held) $fatal(1, "B response changed under backpressure");
        end
        if (held !== expected_resp) $fatal(1, "write response at %h: %h != %h", address, held, expected_resp);
        bready = 1;
        @(posedge clk); @(negedge clk); bready = 0;
    endtask
    task automatic read_register(input logic [7:0] address, output logic [31:0] data,
                                 input logic [1:0] expected_resp = 0);
        logic [31:0] held;
        logic [1:0] held_resp;
        @(negedge clk); araddr = address; arvalid = 1;
        do @(posedge clk); while (!arready);
        @(negedge clk); arvalid = 0;
        wait (rvalid); held = rdata; held_resp = rresp;
        repeat (3) begin
            @(negedge clk);
            if (!rvalid || rdata !== held || rresp !== held_resp)
                $fatal(1, "R response changed under backpressure");
        end
        if (held_resp !== expected_resp) $fatal(1, "read response mismatch at %h", address);
        data = held;
        rready = 1;
        @(posedge clk); @(negedge clk); rready = 0;
    endtask
    task automatic run_and_check(input int repetitions);
        logic [31:0] value;
        int signed expected;
        bit finished;
        write_register(8'h08, 32'(repetitions), 4'hf, 1);
        write_register(8'h00, 1, 4'hf, 2);
        finished = 0;
        for (int poll = 0; poll < 3000; poll++) begin
            read_register(8'h04, value);
            if (value == 2) begin finished = 1; break; end
        end
        if (!finished) $fatal(1, "completion timeout");
        read_register(8'h10, value);
        if (value != 12) $fatal(1, "kernel timing %d != 12", value);
        read_register(8'h14, value);
        if (value != 14*repetitions-2) $fatal(1, "batch timing mismatch");
        read_register(8'h18, value);
        if (value != 0) $fatal(1, "unexpected batch high word");
        read_register(8'h1c, value);
        if (value != repetitions) $fatal(1, "completed count mismatch");
        for (int r = 0; r < 4; r++)
            for (int c = 0; c < 4; c++) begin
                expected = 0;
                for (int k = 0; k < 4; k++) expected += a[r*4+k]*b[k*4+c];
                read_register(8'(8'h80+(r*4+c)*4), value);
                if ($signed(value) != expected) $fatal(1, "result[%d,%d] mismatch", r, c);
            end
    endtask
    logic [31:0] value, packed_row;
    initial begin
        repeat (5) @(negedge clk); resetn = 1;
        read_register(8'h20, value);
        if (value != 32'h20080404) $fatal(1, "config mismatch");
        for (int j = 0; j < 16; j++) begin
            a[j] = (j % 2) ? 127 : -128;
            b[j] = j-8;
        end
        for (int r = 0; r < 4; r++) begin
            packed_row = 0;
            for (int c = 0; c < 4; c++) packed_row[c*8 +: 8] = 8'(a[r*4+c]);
            write_register(8'(8'h40+4*r), packed_row, 4'hf, r%3);
            packed_row = 0;
            for (int c = 0; c < 4; c++) packed_row[c*8 +: 8] = 8'(b[r*4+c]);
            write_register(8'(8'h50+4*r), packed_row, 4'hf, r%3);
        end
        write_register(8'h40, 32'h12345678, 4'b0010);
        read_register(8'h40, value);
        if (value != 32'h7f805680) $fatal(1, "byte strobes mismatch");
        write_register(8'h40, 32'h7f807f80);
        run_and_check(1);
        run_and_check(17);
        // Busy operand writes fail and do not corrupt the resident inputs.
        write_register(8'h08, 1000);
        write_register(8'h00, 1);
        write_register(8'h40, 0, 4'hf, 0, 2'b10);
        write_register(8'h00, 2); // abort and clear
        read_register(8'h04, value);
        if (value != 0) $fatal(1, "abort failed");
        read_register(8'h40, value);
        if (value != 32'h7f807f80) $fatal(1, "busy write changed input");
        run_and_check(2);
        write_register(8'h08, 0);
        write_register(8'h00, 1, 4'hf, 0, 2'b10);
        write_register(8'h00, 2);
        read_register(8'h7c, value, 2'b11);
        write_register(8'h80, 1, 4'hf, 0, 2'b11);
        write_register(8'h41, 1, 4'hf, 0, 2'b11);
        $display("PASS: AXI channels, backpressure, strobes, signed results, timing, abort, errors");
        $finish;
    end
    initial begin
        #1_000_000;
        $fatal(1, "testbench timeout");
    end
endmodule
