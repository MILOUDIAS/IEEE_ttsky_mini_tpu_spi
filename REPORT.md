# Mini TPU — Test-Suite Bring-Up Report

This report documents how the cocotb regression suite under `test/` was
brought from a fully broken state to **9/9 PASS in both RTL and Gate
Level (GL)** simulation, what hardware bugs were uncovered along the
way, and the rationale behind each fix.

---

## 1. Starting state

| Flow                              | Status   | First failure                                                                       |
|-----------------------------------|----------|-------------------------------------------------------------------------------------|
| `make` (RTL, icarus + cocotb)     | ❌ FAIL   | `ValueError: Can't convert LogicArray to int: it contains non-0/1 values` at startup |
| `GATES=yes make` (gate-level)     | ❌ FAIL   | Same Python crash; if patched, every test result was `XXXXXXXX`                      |

`test/test.py` had been reverted (commit `f0cede1 Revert back.. tp patch 3`)
to a state that:

- crashed at the *first line* of the test before any DUT activity;
- had **no assertions** — even after the crash was fixed, the test only
  printed HW vs SW and reported PASS regardless of mismatches;
- accessed internal SPI hierarchy (`dut.user_project.uut_tpu_interface
  .uut_spi.is_sending`, etc.) which works in RTL but is gone in a
  flattened gate-level netlist;
- loaded matrix `B` directly into `memory_b`, which (as we discovered)
  does not match the systolic dataflow.

The repo also lacked a strategy for staging and running a synthesized
netlist — the GL Makefile branch expected `test/gate_level_netlist.v`
to just be present.

---

## 2. Bug #1 — Test-startup `int(X)` crash

### Symptom

```
File ".../test.py", line 181, in Test_TPU
    dut.ui_in.value = int(dut.ui_in.value) | 2
                      ^^^^^^^^^^^^^^^^^^^^
ValueError: Can't convert LogicArray to int: it contains non-0/1 values
```

### Root cause

```python
dut.ena.value, dut.ui_in.value, dut.uio_in.value = 1, 0, 0
dut.ui_in.value = int(dut.ui_in.value) | 2
```

The first line **schedules** writes to the simulator; they don't take
effect until the next delta cycle. The very next statement reads
`dut.ui_in.value`, which is still `XXXXXXXX` (uninitialized `reg` in
`tb.v`), and `int()` rejects X bits.

### Fix

Drive the inputs to literal known values before reading any of them:

```python
dut.rst_n.value  = 1
dut.ena.value    = 1
dut.ui_in.value  = 2     # cs=1 idle, sck=0, mosi=0
dut.uio_in.value = 0
for _ in range(2):
    await RisingEdge(dut.clk)   # let assignments propagate
```

We also wrapped every subsequent read with a small helper
`_safe_int(val, default=0)` that catches X bits and returns 0 — useful
both in RTL (during early reset) and in GL (where unconnected outputs
can briefly be X).

---

## 3. Bug #2 — `data_ready` oscillates inside SPI (design bug)

### Symptom (after Bug #1 fix)

The test ran end-to-end but every test case returned **the same value
in every cell of the output matrix**:

```
I*tens : HW = [[14,14,14],[14,14,14],[14,14,14]]   SW = [[10,10,10],...]
A*I    : HW = [[ 3, 3, 3],...]                     SW = [[ 1, 2, 3],...]
B*I    : HW = [[ 6, 6, 6],...]                     SW = [[ 2, 0, 0],...]
```

The HW value matched `K * (a@b)[0][0] mod 16` for K ≈ 3, regardless of
the requested `(r,c)`.

### Root cause

`spi.v` originally drove `data_ready` like this:

```verilog
if (bit_counter == 0 && !data_ready) data_ready <= 1;
else                                  data_ready <= 0;
```

After a 12-bit instruction lands, `bit_counter` wraps to 0 and **stays
there** until the next instruction starts. The condition `bit_counter
== 0 && !data_ready` is therefore satisfied every other clock — so
`data_ready` toggles `0,1,0,1,…` forever.

Since `instruction = data_ready ? data_buffer : 0`, the control unit
sees the most-recent instruction *every other cycle*. Two consequences:

1. **RUN re-triggers continuously.** `is_run = (opcode==RUN || counter
   > 0)` keeps the counter walking 0→7→0→7… so the accumulator builds
   up `K × (A·B)` instead of `1 × (A·B)`. K=3 walks were observed.

2. **STORE result flickers.** `array_output_row`/`array_output_col`
   were combinational — set to the requested cell during the
   high-`data_ready` cycle and back to 0 during the low cycle — so
   `uo_out` alternated between `c_bus[r][c]` and `c_bus[0][0]`. With
   the test's 2-cycle wait before sampling, we always landed on the
   `c_bus[0][0]` half.

### Fix — `src/spi.v`

Edge-detect the `bit_counter` 11→0 transition so `data_ready` becomes
a single-cycle pulse per received instruction:

