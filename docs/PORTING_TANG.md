# Porting the GameTank core to the Tang Mega 138K Pro

Feasibility study (2026-08-23) for retargeting this core from the MiSTer
(DE10-Nano, Cyclone V + HPS) to the Sipeed Tang Mega 138K Pro Dock
(Gowin GW5AST-138, no HPS).

**Status: T0, T1, T2 done; T3 in progress (2026-08-23/24).** The core synthesizes
clean under GowinSynthesis; GRAM stays in DDR3; and the video top in `tang/`
places, routes and generates a bitstream with zero setup/hold violations.
Nothing has run on real hardware yet. Everything from T3 onward is still
analysis: read out of this repo or cited from a vendor document.

Scope decisions for the MiSTer core itself remain in
[REQUIREMENTS.md](REQUIREMENTS.md); this document does not change them.

## Verdict

**Feasible.** The console RTL ports close to verbatim; the work is almost
entirely *front-end* — replacing MiSTer's `sys/` (HPS, `hps_io`, OSD, ascal,
HDMI, audio) with Tang equivalents. Resources are not the constraint.
Estimated effort: 2–4 weeks for someone comfortable with Gowin EDA, with the
Verilator suite guarding the console the whole way.

Three things make this cheap:

1. [rtl/gametank.sv](../rtl/gametank.sv) is already framework-agnostic by
   contract — its header states it "must never reference `sys/` or
   Quartus-only IP". Everything MiSTer-specific lives in one 250-line
   wrapper, [GameTank.sv](../GameTank.sv).
2. The DDR3 dependency is funnelled through a single small arbiter,
   [rtl/ddr_mux.sv](../rtl/ddr_mux.sv), speaking one documented protocol.
3. The test suite never instantiates `sys/` — [sim/Makefile](../sim/Makefile)
   drives `rtl/gametank.sv` directly from C++, playing the ioctl/SD/DDR roles.
   **The entire suite (13 unit + 18 integration tests, plus the opt-in
   system tier) survives the port unchanged.** This is the single biggest
   de-risking factor.

## Target board facts

