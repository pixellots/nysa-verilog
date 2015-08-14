/*
Copyright (c) 2015 Dave McCoy (dave.mccoy@cospandesign.com)

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

/*
 * Author: David McCoy
 * Description: Card Controller for device side of SDIO
 *  This layer is above the PHY, it expects that data will arrive as data
 *  values instead of a stream of bits
 *  This behaves as a register map and controls data transfers
 *
 *  SPI MODE IS NOT SUPORTED YET, SO IF CS_N IS LOW DO NOT REPSOND!
 *
 * Changes:
 *  2015.08.09: Inital Commit
 *  2015.08.13: Changed name to card controller
 */


/* TODO:
 *  - How to implement busy??
 */

module sdio_device_card_cnt #(
  parameter                 NUM_FUNCS       = 1,        /* Number of SDIO Functions available */
  parameter                 MEM_PRESENT     = 0,        /* Not supported yet */
  parameter                 UHSII_AVAILABLE = 0,        /* UHS Mode Not available yet */
  parameter                 IO_OCR          = 24'hFFF0, /* Operating condition mode (voltage range) */
  parameter                 BUFFER_DEPTH    = 8,        /* 256 byte depth buffer */
  parameter                 EN_8BIT_BUS     = 0         /* Enable 8-bit bus */
)(
  input                     sdio_clk,
  input                     rst,

  //Function Interface
  output  reg               func_stb,
  input                     func_ack_stb,
  output  reg               func_num,
  output  reg               func_write_flag,      /* Read = 0, Write = 1 */
  output  reg               func_read_after_write,
  output  reg   [17:0]      func_reg_addr,
  output  reg   [7:0]       func_reg_write_data,
  input         [7:0]       func_reg_read_data,
  output                    func_dat_rdy,

  output  reg               tunning_block,



  //Function Interface From CCCR
  output        [7:0]       o_func_enable,
  input         [7:0]       i_func_ready,
  output        [7:0]       o_func_int_enable,
  input         [7:0]       i_func_int_pending,
  input         [7:0]       i_func_ready_for_data,
  output        [2:0]       o_func_abort_stb,
  output        [3:0]       o_func_select,
  input         [7:0]       i_func_exec_status,

  output                    o_soft_reset,
  output                    o_en_card_detect_n,
  output                    o_en_4bit_block_int,
  input                     i_func_active,
  output                    o_bus_release_req_stb,
  output        [15:0]      o_max_f0_block_size,

  output                    o_1_bit_mode,
  output                    o_4_bit_mode,
  output                    o_8_bit_mode,

  output                    o_sdr_12,
  output                    o_sdr_25,
  output                    o_sdr_50,
  output                    o_ddr_50,
  output                    o_sdr_104,

  output                    o_driver_type_a,
  output                    o_driver_type_b,
  output                    o_driver_type_c,
  output                    o_driver_type_d,
  output                    o_enable_async_interrupt



  //PHY Interface
  input                     cmd_stb,
  input                     cmd_crc_good_stb,
  input         [5:0]       cmd,
  input         [31:0]      cmd_arg,
  input                     cmd_phy_idle,

  input                     chip_select_n,

  output        [135:0]     rsps,
  output        [7:0]       rsps_len,
  output  reg               rsps_stb

);
//local parameters
localparam      NORMAL_RESPONSE     = 1'b0;
localparam      EXTENDED_RESPONSE   = 1'b1;

localparam      RESET               = 4'h0;
localparam      INITIALIZE          = 4'h1;
localparam      STANDBY             = 4'h2;
localparam      COMMAND             = 4'h3;
localparam      TRANSFER            = 4'h4;
localparam      INACTIVE            = 4'h5;

localparam      R1                  = 4'h0;
localparam      R4                  = 4'h1;
localparam      R5                  = 4'h2;
localparam      R6                  = 4'h3;
localparam      R7                  = 4'h4;

//registes/wires
reg             [3:0]       state;

reg             [47:0]      response_value;
reg             [136:0]     response_value_extended;
reg                         response_type;
reg             [15:0]      register_card_address;  /* Host can set this so later it can be used to identify this card */
reg             [3:0]       voltage_select;
reg                         v1p8_sel;
reg             [23:0]      vio_ocr;
reg                         busy;

reg                         bad_crc;
reg                         cmd_arg_out_of_range;
reg                         illegal_command;
reg                         card_error;

