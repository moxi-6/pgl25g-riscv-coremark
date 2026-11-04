`timescale 1ns/1ps
module tb_mine_top_smoke;
    logic clk=0,rst_n=0;
    tri1 sda,interrupt_pin;
    wire scl,tp_reset,model_oe,model_out,uart;
    wire [3:0] led;
    wire pclk,de,hs,vs,lcd_reset,bl;
    wire [23:0] rgb;
    integer cycles=0;
    bit strap_seen=0;
    always #5 clk=~clk;
    assign sda=model_oe&&!model_out ? 1'b0 : 1'bz;
    atk_l50_mine #(.MEM_FILE("software/build/mine_sim/firmware.hex"),.CLK_HZ(200000),
        .BAUD(100000),.TOUCH_SCL_HZ(50000),.LCD_RESET_CYCLES(8)) dut(
        .sys_clk(clk),.sys_rst_n(rst_n),.key(4'hf),.uart_txd(uart),.led(led),
        .lcd_pclk(pclk),.lcd_de(de),.lcd_hs(hs),.lcd_vs(vs),.lcd_rst(lcd_reset),.lcd_bl(bl),.lcd_rgb(rgb),
        .tp_scl(scl),.tp_sda(sda),.tp_rst(tp_reset),.tp_int(interrupt_pin));
    gt9147_model panel(.scl_i(scl),.sda_oe_o(model_oe),.sda_o_o(model_out),.sda_i(sda),.rst_n_i(rst_n));
    always @(negedge clk) begin
        cycles=cycles+1;
        if(dut.tp_int_oe) begin
            strap_seen=1;
            if(interrupt_pin!==dut.tp_int_o) $fatal(1,"INT address strap was not connected");
        end
        if(cycles>1500000) $fatal(1,"mine top startup timeout");
    end
    initial begin
        repeat(8) @(negedge clk);rst_n=1;
        wait(dut.u_soc.tp_status==1 && dut.mine_state[391:384]==1);
        repeat(20) @(negedge clk);
        if(!strap_seen || dut.tp_int_oe || dut.u_soc.tp_acks || dut.trap) $fatal(1,"mine top startup or pin wiring failed");
        if(!lcd_reset || hs!==1 || vs!==1) $fatal(1,"LCD startup control failed");
        $display("[PASS] mine_top_smoke touch_ready=1 int_strap=1 lcd_reset=1 cycles=%0d",cycles);
        $finish;
    end
endmodule
