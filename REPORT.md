# Mini TPU — Bring-Up Report

This report walks through every problem we hit on the way from a
broken test suite to a clean GitHub-Actions submission, and the fix
applied for each. Three independent layers of failures had to be
peeled back: the cocotb tests, the gate-level simulation flow, and
the librelane PnR + LVS flow.

Final state, verified locally:

| Check                          | Status            |
|--------------------------------|-------------------|
| `make` (RTL cocotb test)       | 9/9 PASS          |
| `GATES=yes make` (GL cocotb)   | 9/9 PASS          |
| Librelane Antenna / DRC / LVS  | All clean (0 errors) |
| GitHub Actions `test.yaml`     | Passes (RTL only) |
| GitHub Actions `gds.yaml`      | Passes (synth + LVS + GL) |

---

## 1. Starting state

When this work began the cocotb test suite was completely broken:

- The very first line of `Test_TPU` crashed with
  `ValueError: Can't convert LogicArray to int`.
- Even with the crash patched, `test.py` had no assertions — it
  printed HW vs SW matrices and reported PASS regardless of value
  mismatches.
- The test reached into `dut.user_project.uut_tpu_interface.uut_spi.*`
  internal hierarchy, which works in RTL but is gone in a flattened
  gate-level netlist.
- Matrix `B` was loaded into `memory_b` in row-major order, but the
  systolic array dataflow needs it transposed.
- No full librelane PnR run had ever completed for this design —
  what looked like a "successful run" (`RUN_2026-05-09_12-58-11`)
  turned out to be **synth-only** (every PnR step skipped).

Each layer is covered below in roughly the order we hit it.

---

## 2. RTL test bring-up

### 2.1 — Crash at startup: `int(LogicArray) … contains non-0/1 values`

**Symptom.** First line of the test:
```python
dut.ena.value, dut.ui_in.value, dut.uio_in.value = 1, 0, 0
dut.ui_in.value = int(dut.ui_in.value) | 2     # ← crashes here
```

**Cause.** Cocotb writes to `signal.value` are non-blocking — they
queue and don't take effect until the next delta cycle. Reading
`dut.ui_in.value` on the very next statement still returned the
initial `XXXXXXXX` of the `tb.v` `reg`, and `int()` rejected the X
bits.

**Fix.** Drive every input to a literal known value before the first
read:
```python
dut.rst_n.value  = 1
dut.ena.value    = 1
dut.ui_in.value  = 2     # cs=1 idle, sck=0, mosi=0
dut.uio_in.value = 0
for _ in range(2):
    await RisingEdge(dut.clk)
```
Subsequent reads use a small `_safe_int(val, default=0)` helper that
catches X bits and falls back to 0 — useful both during early reset
in RTL and routinely in GL.

### 2.2 — SPI `data_ready` oscillates → RUN re-triggers, STORE flickers

**Symptom (after 2.1).** All matrix tests returned the same value in
every cell:
```
I*tens : HW = [[14,14,14],…]            SW = [[10,10,10],…]
A*I    : HW = [[ 3, 3, 3],…]            SW = [[ 1, 2, 3],…]
B*I    : HW = [[ 6, 6, 6],…]            SW = [[ 2, 0, 0],…]
```
The HW value matched `K × (a@b)[0][0] mod 16` for K ≈ 3, regardless
of the requested `(r,c)`.

**Cause.** `spi.v` originally drove `data_ready` like this:
```verilog
if (bit_counter == 0 && !data_ready) data_ready <= 1;
else                                  data_ready <= 0;
```
After a 12-bit instruction lands, `bit_counter` wraps back to 0 and
**stays there** until the next instruction starts. The condition
`bit_counter == 0 && !data_ready` is therefore satisfied every other
clock — so `data_ready` toggles `0,1,0,1,…` forever. Two
consequences:

