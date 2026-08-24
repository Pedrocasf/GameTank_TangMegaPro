# Porting the GameTank core to the Tang Mega 138K Pro

Feasibility study (2026-08-23) for retargeting this core from the MiSTer
(DE10-Nano, Cyclone V + HPS) to the Sipeed Tang Mega 138K Pro Dock
(Gowin GW5AST-138, no HPS). Nothing here has been built or synthesized —
every number below is either read out of this repo or cited from a vendor
document, and the trial-synthesis gate in T0 exists precisely because the
Gowin toolchain claims are the only ones that cannot be checked from the
source tree.

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
| Toolchain | Gowin EDA ≥ 1.9.9, **commercial (not Education) license required** for GW5AST-138; Sipeed run an online license service |

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

Logic lands in the single-digit percents of 138k LUT4. 28.636 MHz is trivial
for this part; the TMDS serializers (5× pixel clock, ~143 MHz) are what
`OSER10` exists for. **Neither logic nor BRAM is a constraint.**

### Open question: GRAM in BSRAM instead of DDR3?

Tempting, because it would delete [rtl/gram_ddr.sv](../rtl/gram_ddr.sv)
(382 lines of prefetcher) *and* the timing deviations it documents —
`blit_starve` and `gram_stall` disappear and the blitter goes back to real
hardware behavior. That is a fidelity **win**, not just a simplification.

- Straight capacity says yes: 512 KB = 4,096 Kb + 1,207 Kb core = ~87% of
  6,120 Kb BSRAM.
- But [DEVELOPMENT_PLAN.md:83](DEVELOPMENT_PLAN.md:83) records the M4 Quartus
  fit demanding **9.7 Mbit** for the same thing — i.e. the tool replicated
  ports rather than using a single true-dual-port instance. If Gowin does the
  same, it does not fit.

Decide this with a trial synthesis in T0/T1, not by argument. Keep
`gram_ddr.sv` as the fallback path either way. The 2 MB cart image
([cart.sv:41](../rtl/cart.sv:41)) needs DDR3 regardless, so the DDR3 bridge is
not optional.

## Work items

Sequenced so that each step is independently verifiable and the riskiest
unknown (the toolchain) is answered on day one.

### T0 — Toolchain gate

- Gowin EDA project (`gw_sh` scriptable), Gowin rPLL/PLLA at 28.636364 MHz,
  `altsyncram` replaced, `rtl/` synthesized standalone with a stub top.
- Prefer **Synplify Pro** (bundled with Gowin EDA for Arora devices) over
  GowinSynthesis for SystemVerilog maturity.
- **Done when:** `rtl/` synthesizes clean and the fitter reports resource
  usage; any SV rewrites are pushed back through Verilator so the sim suite
  still passes.

### T1 — GRAM decision

- Re-run T0 with GRAM promoted to a BSRAM instance behind the existing
  `gram_ddr` port shape.
- **Done when:** the BSRAM-resident variant either fits (adopt it, drop the
  prefetcher) or does not (keep DDR3, proceed to T3).

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
| K1 | SystemVerilog maturity in GowinSynthesis (`always_ff`, `typedef enum`, `unique case`, 2-D arrays are used throughout `rtl/`) | Use bundled Synplify Pro; T0 answers this before anything else is built |
| K2 | Registers relying on declaration initializers with no reset — deliberate in [ddr_mux.sv:63](../rtl/ddr_mux.sv:63) and the cart download path | Confirm Gowin emits power-up init values in the bitstream; add resets only if it does not |
| K3 | `$readmemh` BSRAM init for the 32 KB boot cart (`bootcart.mem`) | Verify in T0; fallback is a generated `.mi` file |
| K4 | GRAM port replication (see T1) | Trial synthesis decides; DDR3 path stays as fallback |
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
