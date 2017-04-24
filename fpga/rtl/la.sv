////////////////////////////////////////////////////////////////////////////////
// Module: Logic Analyzer
// Authors: Iztok Jeras
// (c) Red Pitaya  http://www.redpitaya.com
////////////////////////////////////////////////////////////////////////////////

module la #(
  // stream parameters
  int unsigned DN = 1,  // data number
  type DT = logic [8-1:0],
  // decimation parameters
  int unsigned DCW = 17,  // decimation counter width
  // aquisition parameters
  int unsigned CW  = 32-1,  // counter width
  // event parameters
  type DTC = logic,
  type DTT = evn_pkg::evt_t,
  type DTE = evn_pkg::evd_t
)(
  // streams
  axi4_stream_if.d      sti,  // input
  axi4_stream_if.s      sto,  // output
  // events input/output
  input  DTE            evi,  // input
  output evn_pkg::evs_t evo,  // output
  // reset output
  output logic          ctl_rst,
  // interrupt
  output logic          irq,
  // system bus
  sys_bus_if.s          bus
);

////////////////////////////////////////////////////////////////////////////////
// local signals
////////////////////////////////////////////////////////////////////////////////

// streams
axi4_stream_if #(.DN (DN), .DT (DT)) stn            (.ACLK (sti.ACLK), .ARESETn (sti.ARESETn));  // from negator
axi4_stream_if #(.DN (DN), .DT (DT)) std            (.ACLK (sti.ACLK), .ARESETn (sti.ARESETn));  // from decimator
axi4_stream_if #(.DN (DN), .DT (DT)) stt            (.ACLK (sti.ACLK), .ARESETn (sti.ARESETn));  // from trigger
axi4_stream_if #(.DN (DN), .DT (DT)) sta_str        (.ACLK (sti.ACLK), .ARESETn (sti.ARESETn));  // from acquire
axi4_stream_if #(.DN (DN), .DT (logic [8-1:0])) sta (.ACLK (sti.ACLK), .ARESETn (sti.ARESETn));  // from acquire

// event select masks
DTC             cfg_rst;  // software reset
DTC             cfg_str;  // software start
DTC             cfg_stp;  // software stop
DTC             cfg_swt;  // software trigger
DTT             cfg_trg;  // trigger

// interrupt enable/status/clear
logic   [2-1:0] irq_ena;  // enable
logic   [2-1:0] irq_sts;  // status

// control
//logic           ctl_rst;
// control/status start
logic           ctl_str;
logic           sts_str;
// control/status stop
logic           ctl_stp;
logic           sts_stp;
// control/status trigger
logic           ctl_trg;
logic           sts_trg;

// configuration/status/overflow pre trigger
logic  [CW-1:0] cfg_pre;
logic  [CW-1:0] sts_pre;
logic           sts_pro;
// configuration/status/overflow post trigger
logic  [CW-1:0] cfg_pst;
logic  [CW-1:0] sts_pst;
logic           sts_pso;

// trigger source configuration
DT              cfg_cmp_msk;  // comparator mask
DT              cfg_cmp_val;  // comparator value
DT              cfg_edg_pos;  // edge positive
DT              cfg_edg_neg;  // edge negative

// decimation configuration
logic [DCW-1:0] cfg_dec;  // decimation factor

// RLE configuration
logic           cfg_rle;  // RLE enable

// stream counter staus
logic  [CW-1:0] sts_cur;  // current     counter status
logic  [CW-1:0] sts_lst;  // last packet counter status

// bitwise input polarity
DT              cfg_pol;

////////////////////////////////////////////////////////////////////////////////
//  System bus connection
////////////////////////////////////////////////////////////////////////////////

always_ff @(posedge bus.clk)
if (~bus.rstn) begin
  bus.err <= 1'b0;
  bus.ack <= 1'b0;
end else begin
  bus.err <= 1'b0;
  bus.ack <= bus.wen | bus.ren;
end

localparam int unsigned BAW=7;

// write access
always_ff @(posedge bus.clk)
if (~bus.rstn) begin
  // interrupt enable
  irq_ena <= '0;
  // event masks
  cfg_trg <= '0;
  cfg_rst <= '0;
  cfg_str <= '0;
  cfg_stp <= '0;
  cfg_swt <= '0;
  // configuration
  cfg_pre <= '0;
  cfg_pst <= '0;
  // trigger detection
  cfg_cmp_msk <= '0;
  cfg_cmp_val <= '0;
  cfg_edg_pos <= '0;
  cfg_edg_neg <= '0;
  // filter/dacimation
  cfg_dec <= '0;
  // RLE
  cfg_rle <= 1'b0;
  // bitwise input polarity
  cfg_pol <= '0;