1. **RUN re-triggers continuously.** With `is_run = (opcode == RUN ||
   counter > 0)`, every other cycle saw `opcode = RUN` again and the
   counter just kept walking. The accumulator built up
   `K × (A·B) mod 16` instead of `1 × (A·B)`. K=3 walks were
   observed in the failing logs.
2. **STORE result flickers.** `array_output_row/col` were
   combinational, so `uo_out` alternated between `c_bus[r][c]` (when
   `data_ready=1`) and `c_bus[0][0]` (when 0). The test's 2-cycle
   wait before sampling consistently landed on the `c_bus[0][0]` half.

**Fix — `src/spi.v`.** Edge-detect the `bit_counter` 11→0 transition
so `data_ready` is a single-cycle pulse per received instruction:
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

### 2.3 — `uo_out` valid for only one cycle (consequence of 2.2)

**Symptom.** With `data_ready` now pulsing for one cycle, the STORE
result mux was only valid that cycle — the test's 2-cycle settle
landed on the next cycle where `array_output_row/col` had reverted
to 0.

**Fix — `src/control.v`.** Latch the STORE row/col on each STORE
pulse so the result mux holds a stable value between SPI
transactions:
```verilog
output reg [1:0] array_output_row;
output reg [1:0] array_output_col;
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

### 2.4 — Matrix B was not transposed for the systolic dataflow

**Symptom.** Even after 2.2/2.3, non-symmetric `B` produced wrong
results — `A·I` gave the dot product of row 0 of A with row 0 of I
(i.e. it was computing `A · Bᵀ`).

**Cause.** Column `j` of the array reads `memory_b` row-by-row over
time. To feed `B[k][j]` at cycle `k+1` of array column `j`, the
contents at `memory_b[r][c]` must be `B[c][r]`. The test was loading
`B[r][c]` directly.

**Fix — `test/test.py`.**
```python
# memory_b expects B transposed: column j of B flows down column j
# of the systolic array, so memory_b[r][c] must hold B[c][r].
for r in range(3):
    for c in range(3):
        await send_instr(dut, make_instr(OP_LOAD, 1, r, c, b[c][r] & 0xf))
```

After this **RTL was 9/9 PASS**.

### 2.5 — Real assertions, GL-safe driving

Restructured `test.py`:

- Real `failures` list and `assert False` at the end if any test
  case mismatched — no more silent passes.
- All matrices logged so the diff is traceable.
- 9 test cases: identity, all-tens, two `A·I` shapes, parity
  patterns, all-fives × all-cols, plus 3 random pairs from a fixed
  PRNG seed (`random.Random(0xC0DE)`).
- No `dut.user_project.<internal>` paths in production paths — the
  test drives only DUT pins and reads only `uo_out`/`uio_out`, so it
  works identically in RTL and GL.

---

## 3. Gate-level (GL) test bring-up

### 3.1 — `tb.v`'s `VPWR`/`VGND` ports didn't match the netlist

**Symptom.** First GL elaboration:
```
tb.v:33: error: port "VPWR" is not a port of user_project.
tb.v:33: error: port "VGND" is not a port of user_project.
```

**Cause.** `tb.v` had hard-coded `\`ifdef GL_TEST .VPWR(VPWR), .VGND(VGND)`
on the DUT instance, but the synth at that point did not declare
power ports on `tt_um_tpu`.

**Fix — `test/tb.v`.** The wiring is gated on `\`ifdef GL_TEST` (and
the source `tt_um_tpu.v` carries the canonical TT
`\`ifdef USE_POWER_PINS inout VPWR/VGND` guards). The two flows are
now consistent — see §5.

### 3.2 — `-DUSE_POWER_PINS` poisoned every cell output with X

**Symptom (after 3.1).** Every test reported `uo_out = XXXXXXXX`.

**Cause.** `-DUSE_POWER_PINS` selected the `_FUNCTIONAL_PP`
power-pin-aware sky130 cell models. Those models route every output
through a `pwrgood_pp$P/G` UDP that returns X if `VPWR`/`VGND` are
not driven. Without the source/testbench wiring (which we hadn't yet
re-added), the cells saw X power and propagated X everywhere.

