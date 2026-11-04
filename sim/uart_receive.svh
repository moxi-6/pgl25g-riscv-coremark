// Included inside testbenches with uart_txd and BIT_NS defined.
task automatic receive_byte(output logic [7:0] value);
    @(negedge uart_txd);
    #(BIT_NS / 2);
    if (uart_txd !== 1'b0) $fatal(1, "UART invalid start bit");
    for (integer bit_no = 0; bit_no < 8; bit_no = bit_no + 1) begin
        #(BIT_NS);
        value[bit_no] = uart_txd;
    end
    #(BIT_NS);
    if (uart_txd !== 1'b1) $fatal(1, "UART invalid stop bit");
endtask