end else begin
  if (bus.wen) begin
    // interrupt enable (status/clear are elsewhere)
    if (bus.addr[BAW-1:0]=='h04)  cfg_trg <= bus.wdata;
    if (bus.addr[BAW-1:0]=='h08)  irq_ena <= bus.wdata[  2-1:0];
    // event masks
    if (bus.addr[BAW-1:0]=='h10)  cfg_rst <= bus.wdata;
    if (bus.addr[BAW-1:0]=='h14)  cfg_str <= bus.wdata;
    if (bus.addr[BAW-1:0]=='h18)  cfg_stp <= bus.wdata;
    if (bus.addr[BAW-1:0]=='h1c)  cfg_swt <= bus.wdata;
    // trigger pre/post time
    if (bus.addr[BAW-1:0]=='h20)  cfg_pre <= bus.wdata;
    if (bus.addr[BAW-1:0]=='h24)  cfg_pst <= bus.wdata;
    // trigger detection
    if (bus.addr[BAW-1:0]=='h30)  cfg_cmp_msk <= DT'(bus.wdata);
    if (bus.addr[BAW-1:0]=='h34)  cfg_cmp_val <= DT'(bus.wdata);
    if (bus.addr[BAW-1:0]=='h38)  cfg_edg_pos <= DT'(bus.wdata);
    if (bus.addr[BAW-1:0]=='h3c)  cfg_edg_neg <= DT'(bus.wdata);
    // dacimation
    if (bus.addr[BAW-1:0]=='h40)  cfg_dec <= bus.wdata[DCW-1:0];
    // RLE
    if (bus.addr[BAW-1:0]=='h44)  cfg_rle <= bus.wdata[0];
    // bitwise input polarity
    if (bus.addr[BAW-1:0]=='h50)  cfg_pol <= DT'(bus.wdata);
  end
end

// control signals
always_ff @(posedge bus.clk)
if (~bus.rstn) begin
  evo.rst <= 1'b0;
  evo.str <= 1'b0;
  evo.stp <= 1'b0;
  evo.swt <= 1'b0;
end else begin
  if (bus.wen & (bus.addr[BAW-1:0]=='h00)) begin
    evo.rst <= bus.wdata[0];  // reset
    evo.str <= bus.wdata[1];  // start
    evo.stp <= bus.wdata[2];  // stop
    evo.swt <= bus.wdata[3];  // trigger
  end else begin
    evo.rst <= 1'b0;
    evo.str <= 1'b0;
    evo.stp <= 1'b0;
    evo.swt <= 1'b0;
  end
end

// read access
always_ff @(posedge bus.clk)
casez (bus.addr[BAW-1:0])
  // control
  'h00: bus.rdata <= {sts_trg, sts_stp, sts_str, 1'b0};
  'h04: bus.rdata <= cfg_trg;
  // interrupts enable/status/clear
  'h08: bus.rdata <= irq_ena;
  'h0c: bus.rdata <= irq_sts;
  // event masks
  'h10: bus.rdata <= cfg_rst;
  'h14: bus.rdata <= cfg_str;
  'h18: bus.rdata <= cfg_stp;
  'h1c: bus.rdata <= cfg_swt;
  // trigger pre/post time
  'h20: bus.rdata <=              32'(cfg_pre);
  'h24: bus.rdata <=              32'(cfg_pst);
  'h28: bus.rdata <=    {sts_pro, 31'(sts_pre)};
  'h2c: bus.rdata <=    {sts_pso, 31'(sts_pst)};
  // trigger detection
  'h30: bus.rdata <=                  cfg_cmp_msk;
  'h34: bus.rdata <=                  cfg_cmp_val;
  'h38: bus.rdata <=                  cfg_edg_pos;
  'h3c: bus.rdata <=                  cfg_edg_neg;
  // decimation
  'h40: bus.rdata <= {{32-DCW{1'b0}}, cfg_dec};
  // RLE configuration
  'h44: bus.rdata <= {{32-  1{1'b0}}, cfg_rle};
  // stream counter status
  'h48: bus.rdata <=              32'(sts_cur);
  'h4c: bus.rdata <=              32'(sts_lst);
  // bitwise input polarity
  'h50: bus.rdata <=              32'(cfg_pol);
  default: bus.rdata <= 'x;
endcase

// interrupt status/clear
always_ff @(posedge bus.clk)
if (~bus.rstn) begin
  irq_sts <= '0;
end else begin
  if (ctl_rst) begin
    irq_sts <= '0;
  end else if (bus.wen & (bus.addr[BAW-1:0]=='h0c)) begin
    // interrupt clear
    irq_sts <= irq_sts & ~bus.wdata[3-1:0];
  end else begin
    // interrupt set
    irq_sts <= irq_sts | {evo.lst, evo.trg} & irq_ena;
  end
end

// interrupt output
always_ff @(posedge bus.clk)
if (~bus.rstn)  irq <= '0;
else            irq <= |irq_sts;

////////////////////////////////////////////////////////////////////////////////
// Decimation
////////////////////////////////////////////////////////////////////////////////

str_dec #(
  .DN (DN),
  .CW (DCW)
) dec (
  // control
  .ctl_rst  (ctl_rst),
  // configuration
  .cfg_dec  (cfg_dec),
  // streams
  .sti      (sti),
  .sto      (std)
);

////////////////////////////////////////////////////////////////////////////////
// bitwise input polarity
////////////////////////////////////////////////////////////////////////////////

assign stn.TDATA  = std.TDATA ^ cfg_pol;
assign stn.TKEEP  = std.TKEEP ;
assign stn.TLAST  = std.TLAST ;
assign stn.TVALID = std.TVALID;

assign std.TREADY = stn.TREADY;

////////////////////////////////////////////////////////////////////////////////
// Edge detection (trigger source)
////////////////////////////////////////////////////////////////////////////////

la_trigger #(
  .DT (DT)
) trigger (
  // control
  .ctl_rst  (ctl_rst),
  // configuration
  .cfg_cmp_msk (cfg_cmp_msk),
  .cfg_cmp_val (cfg_cmp_val),
  .cfg_edg_pos (cfg_edg_pos),
  .cfg_edg_neg (cfg_edg_neg),
  // output triggers
  .sts_trg  (evo.trg),
  // stream monitor
  .sti      (stn),
  .sto      (stt)
);

////////////////////////////////////////////////////////////////////////////////
// aquire and trigger status handler
////////////////////////////////////////////////////////////////////////////////

assign ctl_rst = |(evi.rst & cfg_rst);
assign ctl_str = |(evi.str & cfg_str);
assign ctl_stp = |(evi.stp & cfg_stp);
assign ctl_trg = |(evi.swt & cfg_swt)
               | |(evi.trg & cfg_trg);

acq #(
  .DN (DN),
  .DT (DT),
  .CW (CW)
) acq (
  // stream input/output
  .sti      (stt),
  .sto      (sta_str),
  // control
  .ctl_rst  (ctl_rst),
  // control/status start
  .ctl_str  (ctl_str),
  .sts_str  (sts_str),
  // control/status stop
  .ctl_stp  (ctl_stp),
  .sts_stp  (sts_stp),
  // control/status trigger
  .ctl_trg  (ctl_trg),
  .sts_trg  (sts_trg),
  // events
  .evn_lst  (evo.lst),
  // configuration/status pre trigger
  .cfg_pre  (cfg_pre),
  .sts_pre  (sts_pre),
  .sts_pro  (sts_pro),
  // configuration/status post trigger
  .cfg_pst  (cfg_pst),
  .sts_pst  (sts_pst),
  .sts_pso  (sts_pso)
);

assign sta.TDATA  = sta_str.TDATA [0][8-1:0];
assign sta.TKEEP  = sta_str.TKEEP ;
assign sta.TLAST  = sta_str.TLAST ;
assign sta.TVALID = sta_str.TVALID;
assign sta_str.TREADY = sta.TREADY;

rle #(
  // counter properties
  .CW (8),
  // stream properties
  .DN (DN),
  .DTI (logic [  8-1:0]),
  .DTO (logic [8+8-1:0])
) rle (
  // input stream input/output
  .sti      (sta),
  .sto      (sto),
  // configuration
  .ctl_rst  (ctl_rst),
  .cfg_ena  (cfg_rle)
);

axi4_stream_cnt #(
  .DN (DN),
  .CW (CW)
) axi4_stream_cnt (
  // control
  .ctl_rst  (ctl_rst),
  // counter staus
  .sts_cur  (sts_cur),
  .sts_lst  (sts_lst),
  // stream monitor
  .str      (sto)
);

endmodule: la