**Fix.** Detailed in §5: add the canonical `\`ifdef USE_POWER_PINS`
ports in `tt_um_tpu.v`, drive them in `tb.v`, and pass
`-DUSE_POWER_PINS` from the GL Makefile. The TT GDS workflow does
exactly this.

### 3.3 — PE pipeline regs (`a_reg`, `b_reg`) start X in GL

**Symptom (after 3.2).** Upper 4 bits of `uo_out` correctly read 0,
but the lower 4 (the actual datapath) were still X. Internal probes
via escaped hierarchical names showed:
```
PROBE: ma00=0001 mb00=XXXX c00=XXXX a_pe00=0000 b_pe00=0000 dbuf=…
```
The PE flip-flops `a_reg`/`b_reg` were stuck at 0 (correctly reset)
but the multiplier was producing X because of upstream-PE X
propagation (`X * 0 = X` in 4-state Verilog).

**Cause.** `pe.v` deliberately uses `dfxtp` (no-reset) cells for
`a_reg`/`b_reg` to save area, and relies on a sim-only `initial`
block to keep them at 0 in RTL. That `initial` is dropped in
synthesis, so the GL netlist powers up X. The first PE cycle
multiplies `X * 0` and the X reaches `c_reg` immediately. The
designer's defence in the comment ("inactive rows have a_in == 0
and 0 × random_bits == 0") is wrong under standard 4-state `*`
semantics.

**Fix considered: `pe.v` async reset on `a_reg`/`b_reg`.**
Functionally correct but upgrades 72 dfxtp cells to dfrtp
(≈ +600 µm² for the 3×3 array). On a 1×1 tile that area pressure
(combined with §4 below) caused PnR failures.

**Fix shipped — `test/test.py:gl_preheat()`.** A simulator-only
warm-up: load all-zero memory, send one RUN, wait for the array to
clock through, then `hw_reset` to clear the X-poisoned `c_reg`
accumulators. PE pipe regs aren't reset by `rst_n`, so the valid-0
state survives every later test.
```python
async def gl_preheat(dut):
    zeros = [[0]*3 for _ in range(3)]
    await load_matrices(dut, zeros, zeros)
    await send_instr(dut, make_instr(OP_RUN))
    for _ in range(16):
        await RisingEdge(dut.clk)
    await hw_reset(dut)
```
Called once in `Test_TPU` under `if GL_TEST:`. Keeps silicon area at
the original size (small dfxtp cells, sim-only `initial`) and adds
≈ 9 µs of sim time per gate-level test run. RTL is unaffected — it
already has the `initial` block.

### 3.4 — MOSI/SCK setup-time race in `send_instr` (GL only)

**Symptom (after 3.3).** Internal probes showed `data_buffer` content
*off by one bit*:

| Probe                | Expected            | Actual              |
|----------------------|---------------------|---------------------|
| LOAD B[2][2]=10      | `1010 0010 1010` (=0xA2A) | `0101 0101 0101` (=0x555) |
| RUN                  | `0100 0000 0000` (=0x400) | `1000 0000 0001` (=0x801) |

**Cause.** The original `send_instr` set MOSI **and** raised SCK on
the same simulator step:
```python
dut.ui_in.value = (... & 0xf8) | bit | 4   # set MOSI and raise SCK together
await RisingEdge(dut.clk)
```
In RTL `sclk = ui_in[2]` is a wire and both signals transition at
the same delta. In GL with `-DUNIT_DELAY=#1`, the buffer chains
feeding `sclk` and `mosi` have different gate counts, so the rising
SCK arrived before the new MOSI value, and the FF latched the
**previous** mosi.

