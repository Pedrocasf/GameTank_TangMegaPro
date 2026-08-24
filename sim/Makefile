# sim/Makefile — Verilator test suites for the GameTank core.
# Invoked by tools/gametank-test (and CI). Targets: unit, integration, system.
#
# The sim top for system-level tests is rtl/gametank.sv itself — sys/ is never
# simulated. CPU import-gate tests verilate the vendored core alone. Each test
# is a standalone C++ program on top of the headers in common/.

VERILATOR ?= verilator

# ---------------------------------------------------------------------------
# Host platform. Windows (Git Bash + mingw g++) differs in ways that reach
# this Makefile:
#   - executables carry .exe, the emulator the lockstep tests run included;
#   - SDL2 normally arrives as scoop's MSVC build, whose SDL2main.lib cannot
#     be linked by mingw (duplicate `main`), so the emulator is built with
#     SDL_MAIN_HANDLED, without -lSDL2main, and with the companion patch
#     emulator-patches/windows-sdl-main.patch;
#   - that SDL2.dll has to be on PATH while the emulator runs.
# Set SDL_ROOT if SDL2 lives somewhere other than scoop's default.
# ---------------------------------------------------------------------------
ifeq ($(OS),Windows_NT)
EXE           := .exe
SDL_ROOT      ?= $(subst \,/,$(USERPROFILE))/scoop/apps/sdl2/current
EMU_INCLUDES  := -Isrc/imgui -Isrc/imgui/backends -Isrc/imgui/ext/implot \
                 -Isrc/whereami -DSDL_MAIN_HANDLED
EMU_LDFLAGS   := -lmingw32 -lSDL2 -Wl,-Bstatic -mwindows -lm -ldinput8 \
                 -ldxguid -ldxerr8 -luser32 -lgdi32 -lwinmm -limm32 -lcomdlg32 \
                 -lole32 -loleaut32 -lshell32 -lversion -luuid -static-libgcc \
                 -lsetupapi
EMU_MAKE_VARS := SDL_ROOT="$(SDL_ROOT)" EXTRA_INCLUDES="$(EMU_INCLUDES)" \
                 LINKER_FLAGS="$(EMU_LDFLAGS)"
EMU_PATCHES   := lockstep-headless.patch windows-sdl-main.patch
EMU_RUN_ENV   := PATH="$(SDL_ROOT)/lib:$$PATH"
else
EXE           :=
EMU_MAKE_VARS :=
EMU_PATCHES   := lockstep-headless.patch
EMU_RUN_ENV   :=
endif

EMU_BIN := GameTankEmulator/build/GameTankEmulator$(EXE)

RTL_DIR := $(abspath ../rtl)
TANG_DIR:= $(abspath ../tang)
COMMON  := $(abspath common)
OUT     := out

CPU_SRCS := $(RTL_DIR)/cpu/cpu_65c02.v $(RTL_DIR)/cpu/ALU.v
RTL_SRCS := $(abspath waivers.vlt) $(RTL_DIR)/gametank.sv $(RTL_DIR)/gtvideo.sv \
            $(RTL_DIR)/mainbus.sv $(RTL_DIR)/acp.sv $(RTL_DIR)/pads.sv $(RTL_DIR)/via/via6522.v $(RTL_DIR)/vram.sv $(RTL_DIR)/frame_snapshot.sv $(RTL_DIR)/gram_ddr.sv $(RTL_DIR)/cart.sv $(RTL_DIR)/ddr_mux.sv $(RTL_DIR)/savectl.sv $(RTL_DIR)/blitter.sv $(RTL_DIR)/palette.sv $(CPU_SRCS)

# Our own RTL must stay -Wall clean; the vendored CPU is exempt (policy:
# vendored cores are not linted/fixed), so its builds are -Wno-fatal.
VFLAGS     := --cc --exe --build -j 0 -Wall --assert -O2 --top-module gametank
VFLAGS_CPU := --cc --exe --build -j 0 -Wno-fatal --x-assign unique --x-initial unique -O2 --top-module cpu_65c02
# tang/sdram.sv is our own RTL, so it holds to the same -Wall bar as rtl/.
# CLK_KHZ is scaled down so the 200 us power-up and the 7.8 us refresh
# interval fit in a unit test (and so refreshes interleave with traffic).
VFLAGS_SDRAM := --cc --exe --build -j 0 -Wall --assert -O2 --top-module sdram \
                -GCLK_KHZ=12800
CFLAGS     := -std=c++17 -O2 -I$(COMMON)