| | |
|---|---|
| FPGA | GW5AST-LV138FPG676A (Arora V) — 138,240 LUT4, 138,240 FF, **6,120 Kb BSRAM** (340 blocks), 1,080 Kb SSRAM, 298 DSP |
| DRAM | 1 GB DDR3 (512 MB × 2) on the SoM |
| Storage | SD card slot; 128 Mbit × 2 config flash |
| Display | DVI TX × 2 (shared with DVI RX × 2) |
| Audio | 3.5 mm jack + speaker header — **codec not documented, check schematic** |
| Input | 40-pin header, 3 × PMOD; **no onboard USB-host MCU** (unlike Tang Console / Nano 20K's BL616) |
| Extras | hardened RISC-V AE350 SoC, PCIe 3.0 ×4, 2 × SFP+, GbE |
| Toolchain | Gowin EDA ≥ 1.9.9, **commercial (not Education) license required** for GW5AST-138; Sipeed run an online license service. Installed here: 1.9.12.03 at `D:\Gowin`, GW5AST-138B/C device data present, floating license at `106.55.34.119:10559` (see T0) |

Sources at the end of this document.

## Port surface

The core's entire outside world is five signal groups on
[rtl/gametank.sv:15](../rtl/gametank.sv:15). A Tang front-end must supply all
five; nothing else about the console is negotiable.

| Boundary | MiSTer provider | Tang replacement | Risk |
|---|---|---|---|
| `cart_addr` / `cart_data` | `bootcart` BRAM + `$readmemh` in the wrapper | same, verify Gowin honors `$readmemh` BSRAM init | low |
| `dl_active/dl_wr/dl_addr/dl_data/dl_busy/dl_wait` | `hps_io` ioctl | SD FAT reader streaming `.gtr` bytes | medium |
| `sd_lba/sd_rd/sd_wr/sd_buff_*/img_*` | `hps_io` SD block interface | 512-byte block read **and write** to a save file ([rtl/savectl.sv:32](../rtl/savectl.sv:32)) | medium |
| `ddr_*` (64-bit burst, Avalon-ish) | `sys/` HPS f2h bridge | Gowin DDR3 IP + CDC shim | medium |
| `ce_pix/hsync/vsync/hblank/vblank/video_*`, `audio_l/r`, `joy1/joy2` | ascal → HDMI, MiSTer audio, `hps_io` joysticks | line-doubler → TMDS TX; HDMI audio or jack; pad source TBD | medium/high |

### The one Quartus-locked file in `rtl/`

[rtl/acp.sv:187](../rtl/acp.sv:187) instantiates `altsyncram` directly for the
4 KB true-dual-port ACP RAM, behind an `ifdef VERILATOR` that keeps a
behavioral model for simulation. The header records *why* (Quartus 17 refused
to map any behaviorally-correct TDP description to M10K) and exactly which
semantic differs (same-edge read-during-write, which the strobe-latched bus
never consumes). On Gowin: either re-test plain inference, or instantiate
`DPB` / generate the IP — ~40 lines, and the behavioral model is the spec.

Everything else in `rtl/` is portable SystemVerilog. `rtl/pll.v`, `rtl/pll.qip`
and `rtl/pll/` are Quartus-generated and get replaced wholesale by a Gowin
rPLL/PLLA producing 28.636364 MHz.

## Resource budget

Reference point: the current MiSTer build fits a 5CSEBA6 (~42k ALM, 5,662 Kb
M10K) at **23% logic / 25% BRAM** including all of `sys/`
([DEVELOPMENT_PLAN.md:87](DEVELOPMENT_PLAN.md:87)).

Console-only BRAM, counted from the RTL:

| Block | Source | Kb |
|---|---|---|
| System RAM 32 KB | [mainbus.sv:116](../rtl/mainbus.sv:116) | 256 |
| VRAM, 2 × 128×128 pages | [vram.sv:29](../rtl/vram.sv:29) | 256 |
| Display snapshot 16 KB | [frame_snapshot.sv:33](../rtl/frame_snapshot.sv:33) | 128 |
| Cart fixed bank 16 KB | [cart.sv:130](../rtl/cart.sv:130) | 128 |
| Cart cache 16 KB + tags | [cart.sv:143](../rtl/cart.sv:143) | 146 |
| ACP RAM 4 KB | [acp.sv:173](../rtl/acp.sv:173) | 32 |
| GRAM row buffers + caches | [gram_ddr.sv:110](../rtl/gram_ddr.sv:110) | ~5 |
| Boot cart 32 KB | [GameTank.sv:177](../GameTank.sv:177) | 256 |
| **Total** | | **~1,207 Kb (~20% of BSRAM)** |

**Measured** (GowinSynthesis 1.9.12.03, `top_module gametank`, 2026-08-23 —
see T0): **63 / 340 BSRAM (19%)**, 5,274 LUT4+ALU (4%), 2,123 registers (2%).
The estimate above predicted ~20% BSRAM, so the table is sound. Logic is a
non-issue; 28.636 MHz is trivial for this part, and the TMDS serializers
(5× pixel clock, ~143 MHz) are what `OSER10` exists for.

Note: Gowin counts BSRAM in 18 Kb units (340 × 18 Kb = 6,120 Kb), and a
byte-wide port uses 16 of each 18 bits — so byte RAMs cost ~12% more units
than a bit count suggests.

### Resolved: GRAM stays in external memory

Putting the 512 KB GRAM in BSRAM was tempting — it would delete
[rtl/gram_ddr.sv](../rtl/gram_ddr.sv) (382 lines of prefetcher) *and* the
timing deviations it documents; `blit_starve` and `gram_stall` would
disappear and the blitter would go back to real hardware behavior. That is a
fidelity win, not just a simplification.

**It does not fit.** A 512 KB true-dual-port byte RAM (blitter read port +
CPU window read/write port) synthesized standalone infers **256 DPB blocks =
76% of the device's 340**, because a byte-wide port wastes 2 of every 18
bits. With the core's measured 63, that is 319 / 340 = **94%**, leaving 21
units for the whole front-end — and a soft-CPU front-end alone wants ~35 for
firmware RAM. Widening the RAM does not help: the 16-of-18-bit ratio holds at
any width the blitter can use.

This matches the M4 Quartus experience recorded at
[DEVELOPMENT_PLAN.md:83](DEVELOPMENT_PLAN.md:83) (9.7 Mbit demanded). So
`gram_ddr.sv` survives the port unchanged, and an external memory (T3) is on
the critical path — as it would have been anyway for the 2 MB cart image
([cart.sv:41](../rtl/cart.sv:41)).

## Work items

Sequenced so that each step is independently verifiable and the riskiest
unknown (the toolchain) is answered on day one.

### T0 — Toolchain gate ✅ (2026-08-23)

- **License.** `gw_sh` will not start without one ("License verification
  failed"); GW5AST-138 is outside the free Education edition. The floating
  server goes in `IDE/bin/gwlicense.ini` as `lic="<ip>:<port>"` — note the
  **`ip:port`** form; the FlexLM-style `port@ip` is rejected, as are the
  `GOWIN_LICENSE_FILE` / `LM_LICENSE_FILE` environment variables.
- **Result: GowinSynthesis compiled all 16 core RTL files with zero errors
  and no SystemVerilog rewrites** (`set_option -verilog_std sysv2017`,
  `top_module gametank`; `clk_sys` is a plain input, so the core synthesizes
  without a PLL). `always_ff`, `always_comb`, `typedef enum`, `unique case`,
  packed/unpacked arrays and `for` loops in `always_ff` all went through.
  **K1 is closed** for synthesis; PnR is still unproven.
- **Every memory inferred to BSRAM**, including the behavioral true-dual-port
  ACP RAM at [acp.sv:173](../rtl/acp.sv:173) that Quartus refused to map —
  so Gowin likely needs **no** `altsyncram` counterpart at all; the existing
  `ifdef` can simply select the behavioral branch. Confirm the
  read-during-write semantics against the header's argument before relying
  on it.
- The `via6522` instance is swept away, as expected: `via_q`/`via_irq` are
  deliberately dead ([gametank.sv:215](../rtl/gametank.sv:215) — reads and
  the cart SPI come from the write-shadow), so the VIA costs nothing here.
  One warning worth a look: `via_shadow_q[7] does not have a driver`.
- **Still open in T0:** PnR (needs a real top, `.cst` pin constraints and an
  `.sdc`), the Gowin rPLL/PLLA at 28.636364 MHz, and `$readmemh` BSRAM init
  (K3).

### T1 — GRAM decision ✅ (2026-08-23)

- **Answered: keep DDR3.** 256 / 340 BSRAM for GRAM alone — see
  "Resolved: GRAM stays in DDR3" above. `gram_ddr.sv` is not going away, so
  T3 is the next real milestone.

### T2 — Video out ✅ (2026-08-24)

Built in `tang/`, driven by `tools/gametank-build-tang`:

| File | Role |
|---|---|
| `gametank_tang.sv` | board top — PLL, boot cart, core, video chain, LEDs |
| `pll_tang.v` | Gowin `PLL` primitive: 50 MHz → clk_sys + 5x TMDS serial |
| `linedouble.sv` | 908x262 @ ce_pix → 908x524 @ clk_sys |
| `tmds_encoder.sv` | DVI 1.0 §3.2.2 8b/10b encoder (pure RTL) |
| `dvi_tx.sv` | 3 data lanes + clock lane: `OSER10` + `TLVDS_OBUF` |
| `ddr_bram.sv` | 64 KB stand-in speaking the DDRAM protocol (T3 replaces) |
| `gametank_tang.cst` / `.sdc` | dock pins (DVI TX port 0) and clocks |

The doubler stores the input's own hsync/hblank per dot and replays them,
so no timing constant is duplicated from `rtl/gtvideo.sv`.

**Measured** (GW5AST-138B, PnR complete, bitstream generated):

| Resource | Usage |
|---|---|
| Logic | 5,346 / 138,240 (4%) |
| Registers | 2,158 / 139,140 (2%) |
| BSRAM | 117 / 340 (35%) — core 63, boot cart 18 as pROM, DDR stub, line buffer |
| I/O | 15 / 312, 1 PLL, 3 primary clocks |
| Fmax (clk_sys) | **54.18 MHz** against the 28.65 MHz constraint |
| Setup / hold violations | **0 / 0** |

Four findings, all folded into the tree:

1. **The exact console clock is unreachable from this board.** 28.636364 MHz
   is 50 × 63/110, and that 11 would need IDIV = 11 → Fpfd 4.5 MHz, under the
   PLL's 19 MHz floor (PnR: PA2078). The closest legal setting is **+331 ppm**
   (IDIV 2, FBDIV 1, MDIV 34+3/8, ODIV0 6, ODIV1 30 — Fvco 859.375 MHz), i.e.
   60.21 Hz instead of 60.19 and audio 0.03% sharp. Best integer-only setting
   is −2268 ppm, kept in `tang/pll_tang.v` as the fallback if fractional-N
   jitter ever bothers a receiver. For comparison, Sipeed's own 720p reference
   clock is −337 ppm off.
2. **Gowin BSRAM has no read-before-write mode** (PnR: PA2122), which is
   exactly what `mem[a] <= d; q <= mem[a];` describes — the shape used by
   `vram.sv`, `mainbus.sv` and `acp.sv`. A probe pinned the mapping down:

   | Description | WRITE_MODE |
   |---|---|
   | `if (we) m[a]<=d; q<=m[a];` | `2'b10` — **rejected** |
   | `if (we) begin m[a]<=d; q<=d; end else q<=m[a];` | `2'b01` write-through |
   | `if (we) m[a]<=d; else q<=m[a];` | `2'b00` no-change |

   `vram.sv` and `acp.sv` now carry write-through variants behind `` `GOWIN ``,
   `mainbus.sv` a no-change variant; `frame_snapshot.sv` just needed its read
   split into its own `always_ff`. The difference is only what a port reads on
   a cycle that writes the same address, which no consumer here uses — the
   argument `rtl/acp.sv` already makes for its altsyncram NEW_DATA mapping.
3. **Forward-declared signals silently become 1-bit nets.** `rtl/gametank.sv`
   declared `g_addr` and friends *after* the instantiation that used them;
   GowinSynthesis creates an implicit wire and then complains the real
   declaration is a redeclaration (EX3638) — a silent bus truncation waiting
   to happen. Those declarations moved above first use.
4. **`$readmemh` BSRAM init works** — the 32 KB boot cart lands as 18 pROM
   blocks. **K3 closed.**

Two smaller mechanics worth knowing: GowinSynthesis has no
`set_option -verilog_define`, so macros come from `tang/gowin_defines.v`
compiled first; and the OSER10 `RESET` pin is in the serial clock domain, so
`dvi_tx.sv` retimes the console reset into it, with the crossing declared a
false path in the `.sdc`.

**Not done:** nothing has been on hardware. Two open items —
`tools/gametank-build-tang --program` is untested, and STA still reports four
minimum-pulse-width artifacts on the reset synchronizer's own flops (setup
and hold are clean; the reported "actual width" is negative, which is a
modelling artifact rather than a physical pulse).

### T3 — External memory: SDRAM, not DDR3 🚧

**Decision (2026-08-24): a 16-bit SDRAM module on the 40-pin header, not the
board's DDR3.** Capacity and bandwidth are non-issues either way — the console
needs 2.5 MB and under 10 MB/s, and both options are 30x+ over. Latency is the
axis that differs, and it is the one this project cares about:

| | Onboard DDR3 | 16-bit SDRAM |
|---|---|---|
| Read latency | ~200-400 ns (IP pipeline + CDC + bank management) | ~100-200 ns |
| Fits in one 6502 cycle (279 ns)? | no — stalls stay | yes |
| Controller | vendor IP, encrypted netlist, DQS calibration, own PLL | ~330 lines of ours, simulatable |
| Clock domains | user clock fixed by the memory clock → async bridge | 3x clk_sys off the same PLL → no CDC |
| Provenance | vendoring a Gowin IP netlist into a GPL repo is murky | entirely ours |
| Hardware | already on the board | extra module (~$10) |

The deciding argument is that SDRAM is the only option that can *remove*
documented deviations rather than institutionalize them: `cart_stall` and
`blit_starve` exist because HPS DDR3 could not answer inside a 6502 cycle.

**Written so far** — [tang/sdram.sv](../tang/sdram.sv) (controller),
[tang/sdram_io.sv](../tang/sdram_io.sv) (pad layer), wired into the top behind
`` `TANG_SDRAM ``, with [tang/sdram.sdc](../tang/sdram.sdc) and a third PLL
output at 85.9375 MHz (ODIV2 = 10, exactly 3x clk_sys).

Design notes:

- **Drop-in, deliberately.** It speaks the same DDRAM protocol behind
  [rtl/ddr_mux.sv](../rtl/ddr_mux.sv), so the prefetcher and cart cache stay
  exactly as they are and all 18 integration tests stay valid. Simplifying
  `gram_ddr.sv` away is a *later* decision, to be taken only once this is green
  on hardware — those modules absorbed the entire M8/M9 compatibility campaign.
- **No CDC.** clk_sdram is 3x clk_sys off one PLL, so the handshake is
  synchronous multi-rate and STA times it (~11.6 ns). The `.sdc` keeps both
  clocks in one group; splitting them into asynchronous groups would silently
  un-time those paths.
- **Open-row policy**, closed only on a row change or refresh, so a blitter
  streaming one GRAM row pays CL + burst per beat and nothing more. A burst
  crossing a row boundary re-activates through the same path — no special case.
- **Writes are single-beat**, which is what all three clients issue.

**Testing.** [sim/unit/test_sdram.cpp](../sim/unit/test_sdram.cpp) drives the
controller against a behavioural chip model
([sim/common/sdram_harness.h](../sim/common/sdram_harness.h)) that enforces the
protocol as well as the data: activate before access, tRCD/tRP, no precharge
into a live burst, refresh cadence, mode-register contents. It covers single
beats, 8-beat bursts, byte enables, a burst crossing a row boundary, other
rows and banks, and the busy/dout_ready contract the clients rely on.

The read-capture alignment is the delicate part and is now derived rather than
guessed: a READ driven out of edge N is sampled by the chip at N+1, so with
CL=2 its words are latchable at N+3..N+6, which is `RD_EXTRA = 0`. Hardware may
still need 1 once flight time is real — that and the ODDR clock polarity are
the bring-up knobs.

**Pinout** came from `tang/mega.cst`, a board constraint file supplied for
this project; [tang/sdram.cst](../tang/sdram.cst) is generated from it by
renaming signals to our ports, so no pin number was transcribed by hand. Two
caveats live in that file's header and are worth repeating:

- `tang/mega.cst` calls itself **"CST for Console 60K/138K"** — the Tang
  Console, not the Mega 138K Pro Dock. Every signal the two share does match
  Sipeed's dock reference (clock P16, button K16, the five LEDs, all four TMDS
  pairs), and the file's own commented-out lines put the SDRAM on PMOD1, which
  is good evidence the carriers assign the SoM identically. It is evidence,
  not proof — confirm against the dock schematic before powering a module up.
- There is **no SDRAM CKE pin** in it, so the board ties clock-enable high.
  The controller still drives `sd_cke`; the top leaves it unconnected.

**The SDRAM variant now builds end to end** (`gw_sh tang/syn.tcl sdram`):

| Resource | With SDRAM | With the BRAM stand-in |
|---|---|---|
| Logic | 6,047 (5%) | 5,360 (4%) |
| Registers | 3,049 (3%) | 2,285 (2%) |
| BSRAM | 85 / 340 (25%) | 117 / 340 (35%) |
| I/O | 53 / 312 (17%) | 15 / 312 (5%) |

BSRAM *drops* because the 64 KB stand-in is gone. Fmax: clk_sys 47.5 MHz
against 28.65 needed, **clk_sdram 100.3 MHz against 85.94 needed** (17%
margin), clk_serial comfortably clear. Zero setup and zero hold violations on
both variants.

**Not done:** the Verilator test has never been executed — there is no
Verilator on the machine doing the port — and nothing has run on hardware.
When a module is attached, mind that the Sipeed part is **not** pin-compatible
with a MiSTer SDRAM v3.0 board (pins 29/30 differ), and that it carries two
16-bit chips where this controller drives one.

### T4 — Front-end: SD, OSD, saves

The biggest item, and the one to borrow rather than write. `hps_io` provides
file picking, the `status[]` config string, ioctl download, SD block save
slots and joystick decode; none of that exists on a Tang.

- **Recommended:** adopt nand2mario's `iosys` (PicoRV32 + firmware, ~2K LUT)
  from SNESTang — it already implements FAT, an OSD menu, ROM loading and
  BSRAM backup/restore, and SNESTang explicitly supports this board.
  harbaum's MiSTeryNano framework is the alternative.
- Must cover: `.gtr` load (up to 2 MB), the `status[]` bits the wrapper uses
  (reset, Load/Save Backup RAM, autosave, aspect ratio —
  [GameTank.sv:63](../GameTank.sv:63)), and **FAT write** for saves. Save
  support is not optional if M9.1 parity matters: `savectl.sv` streams the
  modified 2 MB image out in 512-byte blocks.
- Budget BSRAM for the soft CPU's firmware RAM here (SNESTang's firmware is
  ~70 KB) — this is the item that competes with a BSRAM-resident GRAM (T1).