**Fix — `test/test.py:send_instr()`.** Settle MOSI on its own clock
cycle, then raise SCK:
```python
for i in range(12):
    bit = (instr >> i) & 1
    # Phase 1: place MOSI with SCK still low.
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

After this **GL was 9/9 PASS**.

---

## 4. Librelane PnR

### 4.1 — `RUN_2026-05-09_12-58-11` was synth-only

A red herring that cost time: the `final/metrics.json` of that run
showed clean numbers (997 cells, 12 524 µm²) and a usable
`final/nl/tt_um_tpu.nl.v`. Reading `flow.log` later revealed
**every PnR step was skipped**:
```
Skipping step 'Floorplan Init'…
Skipping step 'Global Placement Skip IO'…
Skipping step 'I/O Placement'…
…
Skipping step 'Clock Tree Synthesis'…
```
12-58-11 only ran Yosys synth. No full librelane flow had ever
completed for this design — when we then ran the full flow it hit
new failures that hadn't been seen.

### 4.2 — DPL-0036: detailed placement failed at CTS

**Symptom.** The first full flow exit:
```
[GPL-0302] Target density 0.7000 is too low for the available free area.
[GPL-1015] High uniform density (>0.97) may cause congestion or legalization issues.
[DPL-0036] Detailed placement failed.   ← stage 35 (CTS legalisation)
```
After CTS added 64 clock buffers and 54 timing-repair buffers, total
post-CTS area was 14 741 µm² in a 15 484 µm² core — 95 % density —
and the legalizer couldn't slot the 35 instances DPL-0034 listed.

We chased the wrong direction first. `[GPL-0302] "too low"` reads
like a request to *raise* the target, but the underlying issue is
geometry: cells take more area than the floorplan can absorb after
CTS adds buffers. Density tuning didn't help.

**Fix — `config.yaml: DIE_AREA: [0, 0, 167, 108]`.** The
`info.yaml` already documents the canonical TT 1×1 size — *"a single
tile is about 167×108 µM"* — but the local `config.yaml` was set to
a smaller `[0, 0, 160, 100]` floorplan (15.5 k µm² of core).
Bumping to 167×108 gives 17.7 k µm² of core. Post-CTS density drops
to ≈ 83 %, the legalizer has comfortable margin, DPL passes.

The IEEE workshop constraint is "1×1 tile" (count) and 167×108 *is*
the canonical TT 1×1 — no exception requested.

### 4.3 — LVS: 24 → 17 errors from constant-tied output pins

**Symptom (after 4.2).** Antenna ✅, DRC ✅, **LVS ✘** with 24
errors. Magic's spice extraction log:
```
Warning: Ports "uo_out[7]" and "uo_out[3]" are electrically shorted.
Warning: Ports "uo_out[7]" and "uio_oe[7]" are electrically shorted.
Warning: Ports "uo_out[7]" and "VGND" are electrically shorted.
…
```
The extracted layout's `tt_um_tpu` subckt was missing several output
ports entirely:
```
.subckt tt_um_tpu VGND VPWR clk ena rst_n …
+ uio_oe[0..6]                              ← uio_oe[7] missing
+ uio_out[0..7]
+ uo_out[0,1,2,4,5,6]                       ← uo_out[3] and [7] missing
```

**Cause.** The constant-tied output assigns:
```verilog
assign uio_oe[7:1]  = 0;   // tt_um_tpu.v
assign uio_out[7:1] = 0;   // tt_um_tpu.v
result[7:4]         = 0;   // tpu.v: result = { 4'b0, selected }
```
all synthesise into `sky130_fd_sc_hd__conb_1` cells whose `LO`
output is internally pulled down to `VGND`. Magic's spice extraction
follows that pulldown path, decides every constant-tied pin is
electrically VGND, and merges all of them into one giant net. After
the merge, several output ports vanish from the extracted subckt,
and Netgen's pin-list comparison cannot recover.

**Two intermediate attempts that didn't fix it:**
- Bumping `IO_PIN_H_LENGTH/V_LENGTH` from 2 to 4 µm helped
  marginally (24 → 17 errors) — longer pin stubs gave each
  constant-tied output its own metal segment, but the conb→VGND
  merge still happened during extraction.
- `MAGIC_DEF_LABELS: true` had no effect — even with DEF labels the
  conb→VGND collapse happens before Magic gets to label nets.

**Fix shipped — `(* keep *)` flip-flops, `src/tt_um_tpu.v` and
`src/tpu.v`.** Force a real flip-flop driver on every constant-tied
output:
```verilog
(* keep = "true" *) reg [6:0] uio_oe_high_q;
(* keep = "true" *) reg [6:0] uio_out_high_q;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        uio_oe_high_q  <= 7'b0;
        uio_out_high_q <= 7'b0;
    end else begin
        uio_oe_high_q  <= 7'b0;
        uio_out_high_q <= 7'b0;
    end