# ---------------------------------------------------------------------------
# Test registry. Pattern-rule tests build out/<tier>_<name> from
# <tier>/test_<name>.cpp against RTL_SRCS. Klaus import-gate tests have
# explicit rules below (extra fetch/build inputs and arguments).
# ---------------------------------------------------------------------------
UNIT_TESTS        := video_timing blitter gram_ddr cart pads_via acp mainbus vram_window sdram cpu_klaus_6502 cpu_klaus_65c02 cpu_wai_stp cpu_zpx cpu_bit_ops
INTEGRATION_TESTS := cart_ram_pattern cart_download cart_osd_load cart_fb_pattern lockstep_fb_pattern lockstep_blit_scene cart_pads_demo blit_contention gram_window_quadrant blit_bank_race gram_cpu_hostile gram_write_backpressure flash_persist flash_save_roundtrip cart_cache vidpage_latch frontbuffer_ownership via_shadow
SYSTEM_TESTS      := game_smoke

# gametank-test --test NAME passes TEST=NAME
TEST ?=
ifneq ($(TEST),)
UNIT_TESTS        := $(filter $(TEST),$(UNIT_TESTS))
INTEGRATION_TESTS := $(filter $(TEST),$(INTEGRATION_TESTS))
SYSTEM_TESTS      := $(filter $(TEST),game_smoke minicraft_title minicraft_gameplay)
endif

.PHONY: unit integration system clean
.SECONDARY:  # keep built test binaries between runs

unit: $(UNIT_TESTS:%=run-unit-%)

integration: $(INTEGRATION_TESTS:%=run-integration-%)

# System tier (opt-in, slow): real games through the DDR3 cart path.
# Usage: make system GTR_GAME=/abs/path/to/game.gtr [TEST=minicraft_title]
system: $(SYSTEM_TESTS:%=$(OUT)/system_%)
	@if [ -n "$(GTR_GAME)" ]; then \
	  for test in $(SYSTEM_TESTS); do \
	    echo ">>> system/$$test"; \
	    (cd $(OUT) && ./system_$$test "$(GTR_GAME)") || exit $$?; \
	  done; \
	else echo "set GTR_GAME=/abs/path/to/game.gtr to run" >&2; exit 2; fi

$(OUT)/system_%: system/test_%.cpp common/sim_harness.h $(RTL_SRCS) | $(OUT)
	@mkdir -p obj_dir/system_$*
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir/system_$* -CFLAGS "$(CFLAGS)" \
		-o $(abspath $@) $(RTL_SRCS) $(abspath $<)

run-unit-%: $(OUT)/unit_%
	@echo ">>> unit/$*"
	@cd $(OUT) && ./unit_$*

run-integration-%: $(OUT)/integration_%
	@echo ">>> integration/$*"
	@cd $(OUT) && ./integration_$*

$(OUT)/unit_%: unit/test_%.cpp common/sim_harness.h $(RTL_SRCS) | $(OUT)
	@mkdir -p obj_dir/unit_$*
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir/unit_$* -CFLAGS "$(CFLAGS)" \
		-o $(abspath $@) $(RTL_SRCS) $(abspath $<)

# The SDRAM controller is a Tang-port block with its own top and its own
# harness (a behavioural chip on the pins), so it gets an explicit rule.
$(OUT)/unit_sdram: unit/test_sdram.cpp common/sdram_harness.h $(TANG_DIR)/sdram.sv | $(OUT)
	@mkdir -p obj_dir/unit_sdram
	$(VERILATOR) $(VFLAGS_SDRAM) --Mdir obj_dir/unit_sdram -CFLAGS "$(CFLAGS)" \
		-o $(abspath $@) $(TANG_DIR)/sdram.sv $(abspath $<)

$(OUT)/integration_%: integration/test_%.cpp common/sim_harness.h $(RTL_SRCS) | $(OUT)
	@mkdir -p obj_dir/integration_$*
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir/integration_$* -CFLAGS "$(CFLAGS)" \
		-o $(abspath $@) $(RTL_SRCS) $(abspath $<)

$(OUT):
	mkdir -p $(OUT)

# ---------------------------------------------------------------------------
# Test carts (ca65/ld65 from the cc65 suite)
# ---------------------------------------------------------------------------
run-integration-cart_ram_pattern: testroms/ram_pattern.gtr
run-integration-cart_download: testroms/ram_pattern.gtr
run-integration-cart_osd_load: testroms/ram_pattern.gtr testroms/fb_pattern.gtr

testroms/ram_pattern.gtr: testroms/ram_pattern/ram_pattern.s testroms/ram_pattern/gametank.cfg
	cd testroms/ram_pattern && \
	  ca65 ram_pattern.s -o ram_pattern.o && \
	  ld65 ram_pattern.o -C gametank.cfg -o ../ram_pattern.gtr

clean:
	rm -rf obj_dir $(OUT)