- **Done when:** a `.gtr` loads from SD through the OSD and a flash save
  round-trips, matching `test_flash_save_roundtrip`.

### T5 — Audio and input

- Audio: the ACP emits an 8-bit unsigned DAC level on both channels
  ([gametank.sv:103](../rtl/gametank.sv:103)). Easiest path is HDMI audio
  packets; the 3.5 mm jack needs the board schematic checked first.
- Input: **the weakest spot on this specific board.** No onboard USB-host MCU,
  so gamepads need a USB HID host core, a PMOD adapter, or an SNES/DS2-style
  pad wired to the 40-pin header. The core side is trivial — 8 active-high
  bits per pad ([gametank.sv:63](../rtl/gametank.sv:63)).
- **Done when:** two pads work and audio matches the MiSTer build by ear on
  the same cart.

### T6 — Build tooling

- `tools/gametank-build` (Docker + Quartus) gets a Gowin sibling driving
  `gw_sh`. `tools/gametank-test` is untouched — it never needed a vendor
  toolchain.
- **Licensing note:** GW5AST-138 requires a licensed Gowin EDA, typically
  node-locked. Synthesis in GitHub Actions is therefore likely off the table;
  the Verilator CI is unaffected and remains the gate.

## Risks and open questions

| # | Item | Mitigation |
|---|---|---|
| K1 | ~~SystemVerilog maturity in GowinSynthesis~~ — **closed in T0/T2**: all core files compile, place and route with no rewrites | — |
| K2 | Registers relying on declaration initializers with no reset — deliberate in [ddr_mux.sv:63](../rtl/ddr_mux.sv:63) and the cart download path | Confirm Gowin emits power-up init values in the bitstream; add resets only if it does not |
| K3 | ~~`$readmemh` BSRAM init~~ — **closed in T2**: the boot cart maps to 18 pROM blocks | — |
| K4 | ~~GRAM port replication~~ — **closed in T1**: GRAM in BSRAM costs 256/340 units, does not fit | DDR3 path retained; no action |
| K5 | ~~Board unknowns: reference clock, DVI TX topology~~ — **resolved for video in T2** (50 MHz on P16; TMDS straight off FPGA pins via TLVDS_OBUF). The audio codec is still unknown | Pull the schematic before wiring the T5 audio path |
| K6 | Gamepad sourcing on a dock with no USB-host MCU | Decide early — it may motivate the Tang Console 138K instead (below) |
| K7 | Licensed toolchain blocks synthesis in CI | Accept; Verilator CI is the real gate anyway |
| K8 | ~~The SDRAM pinout is undocumented~~ — **closed**: taken from `tang/mega.cst`, though that file is labelled for the Tang Console rather than the Mega Pro Dock | Check the SDRAM pins against the dock schematic before powering a module |
| K9 | ~~`tang/sdram.sv` has never been run~~ — **closed**: oss-cad-suite (Verilator 5.051) is on this machine and the test passes | — |
| K10 | The newer Verilator raises ~90 lint warnings on pre-existing `rtl/` (savectl, via6522, ALU) that `sim/waivers.vlt` does not cover, and its `verilated.cpp` wants the legacy `sc_time_stamp` hook the older tests do not define | Neither is caused by the port; both need a pass over the sim setup if the project moves to a current Verilator |