end
assign uio_oe[7:1]  = uio_oe_high_q;
assign uio_out[7:1] = uio_out_high_q;
```
The `(* keep = "true" *)` attribute blocks yosys's
constant-propagation pass from collapsing the registers into
`conb_1` cells. The synthesised netlist has real `dfrtp` flip-flops
driving each pin. Magic extracts each port as a distinct cell-driven
net, and LVS matches.

The same pattern is applied to `result[7:4]` in `tpu.v`. Total
silicon cost: ≈ 18 extra dfrtp flip-flops (≈ 400 µm²), absorbed
comfortably by the new 167×108 floorplan.

After this **librelane went LVS-clean** —
`design__lvs_error__count: 0`, `design__lvs_unmatched_pin__count: 0`,
`design__lvs_unmatched_net__count: 0`.

---

## 5. Aligning local librelane with CI's `gl_test`

The `gds.yaml` workflow uses `TinyTapeout/tt-gds-action@tt10`. Its
`gl_test` step:

1. Synthesises with `USE_POWER_PINS` defined → top has `inout
   VPWR/VGND`, every filler/decap cell carries
   `.VPWR(...)`/`.VGND(...)`/`.VNB(...)`/`.VPB(...)` connections.
2. Runs cocotb against that netlist via **our** `test/Makefile` and
   `test/tb.v`.

For the same testbench to elaborate against both flows, the local
flow must produce a netlist of the same shape. The decisive failure
mode was:
```
test/gate_level_netlist.v: error: port "VPWR" is not a port of FILLER_38_249.
… 8302 errors …
```
which is the iverilog elaboration crashing because the netlist's
filler cells have `.VPWR(...)` connections but the loaded sky130
cell models don't declare those ports — they only do under
`-DUSE_POWER_PINS`.

The fix is consistency in three places:

**`config.yaml`:**
```yaml
VERILOG_DEFINES:
  - USE_POWER_PINS
```
so local synth produces the same powered netlist as TT's flow.

**`test/Makefile`** (GL branch):
```make
COMPILE_ARGS    += -DUSE_POWER_PINS
```
so the loaded sky130 cell models declare matching power ports.

**`test/tb.v`:**
```verilog
`ifdef GL_TEST
  wire VPWR = 1'b1;
  wire VGND = 1'b0;
`endif

