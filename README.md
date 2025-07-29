# FPGA-Based Control of Current Sensor INA219

This project implements a custom I2C Master in SystemVerilog to interface with the INA219 current and power monitor. The design runs entirely on an FPGA and does not rely on any microcontroller or CPU. It provides a reliable hardware-only method of communicating with the INA219 sensor and can be extended to support other I2C devices with minimal changes.

## RTL Description

- Bit-accurate control over start/stop conditions, address, data, ACK/NACK, and bus state
- Adjustable input (`CLK_HZ`) and I2C output (`I2C_CLK`) frequency parameters
- Handles open-drain SDA and SCL using tristate logic
- Fully automatic 16-bit I2C transactions triggered by `start_transaction`
- FSM-driven sequencer with proper edge-timed transitions
- Hardcoded default I2C address `0x40` (modifiable via `addr_rw` logic)

- Status Signals:
  - `busy` — high during active transaction
  - `transaction_done` — pulse-high at completion
  - `ack_error` — flag if slave fails to acknowledge

## Usage Notes

- Ensure SDA/SCL lines are pulled up externally (e.g., 4.7kΩ to 3.3V)
- Wrap the module in a top-level design with a state machine or control logic to manage transactions
- `write_data` is used for a write operations, and `read_data` holds the output after completion of a read operations.
- Use `transaction_done` to detect when the transfer is finished.
