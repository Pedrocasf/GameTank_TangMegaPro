# Porting the GameTank core to the Tang Mega 138K Pro

Feasibility study (2026-08-23) for retargeting this core from the MiSTer
(DE10-Nano, Cyclone V + HPS) to the Sipeed Tang Mega 138K Pro Dock
(Gowin GW5AST-138, no HPS).

**Status: T0 and T1 executed 2026-08-23** — the core synthesizes clean under
GowinSynthesis, measured utilization is 19% BSRAM / 4% logic, and GRAM stays
in DDR3. Details in those sections. Everything from T2 onward is still
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

### Resolved: GRAM stays in DDR3

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
`gram_ddr.sv` survives the port unchanged, and the DDR3 bridge (T3) is on the
critical path — as it would have been anyway for the 2 MB cart image
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

### T2 — Video out

- Line-double the core's native raster into a DVI/TMDS transmitter. The core
  emits 908 dots × 262 lines at a 14.318 MHz dot clock, 60.19 Hz
  ([gtvideo.sv:17](../rtl/gtvideo.sv:17)); doubling gives 908 × 524 at
  28.636 MHz — a custom mode close enough to 640×480 that most displays
  accept it, and it preserves the native refresh rate rather than resampling
  to 60.000 Hz.
- Deliberately *simpler* than SNESTang's 720p + pause-sync approach, and
  better suited to a project whose fidelity target is raster-honest video
  ([REQUIREMENTS.md](REQUIREMENTS.md) R3).
- **Done when:** the built-in boot cart is visible on an HDMI display with no
  front-end at all.

### T3 — DDR3 bridge

- Async FIFO bridge from `clk_sys` (28.636 MHz) to the Gowin DDR3 user clock,
  presenting the `rd/we/busy/dout_ready/burstcnt` semantics that
  [ddr_mux.sv:1](../rtl/ddr_mux.sv:1) documents and its three clients assume.
- Low risk by construction: every client already tolerates variable, high
  latency (blitter stalls, CPU clock-enable stretch, background save pacing).
- **Done when:** the existing integration tests (`cart_download`, `cart_cache`,
  `gram_*`, `blit_contention`) pass against the bridged path in simulation,
  and a `.gtr` preloaded into DDR3 runs on hardware.

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
| K1 | ~~SystemVerilog maturity in GowinSynthesis~~ — **closed in T0**: all 16 core files compiled clean, no rewrites | PnR-stage surprises remain possible; re-check when T0's PnR half runs |
| K2 | Registers relying on declaration initializers with no reset — deliberate in [ddr_mux.sv:63](../rtl/ddr_mux.sv:63) and the cart download path | Confirm Gowin emits power-up init values in the bitstream; add resets only if it does not |
| K3 | `$readmemh` BSRAM init for the 32 KB boot cart (`bootcart.mem`) | Verify in T0; fallback is a generated `.mi` file |
| K4 | ~~GRAM port replication~~ — **closed in T1**: GRAM in BSRAM costs 256/340 units, does not fit | DDR3 path retained; no action |
| K5 | Board unknowns: audio codec, DVI TX topology, reference-clock frequency into the FPGA | Pull the schematics before committing to the clock and audio plans |
| K6 | Gamepad sourcing on a dock with no USB-host MCU | Decide early — it may motivate the Tang Console 138K instead (below) |
| K7 | Licensed toolchain blocks synthesis in CI | Accept; Verilator CI is the real gate anyway |

### Board alternative worth naming

The **Tang Console 138K** targets retro cores specifically (BL616 USB host,
HDMI, gamepad ports, SD) and would erase most of T5 and part of T4. If the
Mega 138K Pro's PCIe/SFP+/AE350 features are not wanted for this project, the
Console is the cheaper target for the same FPGA class.

## What does *not* change

- All of `rtl/` except `acp.sv`'s RAM and the PLL.
- All of `sim/` — harness, waivers, every test, and the lockstep emulator
  comparison. Any RTL edit made for Gowin must keep them green; that is the
  porting contract.
- [HARDWARE.md](HARDWARE.md) and [REQUIREMENTS.md](REQUIREMENTS.md) fidelity
  targets. A BSRAM-resident GRAM (T1) would *remove* documented deviations,
  never add any.

## Sources

- [Tang Mega 138K Pro Dock — Sipeed Wiki](https://wiki.sipeed.com/hardware/en/tang/tang-mega-138k/mega-138k-pro.html)
- [Gowin Arora V FPGA Products Overview (DS1228)](https://cdn.gowinsemi.com.cn/DS1228E.pdf)
- [GW5AST series Data Sheet (DS1104)](https://cdn.gowinsemi.com.cn/DS1104E.pdf)
- [Arora V BSRAM & SSRAM User Guide (UG300)](https://cdn.gowinsemi.com.cn/UG300E.pdf)
- [SNESTang design notes (iosys, Mega 138K Pro DDR3, HDMI)](https://github.com/nand2mario/snestang/blob/main/doc/design.md)
- [Sipeed — installing Gowin EDA and licensing](https://wiki.sipeed.com/hardware/en/tang/common-doc/get_started/install-the-ide.html)
