`timescale 1ns/1ps
module tb_uart_diagnostic;
    reg clk=0;
    always #5 clk=~clk;
    reg reset_n=0;
    wire tx;
    wire [3:0] led;
    atk_l50_uart_diagnostic #(.CLOCK_HZ(80),.BAUD(10)) dut (
        .sys_clk(clk),.sys_rst_n(reset_n),.uart_txd(tx),.led(led)
    );
    task receive_u;
        reg [7:0] value;
        integer bit_number;
        begin
            @(negedge tx);
            #120;
            for (bit_number=0;bit_number<8;bit_number=bit_number+1) begin
                value[bit_number]=tx;
                #80;
            end
            if (value !== 8'h55 || tx !== 1'b1) $fatal(1,"UART U/frame mismatch: %h",value);
        end
    endtask
    initial begin
        receive_u();
        receive_u();
        if (led[3] !== 1'b1) $fatal(1,"external reset-low indication missing");
        reset_n=1;
        receive_u();
        if (led[3] !== 1'b0) $fatal(1,"external reset-high indication missing");
        if (dut.startup_q !== 6'd63) $fatal(1,"startup counter did not saturate");
        $display("[PASS] uart_diagnostic: U frames during external reset low/high");
        $finish;
    end
    initial begin #10000; $fatal(1,"UART diagnostic timeout"); end
endmodule
