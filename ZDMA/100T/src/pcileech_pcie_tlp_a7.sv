//
// PCILeech FPGA.
//
// PCIe controller module - TLP handling for Artix-7.
//
// (c) Ulf Frisk, 2018-2024
// Author: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_pcie_tlp_a7(
    input                   rst,
    input                   clk_pcie,
    input                   clk_sys,
    IfPCIeFifoTlp.mp_pcie   dfifo, // tlp fifo interface
    
    // PCIe core receive/transmit data
    IfAXIS128.source        tlps_tx,
    IfAXIS128.sink_lite     tlps_rx,
    IfAXIS128.sink          tlps_static,
    IfShadow2Fifo.shadow    dshadow2fifo,
    input [15:0]            pcie_id
    );
    
    // 128 bit axi stream response paths for tlp data
    // Individual streams are eventually merged via a MUX going back into the pcie core so it can do BAR stuff or 
    IfAXIS128 tlps_bar_rsp(); // carries tlps that originate from the BAR controller
    IfAXIS128 tlps_cfg_rsp(); // carries tlps that originate from the config space shadow controller
    
    // ------------------------------------------------------------------------
    // Convert received TLPs from PCIe core and transmit onwards:
    // Submodule processing pipeline for the tlp for filtering and forwarding
    // ------------------------------------------------------------------------
    IfAXIS128 tlps_filtered(); // 128 bit axi stream interface
    
    // Sub Module - 1
    // Monitors the address inside the tlp header to see if they match the device's BAR 
    // Generates AXI stream outs for different sub modules 
    // Does not block TLP's so other modules can observe the same incoming tlp for different functions
    pcileech_tlps128_bar_controller i_pcileech_tlps128_bar_controller(
        .rst            ( rst                           ), 
        .clk            ( clk_pcie                      ),
        .bar_en         ( dshadow2fifo.bar_en           ), // control signal to enable/disable BAR logic.
                                                           // if disabled -> module will ignore or pass tlp w/o responding
        .pcie_id        ( pcie_id                       ), // 16 bit device identifier for matching tlp req/res
        .tlps_in        ( tlps_rx                       ), // input tlp stream from the pcie core
        .tlps_out       ( tlps_bar_rsp.source           ) // output tlp stream used for passing tlp that are targetting the BAR
    );
    
    // Sub Module - 2
    // Monitors Config Space TLPs (r/w)
    // Maintains shadow of config space
    // Custom logic to intercept, store and modify config space -> read out via dshadow2fifo
    pcileech_tlps128_cfgspace_shadow i_pcileech_tlps128_cfgspace_shadow(
        .rst            ( rst                           ),
        .clk_pcie       ( clk_pcie                      ),
        .clk_sys        ( clk_sys                       ), // sys clk used here as well (eg. for updating shadow registers)
        .tlps_in        ( tlps_rx                       ), // inbound tlp
        .pcie_id        ( pcie_id                       ),
        .dshadow2fifo   ( dshadow2fifo                  ), 
        .tlps_cfg_rsp   ( tlps_cfg_rsp.source           ) // output tlp stream for config space res (eg. if the fpga needs to respond to config read reqs)
    );
    
    // Sub Module - 3   
    // Filtering (dropping) certain tlps for downstream
    pcileech_tlps128_filter i_pcileech_tlps128_filter(
        .rst            ( rst                           ),
        .clk_pcie       ( clk_pcie                      ),
        .alltlp_filter  ( dshadow2fifo.alltlp_filter    ), // If asserted will drop all TLPs except for completion
        .cfgtlp_filter  ( dshadow2fifo.cfgtlp_filter    ), // If asserted will drop config TLP's, incoming or outgoing???
        .tlps_in        ( tlps_rx                       ),
        .tlps_out       ( tlps_filtered.source_lite     ) // outgoing filtered tlp stream
    );
    
    // Sub Module - 4
    // Recieves the filtered tlps and places them a fifo that crosses from the pcie clk to the sys_clk 
    // Splits the 128 bit tlp into 32 bit segments to match the dfifo signals
    // dfifo.rx_rd_en - handshake signal so sys can read data at its own pace
    pcileech_tlps128_dst_fifo i_pcileech_tlps128_dst_fifo(
        .rst            ( rst                           ),
        .clk_pcie       ( clk_pcie                      ),
        .clk_sys        ( clk_sys                       ),
        .tlps_in        ( tlps_filtered.sink_lite       ), // consumes data from the filtering sub module
        .dfifo          ( dfifo                         ) // standard 32/64 bit wrd frmt
    );
    
    // ------------------------------------------------------------------------
    // TX data received from FIFO
    // Generates 128 bit axi stream from 4 data words
    // 128 bit axi stream is then muxed with 1 other tlps_in and then sent to downstream module
    // ------------------------------------------------------------------------
    IfAXIS128 tlps_rx_fifo(); // interface declaration 
    
    // Sub Module - 1
    // Reads 32 bit words from the dma fifo interface (dfifo) and stores in internal register
    // Can accumulate up to 4 dws and assembles words into a 128 bit tlp frame
    // Once enough data wrds or end of packet -> asserts tvalid signal within the tlps_out interface 
    //                                        -> sends 128 data bit and control signals (tkeepdw, tlast)
    pcileech_tlps128_src_fifo i_pcileech_tlps128_src_fifo(
        .rst            ( rst                           ),  
        .clk_pcie       ( clk_pcie                      ), 
        .clk_sys        ( clk_sys                       ),
        .dfifo_tx_data  ( dfifo.tx_data                 ), // data chunk, clked by clk_sys

        // Watch tx_valid and tx_last to determine when the TLP packet ends
        .dfifo_tx_last  ( dfifo.tx_last                 ), // last data word
        .dfifo_tx_valid ( dfifo.tx_valid                ), // which parts of data word r valid

        .tlps_out       ( tlps_rx_fifo.source           ) // 128 bit axi output port
                                                          // acts as source of input data to rx_fifo() interface
                                                          // clked by clk_pcie 
    );
    
    // Sub Module - 2
    // 4 to 1 axi stream multiplexer for tlp data
    // Takes in 4 tlp seperate tlp streams and sends one along the output stream (tlps_out)
    // Priority based selection for output - based on which stream has data to send (tvalid)
    //                                     - sends stream on a highest priority basis
    // Transmits the full tlp until tlast is asserted (indicating last dw of tlp)
    pcileech_tlps128_sink_mux1 i_pcileech_tlps128_sink_mux1(
        .rst            ( rst                           ), 
        .clk_pcie       ( clk_pcie                      ),
        .tlps_out       ( tlps_tx                       ), // final merged axi stream driven to the pcie core
        .tlps_in1       ( tlps_cfg_rsp.sink             ), // config response
        .tlps_in2       ( tlps_bar_rsp.sink             ), // bar response
        .tlps_in3       ( tlps_rx_fifo.sink             ), // 128 bit axi data from the dfifo 
        .tlps_in4       ( tlps_static                   ) 
    );
