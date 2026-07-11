`timescale 1ns / 1ps

module axi_to_apb_bridge #(
    parameter ADDR_WIDTH = 32, // The size of memory addresses (32-bit)
    parameter DATA_WIDTH = 32  // The size of data packages (32-bit)
)(
    // --- 1. SYSTEM CONTROL WIRES ---
    input  wire                    aclk,     // The heartbeat (clock ticker) of the chip
    input  wire                    aresetn,  // Reset button (0 = wipe clean, 1 = normal run)

    // --- 2. THE FAST AXI SIDE (Facing the CPU) ---
    // Write Address Channel (Where the CPU wants to send data)
    input  wire [ADDR_WIDTH-1:0]   awaddr,   // Incoming address from CPU
    input  wire                    awvalid,  // CPU says: "This address is valid!"
    output reg                     awready,  // Bridge says: "I am ready to take the address!"

    // Write Data Channel (The actual data package)
    input  wire [DATA_WIDTH-1:0]   wdata,    // Incoming data from CPU
    input  wire                    wvalid,   // CPU says: "This data package is valid!"
    output reg                     wready,   // Bridge says: "I am ready to take this data!"

    // Write Response Channel (Telling the CPU the job is done)
    output reg  [1:0]              bresp,    // Status code (00 = Success, 10 = Error)
    output reg                     bvalid,   // Bridge says: "Hey CPU, my status report is ready!"
    input  wire                    bready,   // CPU says: "I am listening for your report!"

    // Read Address Channel (When CPU wants to ask for data)
    input  wire [ADDR_WIDTH-1:0]   araddr,   
    input  wire                    arvalid,  
    output reg                     arready,  

    // Read Data Channel (Sending requested data back to CPU)
    output reg  [DATA_WIDTH-1:0]   rdata,    // Data passing back to CPU
    output reg  [1:0]              rresp,    // Read status code
    output reg                     rvalid,   // Bridge says: "Hey CPU, here is your requested data!"
    input  wire                    rready,   // CPU says: "I am ready to receive the data!"

    // --- 3. THE SLOW APB SIDE (Facing the Peripherals) ---
    output reg  [ADDR_WIDTH-1:0]   paddr,    // Outgoing address to slow device
    output reg                     psel,     // Tap on the shoulder (Select device)
    output reg                     penable,  // Action flag (Enable data transmission)
    output reg                     pwrite,   // 1 = Bridge is writing, 0 = Bridge is reading
    output reg  [DATA_WIDTH-1:0]   pwdata,   // Outgoing data to slow device
    input  wire                    pready,   // Slow device thumbs-up: "I am finished!"
    input  wire [DATA_WIDTH-1:0]   prdata,   // Data coming from slow device (during a read)
    input  wire                    pslverr   // Slow device error flag (1 = something went wrong)
);





// State Names (Given binary IDs for the state machine)
    localparam ST_IDLE   = 2'b00;
    localparam ST_SETUP  = 2'b01;
    localparam ST_ACCESS = 2'b10;
    localparam ST_RESP   = 2'b11;

    reg [1:0] current_state, next_state;

    // Temporary storage folders inside the bridge
    reg [ADDR_WIDTH-1:0] reg_addr;     // Holds the address
    reg [DATA_WIDTH-1:0] reg_wdata;    // Holds the data we want to write
    reg                  reg_write_op; // Remembers if it's a write (1) or read (0)
    reg [1:0]            reg_resp;     // Holds the pass/fail response
    reg [DATA_WIDTH-1:0] reg_rdata;    // Holds data read from slow device






// --- STEP A: Moving state to state on every clock tick ---
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            current_state <= ST_IDLE; // Reset back to IDLE
        end else begin
            current_state <= next_state; // Step forward
        end
    end

    // --- STEP B: Deciding what the NEXT state should be ---
    always @(*) begin
        next_state = current_state; // Default: stay where you are
        
        case (current_state)
            ST_IDLE: begin
                // If CPU sends a valid address AND valid data -> start a Write
                if (awvalid && wvalid) begin
                    next_state = ST_SETUP;
                // Otherwise, if CPU just sends a valid read request -> start a Read
                end else if (arvalid) begin
                    next_state = ST_SETUP;
                end
            end
            
            ST_SETUP: begin
                // APB rules state we must immediately jump to ACCESS on the next tick
                next_state = ST_ACCESS;
            end
            
            ST_ACCESS: begin
                // Freeze here until the slow peripheral wakes up and gives a thumbs up (pready)
                if (pready) begin
                    next_state = ST_RESP;
                end
            end
            
            ST_RESP: begin
                // Wait until the fast CPU acknowledges our handshake completion report
                if (reg_write_op && bready) begin
                    next_state = ST_IDLE;
                end else if (!reg_write_op && rready) begin
                    next_state = ST_IDLE;
                end
            end
        endcase
    end





// --- STEP C: Storing values inside internal folders ---
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            reg_addr     <= 0;
            reg_wdata    <= 0;
            reg_write_op <= 0;
            reg_rdata    <= 0;
            reg_resp     <= 2'b00;
        end else begin
            if (current_state == ST_IDLE) begin
                if (awvalid && wvalid) begin
                    reg_addr     <= awaddr;     // Capture write address
                    reg_wdata    <= wdata;      // Capture data package
                    reg_write_op <= 1'b1;       // Remember this is a WRITE job
                end else if (arvalid) begin
                    reg_addr     <= araddr;     // Capture read address
                    reg_write_op <= 1'b0;       // Remember this is a READ job
                end
            end else if (current_state == ST_ACCESS && pready) begin
                // Grab the results the moment the slow peripheral finishes
                reg_rdata <= prdata; 
                // Convert 1-bit slow error to 2-bit standard CPU error (10 = Error, 00 = Ok)
                reg_resp  <= pslverr ? 2'b10 : 2'b00;
            end
        end
    end

    // --- STEP D: Setting wire levels based on current state ---
    always @(*) begin
        // Set safe default baseline values so we don't accidentally freeze a wire (latches)
        awready = 1'b0;  wready  = 1'b0;  arready = 1'b0;
        bvalid  = 1'b0;  rvalid  = 1'b0;  psel    = 1'b0;  penable = 1'b0;
        
        paddr   = reg_addr;
        pwrite  = reg_write_op;
        pwdata  = reg_wdata;
        bresp   = reg_resp;
        rresp   = reg_resp;
        rdata   = reg_rdata;

        case (current_state)
            ST_IDLE: begin
                // Shake hands with CPU immediately if it is sending valid traffic
                if (awvalid && wvalid) begin
                    awready = 1'b1;
                    wready  = 1'b1;
                end else if (arvalid) begin
                    arready = 1'b1;
                end
            end

            ST_SETUP: begin
                psel = 1'b1; // Tap peripheral on the shoulder
            end

            ST_ACCESS: begin
                psel    = 1'b1; // Keep shoulder tapped
                penable = 1'b1; // Signal: "Do the work right now!"
            end

            ST_RESP: begin
                if (reg_write_op) begin
                    bvalid = 1'b1; // Report back write completion to CPU
                end else begin
                    rvalid = 1'b1; // Report back read data to CPU
                end
            end
        endcase
    end

endmodule