```verilog
reg [`BIT_COUNT-1:0] bit_counter_prev;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ...
        bit_counter_prev <= 0;
    end else begin
        bit_counter_prev <= bit_counter;
        if (bit_counter == 0 && bit_counter_prev == `INSTRUCTION_WIDTH-1)
            data_ready <= 1;
        else
            data_ready <= 0;
    end
end
```

`bit_counter` is updated on `posedge sclk`; `bit_counter_prev` snapshots
it on `posedge clk`. The two are equal everywhere except at the single
clock cycle right after `bit_counter` rolled from 11 back to 0 — which
is exactly the "instruction just landed" moment.

---

## 4. Bug #3 — `uo_out` valid only one cycle (design bug exposed by Bug #2 fix)

### Symptom

Once `data_ready` was a single pulse, the control-unit STORE path was
only valid for that one cycle and `uo_out` flapped back to `c_bus[0][0]`
afterwards.

### Fix — `src/control.v`

Latch the STORE row/col into real flip-flops on each STORE pulse:

```verilog
output reg  [1:0] array_output_row,
output reg  [1:0] array_output_col,
...
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        array_output_row <= 2'b00;
        array_output_col <= 2'b00;
    end else if (is_store) begin
        array_output_row <= row;
        array_output_col <= col;
    end
end
```

The result mux now keeps showing the most recently requested element
until the next STORE, so the test can sample it any time after the
2-cycle settle.

---

## 5. Bug #4 — B not transposed (test bug)

### Symptom

Even after Bugs #2 and #3 were fixed, results for non-symmetric `B`
were still wrong. For `A·I` the HW gave the dot product of row 0 of A
with row 0 of I — i.e. it was computing `A · Bᵀ`.

### Root cause

The 3×3 array's column `j` reads `memory_b` row-by-row over time, so
to feed the array `B[k][j]` at cycle `k+1` of column `j`, the contents
at `memory_b[r][c]` must be `B[c][r]`. The test was loading `B[r][c]`
directly.

### Fix — `test/test.py`

```python
# memory_b expects B transposed: column j of B flows down column j
# of the systolic array, so memory_b[r][c] must hold B[c][r].
for r in range(3):
    for c in range(3):
        await send_instr(dut, make_instr(OP_LOAD, 1, r, c, b[c][r] & 0xf))
```

After this, RTL was **9/9 PASS**.

---

## 6. Bringing up the gate-level flow

With librelane producing `runs/RUN_*/final/nl/tt_um_tpu.nl.v`, three
distinct GL-only issues remained.

### 6.1 — `VPWR`/`VGND` not on the netlist top

`test/tb.v` was passing `.VPWR(1'b1)` and `.VGND(1'b0)` to the DUT
under `\`ifdef GL_TEST`, but the librelane-generated `tt_um_tpu`
module exposes only the standard TT06 tile pins. iverilog refused
to elaborate.

**Fix:** removed those port connections. With `-DFUNCTIONAL` the
sky130 cell models do not need power pins for behavioural sim.

### 6.2 — `-DUSE_POWER_PINS` poisoned every cell output with X

After 6.1, every test reported `uo_out = XXXXXXXX`. The macro
`-DUSE_POWER_PINS` selected the `_FUNCTIONAL_PP` (power-pin-aware)
cell models. Those models read `VPWR`/`VGND`, but the netlist's cell
instantiations don't connect them — so each gate output went through
`pwrgood_pp$P/G` UDPs that returned X for unknown power.

**Fix — `test/Makefile`:** dropped `-DUSE_POWER_PINS` for the GL
branch and documented why. The non-power-pin functional models are
equivalent for behavioural verification.

### 6.3 — Pipeline regs in `pe.v` had no reset → X poisoning

After 6.2, the upper 4 bits of `uo_out` correctly read 0, but the
lower 4 (the actual datapath) were still X. Internal probes via
escaped hierarchical names showed:

```
PROBE: ma00=0001 mb00=XXXX c00=XXXX a_pe00=0000 b_pe00=0000 dbuf=...
```

`a_reg`/`b_reg` in every PE were stuck at the (correctly reset) 0 —
meaning `we` (i.e. `is_run`) was never firing — and `mem_b[0][0]` was
never written. We chased the timing-race below for that, but the
underlying X-propagation issue here was real:

`pe.v` deliberately used `dfxtp` (no-reset) flip-flops and relied on a
sim-only `initial` block to keep `a_reg`/`b_reg` at 0. That block is
dropped in synthesis, so the GL netlist powers up X. The first time a
PE is clocked with `we=1`, the multiply tree computes `X * 0 = X` (in
4-state Verilog `0 * X` keeps the X) and the X reaches `c_reg` instantly.

The original comment defended this with *"in silicon, inactive rows
have a_in == 0 and 0 × random_bits == 0"* — that reasoning is wrong
under standard 4-state `*` semantics.

**Fix — `src/pe.v`:**

```verilog
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        a_reg <= {`DATA_WIDTH{1'b0}};
        b_reg <= {`DATA_WIDTH{1'b0}};
    end else if (we) begin
        a_reg <= a_in;
        b_reg <= b_in;
    end
end
```

This requires re-synthesizing the netlist (the user re-ran
librelane after each design change).

### 6.4 — MOSI/SCK setup-time race in the testbench (GL only)

After 6.3 the GL probe showed something striking:

| Probe                 | Expected              | Actual                |
|-----------------------|-----------------------|-----------------------|
| `data_buffer` (LOAD B[2][2]=10) | `1010 0010 1010` (=0xA2A) | `0101 0101 0101` (=0x555) |
| `data_buffer` (RUN)             | `0100 0000 0000` (=0x400) | `1000 0000 0001` (=0x801) |

Each bit was *off by one position* — i.e. the SPI was sampling MOSI
**from the previous bit cycle** at every rising SCK.

The original `send_instr` set MOSI **and** raised SCK on the same
simulator step:

```python
dut.ui_in.value = (... & 0xf8) | bit | 4   # set MOSI and raise SCK together
await RisingEdge(dut.clk)
```

In RTL this works because `sclk = ui_in[2]` is a wire and `mosi =
ui_in[0]` is a wire — both transition simultaneously. In GL with
`-DUNIT_DELAY=#1` the buffer chains feeding `sclk` and `mosi` have
different gate counts, so the rising edge of `sclk` arrives before the
new `mosi` value, and the FF latches the **old** mosi.

**Fix — `test/test.py`:** settle MOSI on its own cycle, then raise SCK:

```python
for i in range(12):
    bit = (instr >> i) & 1
    # Phase 1: place MOSI with SCK still low so it can settle.
    dut.ui_in.value = (_safe_int(dut.ui_in.value) & 0xf8) | bit
    await RisingEdge(dut.clk)
    # Phase 2: raise SCK — MOSI is now stable.
    dut.ui_in.value = _safe_int(dut.ui_in.value) | 4
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    # Phase 3: drop SCK.
    dut.ui_in.value = _safe_int(dut.ui_in.value) & 0xfb
    await RisingEdge(dut.clk)
```

After this, GL was **9/9 PASS**.

---

## 7. A few smaller test/infra cleanups

- **rst\_n init.** The test now starts `rst_n = 1` and lets `hw_reset()`
  pulse it low. This guarantees a clean `1→0` negedge for async reset
  ports — iverilog GL is unreliable about firing `negedge` on `X→0`.
- **Real assertions.** `test_and_log` records mismatches into a
  `failures` list; at the end of the run, the test asserts `False`
  with a count if anything mismatched. Each test case still logs both
  matrices and the diff so failures are traceable from the log.
- **No internal hierarchy in production paths.** The committed test
  drives only DUT pins and reads only `uo_out`/`uio_out`, so it works
  identically under RTL and GL.
- **Test cases.** I × tens, A × I, B × I, A × B, parity-pattern
  matrices, all-fives × all-cols, plus 3 random pairs from a fixed
  PRNG seed (`random.Random(0xC0DE)`) for reproducibility.

---

## 8. Files touched

| File                          | Change                                                     |
|-------------------------------|------------------------------------------------------------|
| `src/spi.v`                   | Single-pulse `data_ready` via `bit_counter_prev` edge det. |
| `src/control.v`               | `array_output_row`/`array_output_col` latched on `is_store`|
| `src/pe.v`                    | Async reset for `a_reg`/`b_reg`                             |
| `test/test.py`                | Full rewrite: init, settle MOSI before SCK, transposed B, real assertions, GL-safe |
| `test/tb.v`                   | Dropped `VPWR`/`VGND` ports on the DUT instance            |
| `test/Makefile`               | Removed `-DUSE_POWER_PINS` for GL                          |
| `test/gate_level_netlist.v`   | Staged from `runs/RUN_*/final/nl/tt_um_tpu.nl.v`           |

---

## 9. How to run

### RTL

```sh
cd test
make
```

Expected: `TESTS=1 PASS=1 FAIL=0` and 9 `... : PASS` lines.

### Gate level

1. Re-run librelane against `src/` (after any design change). The
   Skywater PDK lives at
   `~/.ciel/ciel/sky130/versions/8afc8346a57fe1ab7934ba5a6056ea8b43078e71`.
2. Stage the netlist:
   ```sh
   cp runs/RUN_*/final/nl/tt_um_tpu.nl.v test/gate_level_netlist.v
   ```
3. Run:
   ```sh
   cd test
   PDK_ROOT=$HOME/.ciel/ciel/sky130/versions/8afc8346a57fe1ab7934ba5a6056ea8b43078e71 \
       GATES=yes make
   ```

Expected: same 9 PASS lines as RTL.

---

## 10. Final status

```
=== RTL ===
test.Test_TPU  PASS  TESTS=1 PASS=1 FAIL=0 SKIP=0

=== GL ===
test.Test_TPU  PASS  TESTS=1 PASS=1 FAIL=0 SKIP=0
```

Both flows green; the design is ready to submit.
