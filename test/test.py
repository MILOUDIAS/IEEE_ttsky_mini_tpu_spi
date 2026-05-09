# =========================================================
# Mini TPU Test
#
# Drives the SPI front-end as the only input/output channel:
#   ui_in[0] = mosi
#   ui_in[1] = cs    (active-low; 0 = selected)
#   ui_in[2] = sck
#   uo_out   = matmul result (lower 4 bits valid)
#   uio_out[0] = miso
#
# Instructions are 12-bit (LSB first):
#   [11:10] opcode  (01=RUN, 10=LOAD, 11=STORE)
#   [9]     mem_sel (0=A, 1=B for LOAD)
#   [7:6]   row
#   [5:4]   col
#   [3:0]   imm     (LOAD payload)
#
# Works in both RTL and gate-level (GATES=yes) flows.
# =========================================================
import os
import random
import cocotb
from cocotb.clock    import Clock
from cocotb.triggers import RisingEdge


GL_TEST = bool(os.environ.get("GATES") == "yes")

OP_RUN, OP_LOAD, OP_STORE = 0b01, 0b10, 0b11


def make_instr(op, mem_sel=0, row=0, col=0, imm=0):
    return ((op & 3) << 10) | ((mem_sel & 1) << 9) | \
           ((row & 3) << 6) | ((col & 3) << 4) | (imm & 0xf)


def _safe_int(val, default=0):
    """Read a possibly-X LogicArray as an int, falling back to ``default``."""
    try:
        return int(val)
    except (ValueError, TypeError):
        return default


async def send_instr(dut, instr):
    # Drop CS (bit 1) and SCK (bit 2): cs=0, sck=0, mosi=0.
    dut.ui_in.value = _safe_int(dut.ui_in.value) & 0xf9
    await RisingEdge(dut.clk)

    for i in range(12):
        bit = (instr >> i) & 1
        # Settle MOSI with SCK low first; this avoids a setup-time race
        # in GL sims where the MOSI and SCK paths can have different gate
        # delays. Without this, the rising SCK can latch the previous
        # MOSI value instead of `bit`.
        dut.ui_in.value = (_safe_int(dut.ui_in.value) & 0xf8) | bit
        await RisingEdge(dut.clk)
        # Now raise SCK with MOSI already stable.
        dut.ui_in.value = _safe_int(dut.ui_in.value) | 4
        await RisingEdge(dut.clk)
        await RisingEdge(dut.clk)
        # Drop SCK; keep MOSI/CS state.
        dut.ui_in.value = _safe_int(dut.ui_in.value) & 0xfb
        await RisingEdge(dut.clk)

    # Raise CS so the SPI block is idle between instructions.
    dut.ui_in.value = (_safe_int(dut.ui_in.value) & 0xf9) | 2
    await RisingEdge(dut.clk)


async def hw_reset(dut, n=3):
    dut.rst_n.value = 0
    for _ in range(n):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def matmul_ref(a, b):
    n = len(a)
    c = [[0] * n for _ in range(n)]
    for i in range(n):
        for j in range(n):
            c[i][j] = sum(a[i][k] * b[k][j] for k in range(n)) & 0xf
    return c


async def load_matrices(dut, a, b):
    for r in range(3):
        for c in range(3):
            await send_instr(dut, make_instr(OP_LOAD, 0, r, c, a[r][c] & 0xf))
    # The systolic array expects B transposed: column j of B flows down
    # column j of the array, so memory_b[r][c] must hold B[c][r].
    for r in range(3):
        for c in range(3):
            await send_instr(dut, make_instr(OP_LOAD, 1, r, c, b[c][r] & 0xf))


async def read_matrix(dut):
    out = [[0] * 3 for _ in range(3)]
    for r in range(3):
        for c in range(3):
            await send_instr(dut, make_instr(OP_STORE, 0, r, c))
            # Allow the STORE-row/col latch and result mux to settle.
            await RisingEdge(dut.clk)
            await RisingEdge(dut.clk)
            out[r][c] = _safe_int(dut.uo_out.value) & 0xf
    return out


