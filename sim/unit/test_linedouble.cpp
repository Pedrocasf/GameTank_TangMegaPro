// Directed test for tang/linedouble.sv.
//
// The doubler is driven with a synthetic raster matching rtl/gtvideo.sv's
// documented timing (908 dots/line at ce_pix, hsync dots 32-63, hblank dots
// 0-159, 262 lines, vsync lines 4-7, vblank lines 0-15) and its output is
// measured the way a display would look at it: sync edges, their spacing, DE
// width, lines per frame, and whether each input line really does come back
// out twice with the same pixels.
//
// This exists because "no picture" on hardware has very few observable
// causes, and a doubler that never toggles hsync — or emits the wrong number
// of lines per frame — looks exactly like a dead link from the outside.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include <verilated.h>
#include "Vlinedouble.h"
#include "vl_compat.h"

#define CHECK(cond, ...)                                                  \
    do {                                                                  \
        if (!(cond)) {                                                    \
            std::fprintf(stderr, "FAIL %s:%d: %s\n     ", __FILE__,       \
                         __LINE__, #cond);                                \
            std::fprintf(stderr, __VA_ARGS__);                            \
            std::fprintf(stderr, "\n");                                   \
            std::exit(1);                                                 \
        }                                                                 \
    } while (0)

// rtl/gtvideo.sv timing, in dots (one dot = one ce_pix tick)
static constexpr int DOTS       = 908;
static constexpr int LINES      = 262;
static constexpr int HSYNC_ON   = 32;
static constexpr int HSYNC_OFF  = 64;
static constexpr int HBLANK_END = 160;
static constexpr int VSYNC_ON   = 4;
static constexpr int VSYNC_OFF  = 8;
static constexpr int VBLANK_END = 16;

int main() {
    Vlinedouble top;
    top.clk = 0; top.reset = 1; top.ce_pix = 0;
    top.eval();

    // Hold reset a few clocks, as the board top does.
    for (int i = 0; i < 8; i++) {
        top.clk = 1; top.eval(); top.clk = 0; top.eval();
    }
    top.reset = 0;

    struct Sample { bool hs, vs, de; uint8_t r, g, b; };
    std::vector<Sample> out;

    // Two full frames: the first settles the one-line pipeline, the second is
    // measured.
    int dot = 0, line = 0;
    bool phase = false;                     // ce_pix is every other clk
    for (long clk = 0; clk < 2L * LINES * DOTS * 2; clk++) {
        bool ce = phase;
        phase = !phase;

        top.ce_pix    = ce;
        top.hsync_in  = (dot >= HSYNC_ON && dot < HSYNC_OFF);
        top.hblank_in = (dot < HBLANK_END);
        top.vsync_in  = (line >= VSYNC_ON && line < VSYNC_OFF);
        top.vblank_in = (line < VBLANK_END);
        // A pattern that identifies the source dot and line exactly.
        top.r_in = (uint8_t)line;
        top.g_in = (uint8_t)(dot >> 2);
        top.b_in = (uint8_t)(dot & 3);

        top.clk = 1; top.eval();
        top.clk = 0; top.eval();

        out.push_back({(bool)top.hsync_out, (bool)top.vsync_out,
                       (bool)top.de_out, top.r_out, top.g_out, top.b_out});

        if (ce) {
            if (++dot == DOTS) { dot = 0; if (++line == LINES) line = 0; }
        }
    }

    // ---- sync must actually toggle ---------------------------------------
    std::vector<size_t> hs_rise, vs_rise;
    for (size_t i = 1; i < out.size(); i++) {
        if (out[i].hs && !out[i - 1].hs) hs_rise.push_back(i);
        if (out[i].vs && !out[i - 1].vs) vs_rise.push_back(i);
    }
    CHECK(hs_rise.size() > 100, "hsync only rose %zu times — a display sees "
          "this as a dead link", hs_rise.size());
    CHECK(vs_rise.size() >= 2, "vsync only rose %zu times", vs_rise.size());

    // ---- one output line per 908 clocks, two per input line --------------
    int bad = 0;
    for (size_t i = 2; i < hs_rise.size(); i++) {
        long d = (long)(hs_rise[i] - hs_rise[i - 1]);
        if (d != DOTS) bad++;
    }
    CHECK(bad == 0, "%d output lines were not %d clocks long", bad, DOTS);

    // ---- frame geometry ---------------------------------------------------
    long frame = (long)(vs_rise[vs_rise.size() - 1] - vs_rise[vs_rise.size() - 2]);
    CHECK(frame == 2L * LINES * DOTS, "frame is %ld clocks, want %ld",
          frame, 2L * LINES * DOTS);

    // Count output lines in a frame: hsync rises between two vsync rises.
    int lines_per_frame = 0;
    for (size_t i : hs_rise)
        if (i > vs_rise[vs_rise.size() - 2] && i <= vs_rise[vs_rise.size() - 1])
            lines_per_frame++;
    CHECK(lines_per_frame == 2 * LINES, "%d output lines per frame, want %d",
          lines_per_frame, 2 * LINES);

    // ---- DE width ---------------------------------------------------------
    // Active dots per line = DOTS - HBLANK_END, on the doubled active lines.
    // Measured from the third output line on: until the first anchor arrives
    // the output counter free-runs against a buffer holding nothing, so the
    // first line or two are partial by construction. A display meets that
    // once at power-up, which is what its own sync recovery is for.
    int de_run = 0, de_runs = 0, de_bad = 0;
    bool first_partial = true;
    for (size_t i = 2 * (size_t)DOTS; i < out.size(); i++) {
        if (out[i].de) de_run++;
        else if (de_run) {
            // The window may open partway through a run; that one is not a
            // measurement.
            if (first_partial) { first_partial = false; de_run = 0; continue; }
            de_runs++;
            if (de_run != DOTS - HBLANK_END) {
                de_bad++;
                if (de_bad <= 6)
                    std::fprintf(stderr, "  odd DE run: %d dots ending at sample %zu\n",
                                de_run, i);
            }
            de_run = 0;
        }
    }
    CHECK(de_runs > 100, "DE asserted only %d times — the display would show "
          "a blank raster", de_runs);
    CHECK(de_bad == 0, "%d DE runs were not %d dots wide", de_bad,
          DOTS - HBLANK_END);

    // ---- pixels really are doubled ---------------------------------------
    // Take two consecutive active output lines and compare their pixels.
    size_t a = 0;
    for (size_t i : hs_rise)
        if (i > vs_rise[vs_rise.size() - 2] + 40L * DOTS) { a = i; break; }
    CHECK(a != 0, "no active line found to compare");
    int diff = 0;
    for (int k = 0; k < DOTS; k++) {
        const Sample& p = out[a + k];
        const Sample& q = out[a + DOTS + k];
        if (p.de && q.de && (p.r != q.r || p.g != q.g || p.b != q.b)) diff++;
    }
    CHECK(diff == 0, "%d pixels differ between a line and its double", diff);

    std::printf("PASS linedouble: %zu hsyncs, %d lines/frame, DE %d dots, "
                "line pairs identical\n",
                hs_rise.size(), lines_per_frame, DOTS - HBLANK_END);
    return 0;
}
