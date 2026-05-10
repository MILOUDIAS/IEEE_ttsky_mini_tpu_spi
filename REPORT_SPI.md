# SPI Implementation Report

## Current Behavior

The intended SPI dataflow is:

1. The external SPI master sends a 12-bit instruction LSB-first on `mosi`.
2. `src/spi.v` collects the serial bits and emits one parallel instruction pulse on `data_buffer_output`.
3. `src/tpu.v` passes that instruction to `src/control.v`.
4. A `RUN` instruction advances the systolic array. When the drain completes, `control.v` pulses `ready_to_send`.
5. `src/array.v` continuously exposes the flattened 3x3 result matrix on `array_data_out`.
6. `src/spi.v` serializes that 36-bit flattened matrix LSB-first on `miso`.

That matches the high-level expectation, but the original SPI implementation had two practical issues:

- `ready_to_send` was a one-cycle `clk` pulse, and `spi.v` only started MISO shifting when `ready_to_send && !cs` was true in that same cycle. A normal master that releases `cs` after `RUN`, waits for the computation, and then starts a later read transaction could miss the result.
- The readback bit counter was too narrow for a 36-bit transfer completion check, so repeated or complete readbacks were not robust.

## Changes Made

The first fix latched `ready_to_send` into a pending readback request so the SPI master can start a later read transaction and still receive the result. The MISO bit counter was widened and reset between CS-framed transfers, and MOSI instruction shifting was blocked while MISO readback is active.

I added focused SPI tests under `test/spi/`:

- `test_instruction_is_parallelized_once`: verifies a 12-bit MOSI transaction produces the expected parallel instruction pulse.
- `test_ready_pulse_is_held_until_read_transaction`: verifies a one-cycle TPU ready pulse is retained until a later SPI read.
- `test_multiple_readbacks_restart_at_bit_zero`: verifies independent readbacks restart from bit 0.

## Verification

The following checks pass:

```sh
cd test/spi && make
cd test && make
```

## Async CDC Hardening

The initial implementation mixed `sclk` and `clk` domain state directly. That can work in ideal RTL simulations but is not a production-quality asynchronous SPI boundary. The SPI block now uses explicit clock-domain-crossing handshakes:

- SPI instruction capture remains in the `sclk` domain.
- Completed instructions cross into `clk` using a synchronized toggle request. The instruction word is held stable until the next complete SPI instruction frame; this matches the current assumption that `clk` is fast enough to observe one instruction before the next one finishes.
- TPU result availability crosses back into the `sclk` domain using a toggle request and acknowledgement.
- Multi-bit result data is held stable while the result handshake is pending.

This avoids relying on single-cycle pulses crossing unrelated clocks.

## Readback Protocol Note

After `RUN`, the first post-ready SPI transaction is consumed as the MISO result readback. While the readback is active, MOSI bits are ignored and the 36-bit flattened result matrix is shifted LSB-first on `miso`.

Because the result request is synchronized into the `sclk` domain, the master must provide two SCLK edges after lowering `cs` before payload bit 0 is valid. The regression tests model this by ignoring the first two readback edges and then collecting 36 bits.

The top-level cocotb test now verifies the intended SPI result path directly: it sends LOAD/RUN over MOSI and reads the flattened matrix over MISO, rather than using STORE instructions and `uo_out` after `RUN`.