async def run_once(dut, a, b):
    await hw_reset(dut)
    await load_matrices(dut, a, b)

    # Trigger the matmul. The control unit's drain counter walks 1..2N+1;
    # 16 clk cycles is plenty for the 3x3 array to finish.
    await send_instr(dut, make_instr(OP_RUN))
    for _ in range(16):
        await RisingEdge(dut.clk)

    hw_out = await read_matrix(dut)
    sw_out = matmul_ref(a, b)
    return hw_out, sw_out


def log_matrix(dut, title, mat):
    dut._log.info(f"--- {title} ---")
    for i, row in enumerate(mat):
        dut._log.info(f"Row {i}: {row}")


def diff_matrix(hw, sw):
    """Return list of (i, j, hw, sw) tuples where hw != sw."""
    return [
        (i, j, hw[i][j], sw[i][j])
        for i in range(len(sw))
        for j in range(len(sw))
        if hw[i][j] != sw[i][j]
    ]


# =========================================================
@cocotb.test()
async def Test_TPU(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    # Drive all DUT inputs to known values BEFORE reading any of them.
    # Start rst_n high, then pulse it low in hw_reset(). This guarantees
    # a 1->0 transition on the async reset, which some GL FF cells need
    # in order to fire (an X->0 transition is not always seen as a
    # negedge in iverilog GL).
    dut.rst_n.value  = 1
    dut.ena.value    = 1
    dut.ui_in.value  = 2     # cs=1 idle, sck=0, mosi=0
    dut.uio_in.value = 0

    # Let the initial assignments propagate.
    for _ in range(2):
        await RisingEdge(dut.clk)

    cocotb.log.info(f"Start Testing TPU (GL_TEST={GL_TEST})")

    failures = []

    async def test_and_log(name, A, B):
        hw_res, sw_res = await run_once(dut, A, B)

        log_matrix(dut, f"{name} | Matrix A", A)
        log_matrix(dut, f"{name} | Matrix B", B)
        log_matrix(dut, f"{name} | SW Result (A*B)", sw_res)
        log_matrix(dut, f"{name} | HW Result", hw_res)

        mism = diff_matrix(hw_res, sw_res)
        if mism:
            for i, j, h, s in mism:
                dut._log.error(f"{name}: C[{i}][{j}] hw={h} sw={s}")
            failures.append((name, mism))
        else:
            dut._log.info(f"{name}: PASS")

    I    = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
    tens = [[10, 10, 10], [10, 10, 10], [10, 10, 10]]

    await test_and_log("I*tens", I, tens)

    A = [[1, 2, 3], [5, 6, 7], [9, 10, 11]]
    B = [[2, 0, 0], [0, 3, 0], [0, 0, 4]]

    await test_and_log("A*I", A, I)
    await test_and_log("B*I", B, I)
    await test_and_log("A*B", A, B)

    A_pat = [[(i + j) % 2 for j in range(3)] for i in range(3)]
    B_pat = [[(i * j) % 2 for j in range(3)] for i in range(3)]
    await test_and_log("pat*pat", A_pat, B_pat)

    A_rows = [[5, 5, 5] for _ in range(3)]
    B_cols = [[1, 2, 3]] * 3
    await test_and_log("rows*cols", A_rows, B_cols)

    rng = random.Random(0xC0DE)
    for trial in range(3):
        Ar = [[rng.randint(0, 15) for _ in range(3)] for _ in range(3)]
        Br = [[rng.randint(0, 15) for _ in range(3)] for _ in range(3)]
        await test_and_log(f"rand-{trial}", Ar, Br)

    if failures:
        for name, mism in failures:
            dut._log.error(f"FAIL {name}: {len(mism)} mismatches")
        assert False, f"{len(failures)} test case(s) had mismatches"
