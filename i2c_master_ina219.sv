module i2c_master_ina219 #(
  parameter int CLK_HZ = 50_000_000,   // Input system clock frequency (Hz)
  parameter int I2C_CLK = 100_000      // Desired I2C clock (Hz)
)(
  input  logic        clk,                 // System clock
  input  logic        reset_n,             // Active-low synchronous reset
  input  logic        enable,              // Enables I2C logic
  input  logic        start_transaction,   // Initiates I2C read operation
  input  logic        rw,                  // Read/Write control (0 = Write, 1 = Read)
  input logic [7:0]  reg_pointer,         // Register address to access
  input logic [15:0] write_data,          // 16-bit write result
  output logic [15:0] read_data,           // 16-bit read result
  output logic        busy,                // Indicates transaction in progress
  output logic        ack_error,           // Acknowledge error flag
  output logic        transaction_done,    // Signals end of transaction
  inout  wire         sda,                 // I2C data line
  inout  wire         scl                  // I2C clock line
);

  //==================================================
  // Internal signals
  //==================================================
  logic sda_ena_n;                    // Active-low control for driving SDA
  logic frame;                        // Indicates frame progress (e.g., byte 1 or 2)
  logic [7:0] addr_rw;                // Combined 7-bit address and R/W bit
  assign addr_rw = {7'b1000000, rw};

  int unsigned bit_cnt;              // Bit counter for transmit/receive

  //==================================================
  // Clock Divider for I2C SCL Generation
  //==================================================
  localparam int divider = (CLK_HZ / I2C_CLK);
  int unsigned count;
  logic scl_ena_n, data_pulse, prev_data_pulse;

  // SCL & SDA tristate control
  assign sda = (sda_ena_n == 1'b0) ? 1'b0 : 1'bz;
  assign scl = (scl_ena_n == 1'b0) ? data_pulse : 1'b1;

  // Generates SCL/data pulse signal using system clock
  always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      count           <= 0;
      data_pulse      <= 1;
      prev_data_pulse <= 1;
    end else if (enable) begin
      prev_data_pulse <= data_pulse;

      if (start_transaction) begin
        count      <= 0;
        data_pulse <= 1;
      end else if (count == divider - 1) begin
        count      <= 0;
        data_pulse <= 1;
      end else if (count > (divider / 2) - 1) begin
        data_pulse <= 0;
        count      <= count + 1;
      end else begin
        data_pulse <= 1;
        count      <= count + 1;
      end
    end else begin
      count           <= 0;
      data_pulse      <= 1;
      prev_data_pulse <= 1;
    end
  end

  //==================================================
  // FSM States Definition
  //==================================================
  typedef enum logic [3:0] {
    READY,
    START,
    COMMAND,
    SLV_ACK1,
    RD,
    WR,
    WR_REGISTER,
    SLV_ACK2,
    MSTR_ACK,
    STOP,
    END_TRANSACTION
  } state_t;

  state_t state;

  //==================================================
  // FSM: I2C Transaction Sequencer
  //==================================================
  always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      state            <= READY;
      busy             <= 1'b0;
      frame            <= 1'b0;
      scl_ena_n        <= 1'b1;
      sda_ena_n        <= 1'b1;
      bit_cnt          <= 7;
      transaction_done <= 1'b0;
      ack_error        <= 1'b0;
      read_data        <= 16'd0;
    end else begin
      transaction_done <= 1'b0;

      case (state)
        //==================================================
        // READY: Idle state
        //==================================================
        READY: begin
          busy      <= 1'b0;
          frame     <= 1'b0;
          scl_ena_n <= 1'b1;
          sda_ena_n <= 1'b1;
          bit_cnt <= 7;
          ack_error <= 1'b0;
          if (start_transaction) begin
            busy      <= 1'b1;
            scl_ena_n <= 1'b0;
            sda_ena_n <= 1'b0;  // Start condition
            state     <= START;
          end
        end

        //==================================================
        // START: Drive SDA low to initiate I2C start
        //==================================================
        START: begin
          if (prev_data_pulse == 1'b1 && data_pulse == 1'b0) begin
            sda_ena_n <= addr_rw[bit_cnt];
            bit_cnt   <= bit_cnt - 1;
            state     <= COMMAND;
          end
        end

        //==================================================
        // COMMAND: Send address + RW bit
        //==================================================
        COMMAND: begin
          if (prev_data_pulse == 1'b1 && data_pulse == 1'b0) begin
            sda_ena_n <= addr_rw[bit_cnt];
            if (bit_cnt == 0) begin
              state <= SLV_ACK1;
            end else begin
              bit_cnt <= bit_cnt - 1;
            end
          end
        end

        //==================================================
        // SLV_ACK1: Expect ACK from slave
        //==================================================
        SLV_ACK1: begin
          if (prev_data_pulse == 1'b1 && data_pulse == 1'b0) begin
            sda_ena_n <= 1'b1; // Release SDA line
            frame <= 1'b0;
            if (rw) begin
              bit_cnt <= 15;
              state <= RD;
            end else begin
              bit_cnt <= 7;
              state <= WR;
            end
          end
        end

        //==================================================
        // WR: Write bits to slave
        //==================================================
        WR: begin
          if (prev_data_pulse == 1'b0 && data_pulse == 1'b1) begin
            if (bit_cnt == 7) begin
              ack_error <= sda;
            end
          end else if (prev_data_pulse == 1'b1 && data_pulse == 1'b0) begin

            sda_ena_n <= reg_pointer[bit_cnt];

            if (bit_cnt == 0) begin

              unique case (reg_pointer)
                8'h00: begin
                  bit_cnt <= 15;
                end
                8'h05: begin
                  bit_cnt <= 15;
                end
                default: begin
                  bit_cnt <= 0;
                end
              endcase
              state <= SLV_ACK2;

            end else begin
              bit_cnt <= bit_cnt - 1;
            end
          end
        end

        //==================================================
        // WR_REGISTER: Send register MSB & LSB
        //==================================================
        WR_REGISTER: begin
          if (prev_data_pulse == 1'b1 && data_pulse == 1'b0) begin

            sda_ena_n <= write_data[bit_cnt];
            bit_cnt <= bit_cnt - 1;

            if (bit_cnt == 0 || bit_cnt == 8) begin
              state <= SLV_ACK2;
            end

          end
        end

        //==================================================
        // SLV_ACK2: Expect ACK from slave
        //==================================================
        SLV_ACK2: begin
          if (prev_data_pulse == 1'b1 && data_pulse == 1'b0) begin

            sda_ena_n <= 1'b1; // Release SDA line

            if (bit_cnt == 7 || bit_cnt == 15) begin
              state <= WR_REGISTER;
            end else begin
              state <= STOP;
            end
            
          end
        end

        //==================================================
        // RD: Read bits from slave
        //==================================================
        RD: begin
          if (prev_data_pulse == 1'b0 && data_pulse == 1'b1) begin
            if (bit_cnt == 15 || bit_cnt == 7) begin
              ack_error <= sda;
            end else begin
              read_data <= {read_data[14:0], sda};
            end
          end else if (prev_data_pulse == 1'b1 && data_pulse == 1'b0) begin
            sda_ena_n <= 1'b1; // Release SDA to read
            bit_cnt   <= bit_cnt - 1;

            if (bit_cnt == 0 || bit_cnt == 8) begin
              state <= MSTR_ACK;
            end

          end
        end

        //==================================================
        // MSTR_ACK: Send ACK/NACK from master
        //==================================================
        MSTR_ACK: begin
          if (prev_data_pulse == 1'b0 && data_pulse == 1'b1) begin
            read_data <= {read_data[14:0], sda};
          end else if (prev_data_pulse == 1'b1 && data_pulse == 1'b0) begin
            sda_ena_n <= 1'b0;
            if (bit_cnt == 7) begin
              frame <= 1'b1;
              state <= RD;
            end else begin
              frame <= 1'b0;
              state <= STOP;
            end
          end
        end

        //==================================================
        // STOP: Drive SDA low to initiate I2C start
        //==================================================
        STOP: begin
          if (prev_data_pulse == 1'b1 && data_pulse == 1'b0) begin   
            sda_ena_n <= 1'b0;
            state <= END_TRANSACTION;
          end else if (data_pulse == 1'b1) begin
            scl_ena_n <= 1'b1; // Release SCL line
          end
        end

        //==================================================
        // End of transaction
        //==================================================
        END_TRANSACTION: begin
          sda_ena_n        <= 1'b1;
          transaction_done <= 1'b1;
          state            <= READY;
        end

        default: state <= READY;
      endcase
    end
  end

endmodule
