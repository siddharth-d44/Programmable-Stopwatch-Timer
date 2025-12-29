`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
//
// Create Date: 11/16/2025 11:46:58 PM
// Design Name: Stopwatch/Timer
// Module Name: stopwatch_timer
// Project Name: Basys3 Stopwatch/Timer
// Target Devices: Basys3
// Description: Fully synchronous stopwatch/timer with 4 modes (Up/Down/Preset).
//
//////////////////////////////////////////////////////////////////////////////////

////////// MODULE FOR THE CLOCK DIVIDER
module clk_divider (
    input clk_in,        // 100 MHz board clock
    input rst,           // Asynchronous reset (though unused in top module, kept for completeness)
    output reg clk_10ms_tick // 100 Hz pulse (ticks every 10ms)
);

// Counter limit for 10ms tick (100,000,000 / 100 Hz = 1,000,000)
// Count from 0 up to 999,999 (1,000,000 clock cycles)
localparam MAX_COUNT = 20'd999999;

reg [19:0] counter = 20'b0;

always @(posedge clk_in or posedge rst) begin
    if (rst) begin
        counter <= 24'b0;
        clk_10ms_tick <= 1'b0;
    end else begin
        if (counter == MAX_COUNT) begin
            counter <= 24'b0;
            clk_10ms_tick <= 1'b1; // Pulse high for one clock cycle
        end else begin
            counter <= counter + 1'b1;
            clk_10ms_tick <= 1'b0;
        end
    end
end

endmodule

// ---

////// CONTROLS THE SEVEN SEGMENT DISPLAY
module seven_seg_decoder (
    input [3:0] bcd_in, // 4-bit BCD input (0-9)
    output reg [6:0] seg // 7-segment output (a-g)
);

// Mapping for common-anode: '0' = ON, '1' = OFF
//   Segments: gfedcba (MSB to LSB)
always @(*) begin
    case (bcd_in)
        4'd0: seg = 7'b1000000; // 0
        4'd1: seg = 7'b1111001; // 1
        4'd2: seg = 7'b0100100; // 2
        4'd3: seg = 7'b0110000; // 3
        4'd4: seg = 7'b0011001; // 4
        4'd5: seg = 7'b0010010; // 5
        4'd6: seg = 7'b0000010; // 6
        4'd7: seg = 7'b1111000; // 7
        4'd8: seg = 7'b0000000; // 8
        4'd9: seg = 7'b0010000; // 9
        default: seg = 7'b1111111; // Off for invalid BCD
    endcase
end

endmodule

// ---

///////MODULE FOR THE ACTUAL TIMER
module stopwatch_timer (
    input clk,             // 100 MHz Clock
    input btn_start_stop,  // Start/Stop button
    input btn_reset,       // Reset/Load button
    input [1:0] sw_mode,   // Mode selection (00:Up, 01:Down, 10:Preset Up, 11:Preset Down)
    input [7:0] sw_preset, // Preset value (MSB: S_T, LSB: S_O)

    output [3:0] an,       // Anode enables (Active-low, 4 digits only) <-- FIXED TO [3:0]
    output [6:0] seg,       // 7-segment segments (Active-low, a-g)
    output reg dp           // Decimal point
);

// --- Internal Wires and Registers ---

// BCD Registers for the four digits
reg [3:0] msec_ones = 4'b0000; // 10ms
reg [3:0] msec_tens = 4'b0000; // 100ms
reg [3:0] sec_ones  = 4'b0000; // Seconds (ones)
reg [3:0] sec_tens  = 4'b0000; // Seconds (tens)

// Clock Tick
wire clk_10ms_tick;

// Debounced button signals (rising edge detection)
reg btn_ss_prev = 1'b0;
reg btn_rst_prev = 1'b0;
wire btn_ss_press = btn_start_stop && !btn_ss_prev; // 1 on rising Rising edge
wire btn_rst_press = btn_reset && !btn_rst_prev; // 11 on rising edge

// Button Edge Detection Register
always @(posedge clk) begin
    btn_ss_prev <= btn_start_stop;
    btn_rst_prev <= btn_reset;
end

// FSM States
localparam S_IDLE       = 3'b000;
localparam S_COUNT_UP   = 3'b001;
localparam S_COUNT_DOWN = 3'b010;

reg [2:0] current_state = S_IDLE;
reg [2:0] next_state = S_IDLE;

// --- 1. Clock Divider Instantiation ---
// rst is set to 0 as the division is continuous
clk_divider divider (.clk_in(clk), .rst(1'b0), .clk_10ms_tick(clk_10ms_tick));

// --- 2. State Machine Logic (Next State Generation - Combinational) ---
always @(*) begin
    next_state = current_state; // Default is self-loop

    case (current_state)
        S_IDLE: begin
            if (btn_ss_press) begin
                if (sw_mode[0] == 1'b0) // Mode 0 or 2 (Up)
                    next_state = S_COUNT_UP;
                else // Mode 1 or 3 (Down)
                    next_state = S_COUNT_DOWN;
            end
        end
        S_COUNT_UP, S_COUNT_DOWN: begin
            if (btn_ss_press) begin
                next_state = S_IDLE; // Stop counting
            end
            // Auto-Stop at 99.99 for UP
            else if (current_state == S_COUNT_UP && sec_tens == 4'd9 && sec_ones == 4'd9 && msec_tens == 4'd9 && msec_ones == 4'd9) begin
                next_state = S_IDLE;
            end
            // Auto-Stop at 00.00 for DOWN
            else if (current_state == S_COUNT_DOWN && sec_tens == 4'd0 && sec_ones == 4'd0 && msec_tens == 4'd0 && msec_ones == 4'd0) begin
                next_state = S_IDLE;
            end
        end
    endcase
end

// --- 3. CONSOLIDATED Register Update Logic (Sequential) ---
// Handles State Register, BCD Registers, and Reset/Load logic.
// This resolves the Multiple Driver Error (MDRV-1).
always @(posedge clk) begin
    
    // PRIORITY 1: SYNCHRONOUS RESET/LOAD (Overrides all counting/state)
    if (btn_rst_press) begin
        // Force state to IDLE immediately
        current_state <= S_IDLE;

        // Load BCD Registers based on sw_mode
        if (sw_mode[1] == 1'b0) begin // Mode 0 (00.00) or Mode 1 (99.99)
            if (sw_mode[0] == 1'b0) begin // Mode 0: Reset to 00.00
                {sec_tens, sec_ones, msec_tens, msec_ones} <= 16'b0;
            end
            else begin // Mode 1: Reset to 99.99
                sec_tens <= 4'd9;
                sec_ones <= 4'd9;
                msec_tens <= 4'd9;
                msec_ones <= 4'd9;
            end
        end 
        else begin // Mode 2 or 3: Load preset
            // Load preset value (sw_preset[7:4] -> sec_tens, sw_preset[3:0] -> sec_ones)
            sec_tens <= sw_preset[7:4];
            sec_ones <= sw_preset[3:0];
            msec_tens <= 4'b0000; // Msecs always start at 00 for preset modes
            msec_ones <= 4'b0000;
        end
    end 
    
    // PRIORITY 2: STATE TRANSITION & COUNTING
    else begin
        // Update FSM state (handles start/stop, auto-stop)
        current_state <= next_state;

        // COUNTING ACTION (Only happens when clk_10ms_tick is active)
        if (clk_10ms_tick) begin
            
            // --- COUNT UP LOGIC ---
            if (current_state == S_COUNT_UP) begin
                // msec_ones (10ms digit)
                if (msec_ones == 4'd9) begin
                    msec_ones <= 4'd0;
                    // msec_tens (100ms digit)
                    if (msec_tens == 4'd9) begin
                        msec_tens <= 4'd0;
                        // sec_ones (seconds ones digit)
                        if (sec_ones == 4'd9) begin
                            sec_ones <= 4'd0;
                            // sec_tens (seconds tens digit)
                            if (sec_tens < 4'd9) sec_tens <= sec_tens + 1'b1;
                        end else begin
                            sec_ones <= sec_ones + 1'b1;
                        end
                    end else begin
                        msec_tens <= msec_tens + 1'b1;
                    end
                end else begin
                    msec_ones <= msec_ones + 1'b1;
                end
            end
            
            // --- COUNT DOWN LOGIC ---
            else if (current_state == S_COUNT_DOWN) begin
                // msec_ones (10ms digit)
                if (msec_ones == 4'd0) begin
                    msec_ones <= 4'd9;
                    // msec_tens (100ms digit)
                    if (msec_tens == 4'd0) begin
                        msec_tens <= 4'd9;
                        // sec_ones (seconds ones digit)
                        if (sec_ones == 4'd0) begin
                            sec_ones <= 4'd9;
                            // sec_tens (seconds tens digit)
                            if (sec_tens > 4'd0) sec_tens <= sec_tens - 1'b1;
                        end else begin
                            sec_ones <= sec_ones - 1'b1;
                        end
                    end else begin
                        msec_tens <= msec_tens - 1'b1;
                    end
                end else begin
                    msec_ones <= msec_ones - 1'b1;
                end
            end
        end
    end
end

// --- 4. 7-Segment Display Multiplexing ---

// Mux clock for display refresh
localparam MUX_COUNT = 18'd50000; // ~500 us delay @ 100MHz clock
reg [17:0] mux_counter = 18'b0;
reg [1:0] digit_select = 2'b00; // Selects which digit is currently active

// Mux register logic
always @(posedge clk) begin
    if (mux_counter == MUX_COUNT) begin
        mux_counter <= 18'b0;
        digit_select <= digit_select + 1'b1; // Cycle through 00, 01, 10, 11
    end else begin
        mux_counter <= mux_counter + 1'b1;
    end
end

// Data to be displayed and Anode selection
reg [3:0] current_bcd;
reg [3:0] an_reg;
assign an = ~an_reg; // Active-low anodes (common-anode)

always @(*) begin
    dp = 1'b1;
    case (digit_select)
        2'b00: begin // LSB: 10ms digit (MSEC_ONES)
            current_bcd = msec_ones;
            an_reg = 4'b0001; // AN0 active
        end
        2'b01: begin // 100ms digit (MSEC_TENS)
            current_bcd = msec_tens;
            an_reg = 4'b0010; // AN1 active
        end
        2'b10: begin // Seconds ones digit (SEC_ONES)
            current_bcd = sec_ones;
            an_reg = 4'b0100; // AN2 active
            dp = 1'b0;
        end
        2'b11: begin // MSB: Seconds tens digit (SEC_TENS)
            current_bcd = sec_tens;
            an_reg = 4'b1000; // AN3 active
        end
        default: begin // Should not happen
            current_bcd = 4'b0000;
            an_reg = 4'b0000;
        end
    endcase
end

// Segment data output via decoder
seven_seg_decoder decoder (
    .bcd_in(current_bcd),
    .seg(seg)
);

endmodule