# ---------------------------------------------------------------------------
# Klaus Dormann import gate (one-time gate on the vendored CPU, TESTING.md).
# Test material is cloned on demand at pinned commits — never vendored.
# ---------------------------------------------------------------------------
KLAUS_URL    := https://github.com/Klaus2m5/6502_65C02_functional_tests
KLAUS_COMMIT := 7954e2dbb49c469ea286070bf46cdd71aeb29e4b
AMB5L_URL    := https://github.com/amb5l/6502_65C02_functional_tests
AMB5L_COMMIT := 966b1a35049f9d8be44ad092ec6d43d5ba1831b3

klaus/upstream/.stamp:
	rm -rf klaus/upstream
	git clone -q $(KLAUS_URL) klaus/upstream
	cd klaus/upstream && git checkout -q $(KLAUS_COMMIT)
	touch $@

klaus/ca65port/.stamp:
	rm -rf klaus/ca65port
	git clone -q $(AMB5L_URL) klaus/ca65port
	cd klaus/ca65port && git checkout -q $(AMB5L_COMMIT)
	touch $@

# 65C02 extended test, reassembled per docs/DEPENDENCIES.md: Rockwell bit ops
# ON (rkwl_wdc_op = 1 exercises BBR/BBS/RMB/SMB, which Ganymede uses — M8;
# the same flag makes the test *skip* WAI/STP, which have directed tests),
# and a label planted on the success trap so the testbench can detect it.
klaus/65C02_extended_opcodes_test.bin: klaus/ca65port/.stamp
	cd klaus/ca65port/ca65 && \
	  sed -e 's/^        success         ;if you get here everything went well/success_pc: success ;(label planted by sim build)/' \
	      65C02_extended_opcodes_test.ca65 > extended_gt.ca65 && \
	  ca65 -g -l extended_gt.lst extended_gt.ca65 && \
	  ld65 extended_gt.o -o $(abspath $@) -m extended_gt.map -Ln extended_gt.lbl -C example.cfg

klaus/extended_success_pc.txt: klaus/65C02_extended_opcodes_test.bin
	grep -i '\.success_pc$$' klaus/ca65port/ca65/extended_gt.lbl \
	  | awk '{print $$2}' | sed 's/^00//' > $@
	@test -s $@ || { echo "success_pc label not found"; rm -f $@; exit 1; }

$(OUT)/unit_cpu_klaus: unit/test_cpu_klaus.cpp common/cpu65_harness.h $(CPU_SRCS) | $(OUT)
	@mkdir -p obj_dir/unit_cpu_klaus
	$(VERILATOR) $(VFLAGS_CPU) --Mdir obj_dir/unit_cpu_klaus -CFLAGS "$(CFLAGS)" \
		-o $(abspath $@) $(CPU_SRCS) $(abspath $<)

$(OUT)/unit_cpu_wai_stp: unit/test_cpu_wai_stp.cpp common/cpu65_harness.h $(CPU_SRCS) | $(OUT)
	@mkdir -p obj_dir/unit_cpu_wai_stp
	$(VERILATOR) $(VFLAGS_CPU) --Mdir obj_dir/unit_cpu_wai_stp -CFLAGS "$(CFLAGS)" \
		-o $(abspath $@) $(CPU_SRCS) $(abspath $<)

$(OUT)/unit_cpu_zpx: unit/test_cpu_zpx.cpp common/cpu65_harness.h $(CPU_SRCS) | $(OUT)
	@mkdir -p obj_dir/unit_cpu_zpx
	$(VERILATOR) $(VFLAGS_CPU) --Mdir obj_dir/unit_cpu_zpx -CFLAGS "$(CFLAGS)" \
		-o $(abspath $@) $(CPU_SRCS) $(abspath $<)

$(OUT)/unit_cpu_bit_ops: unit/test_cpu_bit_ops.cpp common/cpu65_harness.h $(CPU_SRCS) | $(OUT)
	@mkdir -p obj_dir/unit_cpu_bit_ops
	$(VERILATOR) $(VFLAGS_CPU) --Mdir obj_dir/unit_cpu_bit_ops -CFLAGS "$(CFLAGS)" \
		-o $(abspath $@) $(CPU_SRCS) $(abspath $<)

run-unit-cpu_klaus_6502: $(OUT)/unit_cpu_klaus klaus/upstream/.stamp
	@echo ">>> unit/cpu_klaus_6502"
	@cd $(OUT) && ./unit_cpu_klaus ../klaus/upstream/bin_files/6502_functional_test.bin 3469

run-unit-cpu_klaus_65c02: $(OUT)/unit_cpu_klaus klaus/65C02_extended_opcodes_test.bin klaus/extended_success_pc.txt
	@echo ">>> unit/cpu_klaus_65c02"
	@cd $(OUT) && ./unit_cpu_klaus ../klaus/65C02_extended_opcodes_test.bin $$(cat ../klaus/extended_success_pc.txt)