reg             [3:0]       response_index;

wire            [1:0]       r5_cmd;
wire            [15:0]      max_f0_block_size;
wire                        enable_async_interrupt;
wire                        data_txrx_in_progress_flag,

reg             [3:0]       component_select;


/*
 * Needed
 *
 *  OCR (32 bit) CMD5 (SD_CMD_SEND_OP_CMD) ****
 *  X CID (128 bit) CMD10 (SD_CMD_SEND_CID) NOT SUPPORTED ON SDIO ONLY
 *  X CSD (128 bit) CMD9  (SD_CMD_SEND_CSD) NOT SUPPORTED ON SDIO ONLY
 *  RCA (16 bit) ???
 *  X DSR (16 bit optional) NOT SUPPORTED ON SDIO ONLY
 *  X SCR (64 bit) NOT SUPPORTED ON SDIO ONLY
 *  X SD_CARD_STATUS (512 bit) NOT SUPPORED ON SDIO ONLY
 *  CCCR
 */

//Function to Controller
wire  [7:0]                 fc_ready;         //(Bitmask) Function is ready to receive data

//Controller to Function
wire  [7:0]                 fc_activate;      //(Bitmask) Activate a function transaction
wire                        cf_ready;         //Controller is ready to receive data
wire                        cf_write_flag;    //This is a write transaction
wire                        cf_inc_addr_flag; //Increment the Address
wire  [17:0]                cf_address;       //Offset Removed, this will enable modular function


//submodules
sdio_device_cccr #(
  .BUFFER_DEPTH   (BUFFER_DEPTH   ),
  .EN_8BIT_BUS    (EN_8BIT_BUS    )
) cccr (
  .sdio_clk                 (sdio_clk               ),
  .rst                      (rst                    ),

  input                     i_activate,
  input                     i_ready,
  output  reg               o_ready,
  output  reg               o_finished,
  input                     i_write_flag,
  input                     i_inc_addr,
  input         [17:0]      i_address,
  input                     i_data_stb,
  input         [17:0]      i_data_count,
  input         [7:0]       i_data_in,
  output        [7:0]       o_data_out,
  output  reg               o_data_stb,  //If reading, this strobes a new piece of data in, if writing strobes data out

  //Function Interface
  output        [7:0]       o_func_enable,
  input         [7:0]       i_func_ready,
  output        [7:0]       o_func_int_enable,
  input         [7:0]       i_func_int_pending,
  input         [7:0]       i_func_ready_for_data,
  output        [2:0]       o_func_abort_stb,
  output        [3:0]       o_func_select,
  input         [7:0]       i_func_exec_status,

  output                    o_en_card_detect_n,
  output                    o_en_4bit_block_int,
  input                     i_func_active,
  output                    o_bus_release_req_stb,
  .o_soft_reset                 (o_soft_reset               ),
  .i_data_txrx_in_progress_flag (data_txrx_in_progress_flag ),

  .o_max_f0_block_size          (max_f0_block_size          ),
                                                            
  .o_1_bit_mode                 (o_1_bit_mode               ),
  .o_4_bit_mode                 (o_4_bit_mode               ),
  .o_8_bit_mode                 (o_8_bit_mode               ),
                                                            
  .o_sdr                        (o_sdr_12                   ),
  .o_sdr                        (o_sdr_25                   ),
  .o_sdr                        (o_sdr_50                   ),
  .o_ddr                        (o_ddr_50                   ),
  .o_sdr                        (o_sdr_104                  ),
                                                            
  .o_driver_type_a              (o_driver_type_a            ),
  .o_driver_type_b              (o_driver_type_b            ),
  .o_driver_type_c              (o_driver_type_c            ),
  .o_driver_type_d              (o_driver_type_d            ),
  .o_enable_async_interrupt     (enable_async_interrupt     )

);