### Board alternative worth naming

The **Tang Console 138K** targets retro cores specifically (BL616 USB host,
HDMI, gamepad ports, SD) and would erase most of T5 and part of T4. If the
Mega 138K Pro's PCIe/SFP+/AE350 features are not wanted for this project, the
Console is the cheaper target for the same FPGA class.

## What changed in `rtl/`, and what did not

T2 could not leave `rtl/` completely untouched. The edits so far:

| File | Edit | Visible to MiSTer / Verilator? |
|---|---|---|
| `gametank.sv` | forward declarations moved above first use | no — pure reordering |
| `frame_snapshot.sv` | scan read split into its own `always_ff` | no — identical semantics |
| `acp.sv`, `vram.sv`, `mainbus.sv` | Gowin-only RAM write-mode variants behind `` `GOWIN `` | no — the `` `else `` branch is the original text |

Everything else is additive (`tang/`, `tools/gametank-build-tang`).

**The `` `GOWIN `` guards were a debt; the suite has now paid it.** They exist
because the Verilator suite could not be run when the edits were made. It can
be now (oss-cad-suite is on this machine), and it was run **both ways**:

| Run | Result |
|---|---|
| Default (MiSTer/Verilator branches) | **26 pass, 0 fail** — the entire unit and integration suite, lockstep included |
| `-DGOWIN` (the branches the Tang bitstream contains) | 17 pass, 0 fail |

So the two RAM descriptions are interchangeable as far as the suite can see,
and the Tang build is no longer running RTL that nothing tests. Collapsing
each guard to a single description is now a safe, optional cleanup — the one
reason to hold off is that it would also change what Quartus infers for the
MiSTer build, and there is no Quartus here to confirm that.

Unchanged:

- All of `sim/` — harness, waivers, every test, and the lockstep emulator
  comparison. Any RTL edit made for Gowin must keep them green; that is the
  porting contract, and it is **verified** for the T2/T3 edits (see above) —
  including both lockstep tests, which compare frame dumps against the pinned
  reference emulator. `lockstep_fb_pattern` matches on frame CRC and
  `lockstep_blit_scene` is byte-identical over 12 frames, so the RTL edits did
  not move the core off the emulator it is validated against.
- [HARDWARE.md](HARDWARE.md) and [REQUIREMENTS.md](REQUIREMENTS.md) fidelity
  targets, with one hardware-imposed exception now recorded: the console
  clock runs +331 ppm fast on this board (see T2).

## Sources

- [Tang Mega 138K Pro Dock — Sipeed Wiki](https://wiki.sipeed.com/hardware/en/tang/tang-mega-138k/mega-138k-pro.html)
- [Gowin Arora V FPGA Products Overview (DS1228)](https://cdn.gowinsemi.com.cn/DS1228E.pdf)
- [GW5AST series Data Sheet (DS1104)](https://cdn.gowinsemi.com.cn/DS1104E.pdf)
- [Arora V BSRAM & SSRAM User Guide (UG300)](https://cdn.gowinsemi.com.cn/UG300E.pdf)
- [SNESTang design notes (iosys, Mega 138K Pro DDR3, HDMI)](https://github.com/nand2mario/snestang/blob/main/doc/design.md)
- [Sipeed — installing Gowin EDA and licensing](https://wiki.sipeed.com/hardware/en/tang/common-doc/get_started/install-the-ide.html)