tt_um_tpu user_project (
`ifdef GL_TEST
    .VPWR(VPWR),
    .VGND(VGND),
`endif
    ...
);
```

**Important detail — stage `pnl/`, not `nl/`.** The librelane flow
emits two netlists in `runs/RUN_*/final/`:
- `nl/tt_um_tpu.nl.v` — synthesised netlist *without* power-pin
  connections.
- `pnl/tt_um_tpu.pnl.v` — **powered** netlist with `VPWR/VGND` on
  the top module and `.VPWR/.VGND/.VNB/.VPB` connections on every
  filler/decap instance.

GL must use `pnl/`. `scripts/run-gl-test.sh` does this automatically.

---

## 6. Final state

Local librelane `RUN_2026-05-09_23-02-22` `final/metrics.json`:

```
design__instance__count       : 2232 (incl. fillers/buffers)
design__instance__utilization : 85.6 %
design__violations            : 0
magic__drc_error__count       : 0
klayout__drc_error__count     : 0
design__lvs_error__count      : 0
design__lvs_unmatched_pin__count : 0
design__lvs_unmatched_net__count : 0
```

Local GL sim against the powered netlist (`scripts/run-gl-test.sh
--skip-synth`):
```
I*tens   : PASS
A*I      : PASS
B*I      : PASS
A*B      : PASS
pat*pat  : PASS
rows*cols: PASS
rand-0   : PASS
rand-1   : PASS
rand-2   : PASS
TESTS=1 PASS=1 FAIL=0
```

GitHub Actions:
- `test.yaml` (RTL only, no power pins) → green.
- `gds.yaml` synth + LVS + `gl_test` → green.

---

## 7. Files touched

| File                          | Change                                                     |
|-------------------------------|------------------------------------------------------------|
| `src/spi.v`                   | Single-pulse `data_ready` via `bit_counter_prev` edge detect (§2.2). |
| `src/control.v`               | `array_output_row`/`array_output_col` latched on `is_store` (§2.3). |
| `src/pe.v`                    | Unchanged — small dfxtp cells, sim-only `initial` block. GL X-mitigation lives in `test.py:gl_preheat()` instead (§3.3). |
| `src/tt_um_tpu.v`             | Standard TT `\`ifdef USE_POWER_PINS inout VPWR/VGND` guards (§5); `(* keep *)` flip-flops drive `uio_oe[7:1]` and `uio_out[7:1]` to avoid `conb_1.LO`→VGND collapse during magic extraction (§4.3). |
| `src/tpu.v`                   | `(* keep *)` flip-flop drives `result[7:4]` for the same LVS reason (§4.3). |
| `src/config.json`             | Unchanged. |
| `config.yaml`                 | `DIE_AREA` → 167×108 µm to give CTS room (§4.2); `IO_PIN_H_LENGTH`/`V_LENGTH` 2 → 4 µm; `VERILOG_DEFINES: [USE_POWER_PINS]` so the synthesised netlist matches TT's flow (§5); `FP_CORE_UTIL: 45`, `PL_TARGET_DENSITY_PCT: 75`. |
| `test/test.py`                | Full rewrite: proper init, settle MOSI before SCK (§3.4), transposed B (§2.4), real assertions (§2.5), `gl_preheat()` for GL X-mitigation (§3.3). |
| `test/tb.v`                   | Drives `VPWR=1, VGND=0` under `\`ifdef GL_TEST` (§5). |
| `test/Makefile`               | `-DUSE_POWER_PINS` enabled for GL (§5). |
| `test/gate_level_netlist.v`   | Staged from `runs/RUN_*/final/pnl/tt_um_tpu.pnl.v` (powered). |
| `scripts/run-gl-test.sh`      | New wrapper: librelane synth → stage powered netlist → `GATES=yes make`. Mimics CI's `gl_test`. |
| `REPORT.md`                   | This file. |

---

## 8. How to run

### RTL
```sh
cd test
make
```
Expected: `TESTS=1 PASS=1 FAIL=0`, 9 `… : PASS` lines.

### Gate level — locally, mimicking CI's `gl_test`
```sh
bash scripts/run-gl-test.sh
```
Expected: librelane completes the full flow (DRC ✅, LVS ✅), then 9
`… : PASS` lines from cocotb.

`--skip-synth` reuses the most-recent `runs/RUN_*` instead of
re-running librelane (useful when iterating on `test/test.py`).

The equivalent commands without the script:
```sh
librelane @config.yaml
cp runs/RUN_*/final/pnl/tt_um_tpu.pnl.v test/gate_level_netlist.v
cd test
PDK_ROOT=$HOME/.ciel/ciel/sky130/versions/8afc8346a57fe1ab7934ba5a6056ea8b43078e71 \
    GATES=yes make
```

### CI

`test.yaml` runs the RTL test on every push. `gds.yaml` runs
TT's `tt-gds-action@tt10` which performs synth + PnR + LVS + DRC and
then `gl_test`. Both are green with the changes in this report.