//asynchronous logic
always @ (*) begin
  if (rst || o_soft_rest) begin
    component_select      <=  `NO_SELECT_INDEX;
  end
  else begin
    if      ((func_reg_addr >= `CCCR_FUNCITON_START_ADDR)  && (func_reg_addr <= `CCCR_FUNCTION_END_ADDR )) begin
      //CCCR Selected
      component_select      <=  `CCCR_INDEX;
    end
    else if ((func_reg_addr >= `FUNCITON_1_START_ADDR)     && (func_reg_addr <= `FUNCTION_1_END_ADDR    )) begin
      //Fuction 1 Sected
      component_select      <=  `F1_INDEX;
    end
    else if ((func_reg_addr >= `FUNCITON_2_START_ADDR)     && (func_reg_addr <= `FUNCTION_2_END_ADDR    )) begin
      //Fuction 2 Sected
      component_select      <=  `F2_INDEX;
    end                                                   
    else if ((func_reg_addr >= `FUNCITON_3_START_ADDR)     && (func_reg_addr <= `FUNCTION_3_END_ADDR    )) begin
      //Fuction 3 Sected
      component_select      <=  `F3_INDEX;
    end                                                   
    else if ((func_reg_addr >= `FUNCITON_4_START_ADDR)     && (func_reg_addr <= `FUNCTION_4_END_ADDR    )) begin
      //Fuction 4 Sected
      component_select      <=  `F4_INDEX;
    end                                                   
    else if ((func_reg_addr >= `FUNCITON_5_START_ADDR)     && (func_reg_addr <= `FUNCTION_5_END_ADDR    )) begin
      //Fuction 5 Sected
      component_select      <=  `F5_INDEX;
    end                                                   
    else if ((func_reg_addr >= `FUNCITON_6_START_ADDR)     && (func_reg_addr <= `FUNCTION_6_END_ADDR    )) begin
      //Fuction 6 Sected
      component_select      <=  `F6_INDEX;
    end                                                   
    else if ((func_reg_addr >= `FUNCITON_7_START_ADDR)     && (func_reg_addr <= `FUNCTION_7_END_ADDR    )) begin
      //Fuction 7 Sected
      component_select      <=  `F7_INDEX;
    end
    else if ((func_reg_addr >= `MAIN_CIS_START_ADDR)       && (func_reg_addr <= `MAIN_CIS_END_ADDR      )) begin
      //Main CIS Region
      component_select      <=  `MAIN_CIS_INDEX;
    end
    else begin
      component_select      <=  `NO_SELECT_INDEX;
    end
  end
end

assign  rsps[135]   = 1'b0; //Start bit
assign  rsps[134]   = 1'b0; //Direction bit (to the host)
assign  rsps[133:0] = response_type ? response_value_extended[133:0] : {response_value[45:0], 87'h0};
assign  rsps_len    = response_type ? 128 : 40;

assign  r5_cmd      = (state == RESET) || (state == INITIALIZE) || (state == STANDBY) || (state == INACTIVE) ? 2'b00 :
                      (state == COMMAND)                                                                     ? 2'b01 :
                      (state == TRANSFER)                                                                    ? 2'b10 :
                                                                                                               2'b11;

assign  func_dat_rdy= cmd_phy_idle; /* Can only send data when cmd phy is not sending data */
//synchronous logic


always @ (posedge sdio_clk) begin
  if (rst) begin
    response_type           <=  NORMAL_RESPONSE;
    response_value          <=  32'h00000000;
    response_value_extended <=  128'h00;
  end
  else if (rsps_stb || func_ack_stb) begin
    //Strobe
    //Process Command
    case (response_index)
      R1: begin
        //R1
        response_type                                                     <=  NORMAL_RESPONSE;
        response_value                                                    <=  48'h0;
        response_value[`CMD_RSP_CMD]                                      <=  cmd;
        response_value[`R1_OUT_OF_RANGE]                                  <=  cmd_arg_out_of_range;
        response_value[`R1_COM_CRC_ERROR]                                 <=  bad_crc;
        response_value[`R1_ILLEGAL_COMMAND]                               <=  illegal_command;
        response_value[`R1_ERROR]                                         <=  card_error;
        response_value[`R1_CURRENT_STATE]                                 <=  4'hF;
      end
      R4: begin
        //R4:
        response_type                                                     <=  NORMAL_RESPONSE;
        response_value                                                    <=  48'h0;
        response_value[`R4_RSRVD]                                         <=  6'h3F;
        response_value[`R4_READY]                                         <=  1'b1;
        response_value[`R4_NUM_FUNCS]                                     <=  NUM_FUNCS;
        response_value[`R4_MEM_PRESENT]                                   <=  MEM_PRESENT;
        response_value[`R4_UHSII_AVAILABLE]                               <=  UHSII_AVAILABLE;
        response_value[`R4_IO_OCR]                                        <=  24'hFFFF00;
        response_value[15:8]                                              <=  8'h00;
      end
      R5: begin
        //R5:
        response_type                                                     <=  NORMAL_RESPONSE;
        response_value                                                    <=  48'h0;
        response_value[`CMD_RSP_CMD]                                      <=  cmd;
        response_value[`R5_FLAG_CRC_ERROR]                                <=  bad_crc;
        response_value[`R5_INVALID_CMD]                                   <=  illegal_command;
        response_value[`R5_FLAG_CURR_STATE]                               <=  r5_cmd;
        response_value[`R5_FLAG_ERROR]                                    <=  card_error;
      end
      R6: begin
        //R6: Relative address response
        response_type                                                     <=  NORMAL_RESPONSE;
        response_value                                                    <=  48'h0;
        response_value[`CMD_RSP_CMD]                                      <=  cmd;
        response_value[`R6_REL_ADDR]                                      <=  register_card_address;
        response_value[`R6_STS_CRC_COMM_ERR]                              <=  bad_crc;
        response_value[`R6_STS_ILLEGAL_CMD]                               <=  illegal_command;
        response_value[`R6_STS_ERROR]                                     <=  card_error;
      end
      R7: begin
        //R7
        response_type                                                     <=  NORMAL_RESPONSE;
        response_value                                                    <=  48'h0;
        response_value[`CMD_RSP_CMD]                                      <=  cmd;
        response_value[`R7_VHS]                                           <=  cmd_arg[`CMD5_ARG_VHS] & `VHS_DEFAULT_VALUE;
        response_value[`R7_PATTERN]                                       <=  cmd_arg[`CMD8_ARG_PATTERN];
      end
      default: begin
      end
    endcase
  end
end


always @ (posedge sdio_clk) begin
  //Deassert Strobes
  rsps_stb                  <=  0;
  func_stb                  <=  0;

  if (rst || o_soft_reset) begin
    state                   <=  INITIALIZE;
    register_card_address   <=  16'h0001;       // Initializes the RCA to 0
    voltage_select          <=  `VHS_DEFAULT_VALUE;
    v1p8_sel                <=  0;
    vio_ocr                 <=  24'hFFFF00;

    bad_crc                 <=  0;
    cmd_arg_out_of_range    <=  0;
    illegal_command         <=  0;              //Illegal Command for the Given State
    card_error              <=  0;              //Unknown Error

    func_stb                <=  0;
    func_write_flag         <=  0;              /* Read Write Flag R = 0, W = 1 */
    func_num                <=  4'h0;
    func_read_after_write   <=  0;
    func_reg_addr           <=  18'h0;
    busy                    <=  0;

    response_index          <=  0;
    tunning_block           <=  0;

  end
  else if (cmd_stb && !cmd_crc_good_stb) begin
    bad_crc                 <=  1;
    //Do not send a response
  end
  else if (cmd_stb) begin
    //Strobe
    //Card Bootup Sequence
    case (state)
      RESET: begin
        state                       <= INITIALIZE;
      end
      INITIALIZE: begin
        case (cmd)
          `SD_CMD_IO_SEND_OP_CMD: begin
            response_index          <=  R4;
            rsps_stb                <=  1;
          end
          `SD_CMD_SEND_RELATIVE_ADDR: begin
            state                   <=  STANDBY;
            response_index          <=  R6;
            rsps_stb                <=  1;
          end
          `SD_CMD_GO_INACTIVE_STATE: begin
            state                   <=  INACTIVE;
          end
          default: begin
            illegal_command         <=  1;
          end
        endcase
      end
      STANDBY: begin
        case (cmd)
          `SD_CMD_SEND_RELATIVE_ADDR: begin
            state                   <=  STANDBY;
            response_index          <=  R6;
            rsps_stb                <=  1;
          end
          `SD_CMD_SEL_DESEL_CARD: begin
            if (register_card_address == cmd_arg[15:0]) begin
              state                 <= COMMAND;
            end
            response_index          <=  R1;
            rsps_stb                <=  1;
          end
          `SD_CMD_GO_INACTIVE_STATE: begin
            state                   <=  INACTIVE;
          end
          default: begin
            illegal_command         <=  1;
          end
        endcase
      end
      COMMAND: begin
        case (cmd)
          `SD_CMD_IO_RW_DIRECT: begin
            func_write_flag         <= cmd_arg[`CMD52_ARG_RW_FLAG ];
            func_num                <= cmd_arg[`CMD52_ARG_FNUM    ];
            func_read_after_write   <= cmd_arg[`CMD52_ARG_RAW_FLAG];
            func_reg_addr           <= cmd_arg[`CMD52_ARG_REG_ADDR];
            func_reg_write_data     <= cmd_arg[`CMD52_ARG_WR_DATA ];
            func_stb                <= 1;
            busy                    <= 1;
            rsps_stb                <= 1;
          end
          `SD_CMD_SEL_DESEL_CARD: begin
            if (register_card_address != cmd_arg[15:0]) begin
              state                 <= STANDBY;
            end
            response_index          <=  R1;
            rsps_stb                <=  1;
          end
          `SD_CMD_SEND_TUNNING_BLOCK: begin
            response_index          <=  R1;
            rsps_stb                <=  1;
            tunning_block           <=  1;
          end
          `SD_CMD_IO_RW_DIRECT: begin
            rsps_stb                <=  1;
          end
          `SD_CMD_IO_RW_EXTENDED: begin
            response_index          <=  R5;
            state                   <=  TRANSFER;
            rsps_stb                <=  1;
          end
          `SD_CMD_GO_INACTIVE_STATE: begin
            state                   <=  INACTIVE;
          end
          default: begin
            illegal_command         <=  1;
          end
        endcase
      end
      TRANSFER: begin
        if (func_ack_stb) begin
          state                     <=  COMMAND;
        end
        case (cmd)
          `SD_CMD_IO_RW_DIRECT: begin
            func_write_flag         <= cmd_arg[`CMD52_ARG_RW_FLAG ];
            func_num                <= cmd_arg[`CMD52_ARG_FNUM    ];
            func_read_after_write   <= cmd_arg[`CMD52_ARG_RAW_FLAG];
            func_reg_addr           <= cmd_arg[`CMD52_ARG_REG_ADDR];
            func_reg_write_data     <= cmd_arg[`CMD52_ARG_WR_DATA ];
            func_stb                <= 1;
            busy                    <= 1;
            rsps_stb                <= 1;
          end
          default: begin
            illegal_command         <=  1;
          end
        endcase
      end
      INACTIVE: begin
        //Nothing Going on here
      end
      default: begin
      end
    endcase



    //Always Respond to these commands regardless of state
    if (cmd_stb) begin
      case (cmd)
        `SD_CMD_GO_IDLE_STATE: begin
          $display ("Initialize SD or SPI Mode, SPI MODE NOT SUPPORTED NOW!!");
          illegal_command           <=  0;
          response_index            <=  R1;
          if (!chip_select_n) begin
            //We are in SD Mode
            rsps_stb                <=  1;
          end
          else begin
            //XXX: SPI MODE IS NOT SUPPORTED YET!!!
          end
        end
        `SD_CMD_SEND_IF_COND: begin
          $display ("Send Interface Condition");
          illegal_command           <=  0;
          response_index            <=  R7;
          /*XXX Check if this should IO_OCR */
          if (cmd_arg[`CMD5_ARG_VHS] & `VHS_DEFAULT_VALUE) begin
            v1p8_sel                <=  cmd_arg[`CMD5_ARG_S18R];
            vio_ocr                 <=  cmd_arg[`CMD5_ARG_VHS ];
            if (cmd_arg[`CMD5_ARG_VHS] & `VHS_DEFAULT_VALUE)
              voltage_select        <=  cmd_arg[`CMD5_ARG_VHS ] & `VHS_DEFAULT_VALUE;
            rsps_stb                <=  1;
          end
        end
        `SD_CMD_VOLTAGE_SWITCH: begin
          $display ("Voltage Mode Switch");
          illegal_command           <=  0;
          response_index            <=  R1;
          rsps_stb                  <=  1;
        end
        default: begin
        end
      endcase
    end
  end
  else if (rsps_stb) begin
    //Whenever a response is successful de-assert any of the errors, they will have been picked up by the response
    bad_crc                         <=  0;
    cmd_arg_out_of_range            <=  0;
    illegal_command                 <=  0;
    card_error                      <=  0;  //Unknown Error
  end
  else if (func_ack_stb) begin
    busy                    <=  0;
  end
end

endmodule