endmodule



// ------------------------------------------------------------------------
// TLP-AXI-STREAM destination:
// - Forward the data to output device (FT601, etc.)
// - TLP split into 4 x 32 bit wrds (dfifo.rx_data[0...3])
// - Control/status bits (rx_valid[], rx_first[] and rx_last[]) for indicating valid words, first/last packet cycles
// - Axi stream signals (tvalid, tlast, tkeepdw & tuser) are mapped to simplier dma interface
// ------------------------------------------------------------------------
module pcileech_tlps128_dst_fifo(
    input                   rst,

    // Clk crossing fifo. Data bridged b/w pcie <-> fpga sys
    input                   clk_pcie, // write side (where tlps_in arrives from)
    input                   clk_sys, // read side (where this downstream dfifo operates on)
    IfAXIS128.sink_lite     tlps_in, // interface for 128 bit axi stream (tlps_tx from top module) w/ signals:
                                     // tdata[0..3]
                                     // tvalid
                                     // tlast
                                     // tkeep[3:0]
                                     // tuser[0]  
    IfPCIeFifoTlp.mp_pcie   dfifo // interface for downstream fifo consumption w/ signals:
                                  // - rx_data[0..3] => each 32 bit dw of tlp data
                                  // - rx_valid[0..3] => which dw is valid
                                  // - rx_first[0] => start of packet
                                  // - rx_last[0..3] => end of packet
                                  // - rx_rd_en => read enable for downstream to output data
);
    
    // Local Signals:
    //  ** These wires recieve the output of the clk crossing fifo
    wire         tvalid; 
    wire [127:0] tdata;
    wire [3:0]   tkeepdw;
    wire         tlast;
    wire         first;
       
    // Instantiating the clk crossing fifo
    fifo_134_134_clk2 i_fifo_134_134_clk2 (
        .rst        ( rst               ),
        .wr_clk     ( clk_pcie          ), // pcie core writes into the fpga space
        .rd_clk     ( clk_sys           ), // fpga reads into dma

        // fifo input (din)
        .din        ( { tlps_in.tuser[0], tlps_in.tlast, tlps_in.tkeepdw, tlps_in.tdata } ),

        .wr_en      ( tlps_in.tvalid    ), // write to fifo when tvalid is asserted
        .rd_en      ( dfifo.rx_rd_en    ), // downstream determines when it wants to read from fifo

        // split 134 bit data back into individual dout signals 
        .dout       ( { first, tlast, tkeepdw, tdata } ),
        .full       (                   ),
        .empty      (                   ),
        .valid      ( tvalid            )
    );

    /* Mapping fifo output to dfifo signals */
    // 128 bit tdata stream is divided in 32 bit chunks
    assign dfifo.rx_data[0]  = tdata[31:0]; 
    assign dfifo.rx_data[1]  = tdata[63:32];
    assign dfifo.rx_data[2]  = tdata[95:64];
    assign dfifo.rx_data[3]  = tdata[127:96];
    assign dfifo.rx_first[0] = first; // tfirst is always [0]
    assign dfifo.rx_first[1] = 0;
    assign dfifo.rx_first[2] = 0;
    assign dfifo.rx_first[3] = 0;

    // Assigning end of packet based on tlast and tkeepdw
    // - value of tkeepdw will tell us which is the last valid pckt
    assign dfifo.rx_last[0]  = tlast && (tkeepdw == 4'b0001); // ie. only first pckt is valid and thus end
    assign dfifo.rx_last[1]  = tlast && (tkeepdw == 4'b0011);
    assign dfifo.rx_last[2]  = tlast && (tkeepdw == 4'b0111); 
    assign dfifo.rx_last[3]  = tlast && (tkeepdw == 4'b1111);
    assign dfifo.rx_valid[0] = tvalid && tkeepdw[0];
    assign dfifo.rx_valid[1] = tvalid && tkeepdw[1];
    assign dfifo.rx_valid[2] = tvalid && tkeepdw[2];
    assign dfifo.rx_valid[3] = tvalid && tkeepdw[3];

endmodule



// ------------------------------------------------------------------------
// TLP-AXI-STREAM FILTER:
// Filter away certain packet types such as CfgRd/CfgWr or non-Cpl/CplD
// Ie. we only want completion and completion w/ data packets. Everything else is garbage
// Note: emulation will require we respond to certain pckts => more on this later 
// Looks at the first double wrd (32 bit) of the tlp header which contains TLP format/type field
// If pckt matches filtered type => assert signal to prevent propgating pckt forward
// ------------------------------------------------------------------------
module pcileech_tlps128_filter(
    input                   rst,
    input                   clk_pcie,
    input                   alltlp_filter, // flag for filtering out non completion tlps
    input                   cfgtlp_filter, // flag for config read/write tlps
    IfAXIS128.sink_lite     tlps_in, // input stream
    IfAXIS128.source_lite   tlps_out // (optional) output tlp stream
);

    // Internal Signals
    bit [127:0]     tdata;
    bit [3:0]       tkeepdw;
    bit             tvalid  = 0;
    bit [8:0]       tuser;
    bit             tlast;
    
    // Wiring signals to output interface
    assign tlps_out.tdata   = tdata;
    assign tlps_out.tkeepdw = tkeepdw;
    assign tlps_out.tvalid  = tvalid;
    assign tlps_out.tuser   = tuser;
    assign tlps_out.tlast   = tlast;
    
    // Filtering Logic
    // - Detect if cpl pckt or cfg pckt
    // - This current incoming pckt will be filtered if 
    //      - pckt is already being filtered and we not on the first cycle of the tlp
    //      - cfg flag is set and config pckt is recognized
    //      - all non cpl flag is set and pckt is not a cpl or is a cfg pckt
    // - thus filter_next is set to true so the tlp is dropped/continued to be dropped
    bit  filter = 0; // 0 - don't drop tlp, 1 - drop tlp
    wire first = tlps_in.tuser[0];
    wire is_tlphdr_cpl = first && (
                        (tlps_in.tdata[31:25] == 7'b0000101) ||      // Cpl:  Fmt[2:0]=000b (3 DW header, no data), Cpl=0101xb
                        (tlps_in.tdata[31:25] == 7'b0100101)         // CplD: Fmt[2:0]=010b (3 DW header, data),    CplD=0101xb
                      );
    wire is_tlphdr_cfg = first && (
                        (tlps_in.tdata[31:25] == 7'b0000010) ||      // CfgRd: Fmt[2:0]=000b (3 DW header, no data), CfgRd0/CfgRd1=0010xb
                        (tlps_in.tdata[31:25] == 7'b0100010)         // CfgWr: Fmt[2:0]=010b (3 DW header, data),    CfgWr0/CfgWr1=0010xb
                      );
    wire filter_next = (filter && !first) || (cfgtlp_filter && first && is_tlphdr_cfg) || (alltlp_filter && first && !is_tlphdr_cpl && !is_tlphdr_cfg);
                      
    always @ ( posedge clk_pcie ) begin
        tdata   <= tlps_in.tdata;
        tkeepdw <= tlps_in.tkeepdw;
        tvalid  <= tlps_in.tvalid && !filter_next && !rst;
        tuser   <= tlps_in.tuser;
        tlast   <= tlps_in.tlast;
        filter  <= filter_next && !rst; // update filter for next clk
    end
    
endmodule



// ------------------------------------------------------------------------
// RX FROM FIFO - TLP-AXI-STREAM:
// Convert 32-bit incoming data to 128-bit TLP-AXI-STREAM to be sent onwards to mux/pcie core. 
// fifo facilitates clk domain crossing from clk_sys -> clk_pcie
// ------------------------------------------------------------------------
module pcileech_tlps128_src_fifo (
    input                   rst,
    input                   clk_pcie,
    input                   clk_sys,
    // DFIFO coming from clk_sys
    input [31:0]            dfifo_tx_data, 
    input                   dfifo_tx_last,
    input                   dfifo_tx_valid, 
    IfAXIS128.source        tlps_out // output stream
);

    // 1: 32-bit -> 128-bit state machine:
    bit [127:0] tdata;
    bit [3:0]   tkeepdw = 0;
    bit         tlast;
    bit         first   = 1; // flag to track if we are at the start of a new pckt
    wire        tvalid  = tlast || tkeepdw[3]; // tvalid flag asserted once 128 bit wrd ready or the pckt has ended
    
    // 32 bit wrds combined into 128 bit stream
    always @ ( posedge clk_sys )
        if ( rst ) begin 
            tkeepdw <= 0;
            tlast   <= 0;
            first   <= 1;
        end
        else begin
            tlast   <= dfifo_tx_valid && dfifo_tx_last; // if current wrd is valid and last wrd, then assert tlast
            
            // Shift or reinit tkeepdw depending on if we alr have a full/valid 128 bit tlp
            tkeepdw <= tvalid ? 
            // tvalid (pckt complete) 
                // if incoming wrd tx_valid -> reset keepdw at 0001
                // else -> reset keepdw at 0000
                (dfifo_tx_valid ? 4'b0001 : 4'b0000) : 
            // not tvalid (pckt not complete)
                // if incoming wrd tx_valid -> shift left once and then update lsb with 1
                // else -> keep the current tkeepdw
                (dfifo_tx_valid ? ((tkeepdw << 1) | 1'b1) : tkeepdw);
            
            // tvalid (pckt complete) -> first = tlast
            first   <= tvalid ? tlast : first;

            // Storing incoming wrd in tdata
            // Finds the first empty spot to put the 32 bit wrd in
            if ( dfifo_tx_valid ) begin 
                if ( tvalid || !tkeepdw[0] )
                    tdata[31:0]   <= dfifo_tx_data;
                if ( !tkeepdw[1] )
                    tdata[63:32]  <= dfifo_tx_data;
                if ( !tkeepdw[2] )
                    tdata[95:64]  <= dfifo_tx_data;
                if ( !tkeepdw[3] )
                    tdata[127:96] <= dfifo_tx_data;   
            end
        end
		
    // 2.1 - buffered packet count (w/ safe fifo clock-crossing).
    bit [10:0]  pkt_count       = 0; // tracking how many complete 128 bit pckts are waiting to be sent
    wire        pkt_count_dec   = tlps_out.tvalid && tlps_out.tlast; // decrement counts when pckt has been sent out
    wire        pkt_count_inc;
    wire [10:0] pkt_count_next  = pkt_count + pkt_count_inc - pkt_count_dec;
    assign tlps_out.has_data    = (pkt_count_next > 0); // Tells the downstream logic that at least one packet is waiting
    
    // Crossing Clk domain
    fifo_1_1_clk2 i_fifo_1_1_clk2(
        .rst            ( rst                       ),
        .wr_clk         ( clk_sys                   ),
        .rd_clk         ( clk_pcie                  ),
        .din            ( 1'b1                      ),
        .wr_en          ( tvalid && tlast           ), // write enabled in clk_sys when pckt is ready
        .rd_en          ( 1'b1                      ), // read is always enabled in the clk_pcie side
        .dout           (                           ),
        .full           (                           ),
        .empty          (                           ),
        .valid          ( pkt_count_inc             ) // new pckt available for consumption
    );
	
    always @ ( posedge clk_pcie ) begin
        pkt_count <= rst ? 0 : pkt_count_next;
    end
        
    // 2.2 - submit to output fifo - will feed into mux/pcie core.
    //       together with 2.1 this will form a low-latency "packet fifo".
    fifo_134_134_clk2_rxfifo i_fifo_134_134_clk2_rxfifo(    
        .rst            ( rst                       ),
        .wr_clk         ( clk_sys                   ), 
        .rd_clk         ( clk_pcie                  ),
        // Data In - 134 bit total
        //     - 128 bit - tdata
        //     - 1 bit - first, last
        //     - 4 bits - tkeepdw
        .din            ( { first, tlast, tkeepdw, tdata } ), 
        .wr_en          ( tvalid                    ), // write enabled when tvalid asserted
        .rd_en          ( tlps_out.tready && (pkt_count_next > 0) ), // read enabled when...
                                                                    // - downstream ready to recieve
                                                                    // - there is a pckt available for recieving
        // Data Out - Unpacked Axi stream signals
        .dout           ( { tlps_out.tuser[0], tlps_out.tlast, tlps_out.tkeepdw, tlps_out.tdata } ),
        .full           (                           ),
        .empty          (                           ),
        .valid          ( tlps_out.tvalid           )
    );

endmodule

// ------------------------------------------------------------------------
// RX MUX - TLP-AXI-STREAM:
// Select the TLP-AXI-STREAM with the highest priority (lowest number) and
// let it transmit its full packet.
// Each incoming stream must have latency of 1CLK. 
// pckt is transmitted until tlast is asserted
// ------------------------------------------------------------------------
module pcileech_tlps128_sink_mux1 (
    input                       clk_pcie,
    input                       rst,
    IfAXIS128.source            tlps_out, // output signals interface
    IfAXIS128.sink              tlps_in1, // 
    IfAXIS128.sink              tlps_in2,
    IfAXIS128.sink              tlps_in3,
    IfAXIS128.sink              tlps_in4
);
    bit [2:0] id = 0; 
    assign tlps_out.has_data    = tlps_in1.has_data || tlps_in2.has_data || tlps_in3.has_data || tlps_in4.has_data;
    
    // Forwarding tdata and cntrl signals given current id
    // If id = 0 (not set) frwrd -> 0
    assign tlps_out.tdata       = (id==1) ? tlps_in1.tdata :
                                  (id==2) ? tlps_in2.tdata :
                                  (id==3) ? tlps_in3.tdata :
                                  (id==4) ? tlps_in4.tdata : 0;
    
    assign tlps_out.tkeepdw     = (id==1) ? tlps_in1.tkeepdw :
                                  (id==2) ? tlps_in2.tkeepdw :
                                  (id==3) ? tlps_in3.tkeepdw :
                                  (id==4) ? tlps_in4.tkeepdw : 0;
    
    assign tlps_out.tlast       = (id==1) ? tlps_in1.tlast :
                                  (id==2) ? tlps_in2.tlast :
                                  (id==3) ? tlps_in3.tlast :
                                  (id==4) ? tlps_in4.tlast : 0;
    
    assign tlps_out.tuser       = (id==1) ? tlps_in1.tuser :
                                  (id==2) ? tlps_in2.tuser :
                                  (id==3) ? tlps_in3.tuser :
                                  (id==4) ? tlps_in4.tuser : 0;
    
    assign tlps_out.tvalid      = (id==1) ? tlps_in1.tvalid :
                                  (id==2) ? tlps_in2.tvalid :
                                  (id==3) ? tlps_in3.tvalid :
                                  (id==4) ? tlps_in4.tvalid : 0;
    
    // Priority Stream Selection from 1 -> 4
    wire [2:0] id_next_newsel   = tlps_in1.has_data ? 1 :
                                  tlps_in2.has_data ? 2 :
                                  tlps_in3.has_data ? 3 :
                                  tlps_in4.has_data ? 4 : 0;
    
    // Trigger next id update if currently 0 or if pckt done transmitting
    wire [2:0] id_next          = ((id==0) || (tlps_out.tvalid && tlps_out.tlast)) ? id_next_newsel : id;
    
    // Chosen stream sent downstream once downstream interface is **tready**
    assign tlps_in1.tready      = tlps_out.tready && (id_next==1);
    assign tlps_in2.tready      = tlps_out.tready && (id_next==2);
    assign tlps_in3.tready      = tlps_out.tready && (id_next==3);
    assign tlps_in4.tready      = tlps_out.tready && (id_next==4);
    
    // Updating current id on pcie clk edge
    always @ ( posedge clk_pcie ) begin 
        id <= rst ? 0 : id_next;
    end
endmodule