run-integration-cart_fb_pattern: testroms/fb_pattern.gtr

testroms/fb_pattern.gtr: testroms/fb_pattern/fb_pattern.s testroms/fb_pattern/gametank.cfg
	cd testroms/fb_pattern && \
	  ca65 fb_pattern.s -o fb_pattern.o && \
	  ld65 fb_pattern.o -C gametank.cfg -o ../fb_pattern.gtr

# Blitter unit tests verilate rtl/blitter.sv alone (our RTL, -Wall applies)
$(OUT)/unit_blitter: unit/test_blitter.cpp $(RTL_DIR)/blitter.sv | $(OUT)
	@mkdir -p obj_dir/unit_blitter
	$(VERILATOR) --cc --exe --build -j 0 -Wall --assert -O2 --top-module blitter \
		--Mdir obj_dir/unit_blitter -CFLAGS "$(CFLAGS)" \
		-o $(abspath $@) $(RTL_DIR)/blitter.sv $(abspath $<)

# ---------------------------------------------------------------------------
# Emulator-lockstep harness. GameTankEmulator is cloned on demand at a pinned
# commit, patched for headless per-frame framebuffer dumps (see
# emulator-patches/lockstep-headless.patch and docs/TESTING.md), and run with
# SDL dummy drivers — same .gtr as the Verilator side, dumps compared.
# ---------------------------------------------------------------------------
EMU_URL    := https://github.com/clydeshaffer/GameTankEmulator
EMU_COMMIT := e7e25e2daf5da5d041ae8dc48f740a362c1e66ff

GameTankEmulator/.stamp:
	rm -rf GameTankEmulator
	git clone -q $(EMU_URL) GameTankEmulator
	cd GameTankEmulator && git checkout -q $(EMU_COMMIT) && \
	  git submodule update --init --depth 1 src/mos6502 src/imgui/ext/implot && \
	  $(foreach p,$(EMU_PATCHES),git apply $(abspath emulator-patches/$(p)) &&) true
	touch $@

$(EMU_BIN): GameTankEmulator/.stamp
	+$(MAKE) -C GameTankEmulator build/GameTankEmulator$(EXE) $(EMU_MAKE_VARS)

LOCKSTEP_FRAMES ?= 12

$(OUT)/%.emu_frames.bin: testroms/%.gtr $(EMU_BIN) | $(OUT)
	$(EMU_RUN_ENV) SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
	GTE_LOCKSTEP_OUT=$(abspath $@) GTE_LOCKSTEP_FRAMES=$(LOCKSTEP_FRAMES) \
	  ./$(EMU_BIN) --softrender --nosound --nojoystick \
	  $(abspath $<) >/dev/null 2>&1

run-integration-lockstep_fb_pattern: $(OUT)/integration_lockstep_fb_pattern \
                                     $(OUT)/fb_pattern.emu_frames.bin testroms/fb_pattern.gtr
	@echo ">>> integration/lockstep_fb_pattern"
	@cd $(OUT) && ./integration_lockstep_fb_pattern fb_pattern.emu_frames.bin

testroms/blit_scene.gtr: testroms/blit_scene/blit_scene.s testroms/blit_scene/gametank.cfg
	cd testroms/blit_scene && \
	  ca65 blit_scene.s -o blit_scene.o && \
	  ld65 blit_scene.o -C gametank.cfg -o ../blit_scene.gtr

run-integration-lockstep_blit_scene: $(OUT)/integration_lockstep_blit_scene \
                                     $(OUT)/blit_scene.emu_frames.bin testroms/blit_scene.gtr
	@echo ">>> integration/lockstep_blit_scene"
	@cd $(OUT) && ./integration_lockstep_blit_scene blit_scene.emu_frames.bin

$(OUT)/unit_gram_ddr: unit/test_gram_ddr.cpp $(RTL_DIR)/gram_ddr.sv | $(OUT)
	@mkdir -p obj_dir/unit_gram_ddr
	$(VERILATOR) --cc --exe --build -j 0 -Wall --assert -O2 --top-module gram_ddr \
		--Mdir obj_dir/unit_gram_ddr -CFLAGS "$(CFLAGS)" \
		-o $(abspath $@) $(RTL_DIR)/gram_ddr.sv $(abspath $<)

testroms/pads_demo.gtr: testroms/pads_demo/pads_demo.s testroms/pads_demo/gametank.cfg
	cd testroms/pads_demo && \
	  ca65 pads_demo.s -o pads_demo.o && \
	  ld65 pads_demo.o -C gametank.cfg -o ../pads_demo.gtr

run-integration-cart_pads_demo: testroms/pads_demo.gtr
