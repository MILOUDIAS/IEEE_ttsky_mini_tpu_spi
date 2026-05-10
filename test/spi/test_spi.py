import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


INSTRUCTION_BITS = 12
OUTPUT_BITS = 36


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.mosi.value = 0
    dut.cs.value = 1
    dut.sclk.value = 0
    dut.ready_to_send.value = 0
    dut.data_in.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def sclk_rising(dut):
    dut.sclk.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)


async def sclk_falling(dut):
    dut.sclk.value = 0
    await RisingEdge(dut.clk)


async def send_instruction(dut, instr):
    observed = False
    dut.cs.value = 0
    await RisingEdge(dut.clk)

    for bit_idx in range(INSTRUCTION_BITS):
        dut.mosi.value = (instr >> bit_idx) & 1
        await RisingEdge(dut.clk)
        await sclk_rising(dut)
        observed = observed or int(dut.data_buffer_output.value) == instr
        await sclk_falling(dut)
        observed = observed or int(dut.data_buffer_output.value) == instr

    await RisingEdge(dut.clk)
    observed = observed or int(dut.data_buffer_output.value) == instr
    await RisingEdge(dut.clk)
    observed = observed or int(dut.data_buffer_output.value) == instr
    dut.cs.value = 1
    await RisingEdge(dut.clk)
    observed = observed or int(dut.data_buffer_output.value) == instr
    return observed


async def read_output_bits(dut):
    bits = []
    dut.cs.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)

    for _ in range(8):
        await sclk_rising(dut)
        if int(dut.is_sending.value):
            bits.append(int(dut.miso.value))
            await sclk_falling(dut)
            break
        await sclk_falling(dut)

    assert bits, "readback did not start after result request was synchronized"

    while len(bits) < OUTPUT_BITS:
        await sclk_rising(dut)
        bits.append(int(dut.miso.value))
        await sclk_falling(dut)

    dut.cs.value = 1
    await RisingEdge(dut.clk)
    return sum(bit << idx for idx, bit in enumerate(bits))


async def pulse_ready(dut):
    dut.ready_to_send.value = 1
    await RisingEdge(dut.clk)
    dut.ready_to_send.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_instruction_is_parallelized_once(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    instr = 0x6A5
    observed = await send_instruction(dut, instr)

    assert observed, (
        f"SPI did not pulse instruction 0x{instr:03x} on data_buffer_output; "
        f"data_buffer=0x{int(dut.data_buffer.value):03x}, "
        f"bit_counter={int(dut.bit_counter.value)}, "
        f"bit_counter_prev={int(dut.bit_counter_prev.value)}"
    )


@cocotb.test()
async def test_ready_pulse_is_held_until_read_transaction(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    expected = 0xA5_5A_C3_3F & ((1 << OUTPUT_BITS) - 1)
    dut.data_in.value = expected

    await pulse_ready(dut)

    for _ in range(5):
        await RisingEdge(dut.clk)

    observed = await read_output_bits(dut)
    assert observed == expected, (
        f"delayed readback returned 0x{observed:09x}, expected 0x{expected:09x}"
    )


@cocotb.test()
async def test_multiple_readbacks_restart_at_bit_zero(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    patterns = [0x001_234_567, 0x00A_BCD_EF0]
    for expected in patterns:
        expected &= (1 << OUTPUT_BITS) - 1
        dut.data_in.value = expected
        await pulse_ready(dut)
        observed = await read_output_bits(dut)
        assert observed == expected, (
            f"readback returned 0x{observed:09x}, expected 0x{expected:09x}"
        )
