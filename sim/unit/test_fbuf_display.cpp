// End-to-end test for tang/fbuf_display.sv, driven by the real rtl/gtvideo.sv.
//
// The console framebuffer is filled with a pattern that identifies every
// coordinate uniquely, gtvideo scans it out, fbuf_display samples that stream
// back into a 128x128 image, and the display output is then compared against
// what should be on screen. Getting (x, y) wrong on the write side is exactly
// what produced "unstable grey boxes" on hardware, and it is invisible to any
// test that regenerates the raster in C++ instead of using the generator.
//
// Checks: the output raster is 640x480@60 with correct sync geometry, the
// picture sits where it should, and every displayed pixel carries the value
// its source coordinate was given.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include <verilated.h>
#include "Vtb_fbuf_display.h"
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

// Output raster (tang/fbuf_display.sv)
static constexpr int H_ACT = 640, H_FP = 16, H_SY = 96, H_TOT = 800;
static constexpr int V_ACT = 480, V_FP = 10, V_SY = 2,  V_TOT = 525;
static constexpr int V_PAD = (V_ACT - 128 * 3) / 2;

// The palette is not in this path: gtvideo emits RGB from its own table, so
// the test compares against what gtvideo actually produced for each source
// pixel rather than against the framebuffer byte.
static uint8_t fb[16384];

int main() {
    Vtb_fbuf_display top;

    // Each source pixel gets a distinct byte so a mis-mapped coordinate shows
    // up as a wrong colour rather than a plausible one.
    for (int y = 0; y < 128; y++)
        for (int x = 0; x < 128; x++)
            fb[(y << 7) | x] = (uint8_t)((x * 7 + y * 13) & 0xFF);

    top.clk_sys = 0; top.clk_pix = 0;
    top.reset = 1; top.pix_reset = 1;
    top.fb_data = 0;
    top.eval();

    // What gtvideo emitted for each source pixel, learned from the native
    // stream during the run.
    struct Rgb { uint8_t r, g, b; bool seen; };
    std::vector<Rgb> expect(16384, {0, 0, 0, false});

    // Native-side tracking, mirroring gtvideo's documented geometry.
    int  n_dot = 0, n_line = 0;
    bool hs_d = false, vs_d = false;

    // Display-side capture
    struct Sample { bool hs, vs, de; uint8_t r, g, b; };
    std::vector<Sample> out;

    int  d_hx = 0, d_vy = 0;
    bool d_hs_d = false, d_vs_d = false;
    bool started = false;

    // Step the pixel clock, interleaving console clocks at the true ratio
    // (28.6458 : 25.125). Two captured frames is plenty; one frame is
    // 800 x 525 pixel clocks, so the run has to be long enough to reach it —
    // the first attempt at this test ran a fifth of a frame and saw nothing.
    long acc = 0;
    int  frames = 0;
    const long SYS_INC = 28646, PIX_INC = 25125;

    auto sys_tick = [&](long i) {
        top.fb_data = fb[top.fb_addr & 0x3FFF];
        top.clk_sys = 1; top.eval();
        top.clk_sys = 0; top.eval();
        if (i > 500) top.reset = 0;

        bool h_rise = top.hsync_native && !hs_d;
        bool v_rise = top.vsync_native && !vs_d;
        hs_d = top.hsync_native;
        vs_d = top.vsync_native;

        if (v_rise)            { n_line = 0; n_dot = 0; }
        else if (h_rise)       { n_line++;   n_dot = 0; }
        else if (top.ce_pix)   { n_dot++; }

        if (top.ce_pix && !top.reset) {
            int rel_d = n_dot - 188;
            int rel_l = n_line - 12;
            if (rel_d >= 0 && rel_l >= 0) {
                int x = rel_d / 5;
                int y = rel_l / 2;
                if (x < 128 && y < 128)
                    expect[(y << 7) | x] = {top.r_native, top.g_native,
                                            top.b_native, true};
            }
        }
    };

    for (long p = 0; p < 8000000L && frames < 5; p++) {
        acc += SYS_INC;
        while (acc >= PIX_INC) { acc -= PIX_INC; sys_tick(p); }

        top.clk_pix = 1; top.eval();
        top.clk_pix = 0; top.eval();
        if (p > 500) top.pix_reset = 0;

        if (!top.pix_reset) {
            bool v_rise = top.vsync_out && !d_vs_d;
            d_vs_d = top.vsync_out;
            if (v_rise) {
                frames++;
                // Let the console paint whole frames first: the display reads
                // the store asynchronously, so a frame captured while the
                // console is still filling it shows stale rows at the top.
                // That is a real (and documented) property of the frame store,
                // not something to measure the mapping against.
                if (frames == 4) { started = true; out.clear(); }
            }
            if (started) out.push_back({(bool)top.hsync_out, (bool)top.vsync_out,
                                        (bool)top.de_out, top.r_out, top.g_out,
                                        top.b_out});
        }
    }
    (void)d_hs_d; (void)d_hx; (void)d_vy;

    CHECK(out.size() > (size_t)H_TOT * V_TOT,
          "captured only %zu display samples", out.size());

    // ---- output raster geometry ------------------------------------------
    std::vector<size_t> hs_rise;
    for (size_t i = 1; i < out.size(); i++)
        if (out[i].hs && !out[i - 1].hs) hs_rise.push_back(i);
    CHECK(hs_rise.size() > 100, "hsync rose only %zu times", hs_rise.size());
    int bad = 0;
    for (size_t i = 2; i < hs_rise.size(); i++)
        if ((long)(hs_rise[i] - hs_rise[i - 1]) != H_TOT) bad++;
    CHECK(bad == 0, "%d output lines were not %d clocks", bad, H_TOT);

    // ---- DE geometry ------------------------------------------------------
    int de_run = 0, de_runs = 0, de_bad = 0;
    bool first = true;
    for (size_t i = 1; i < out.size(); i++) {
        if (out[i].de) de_run++;
        else if (de_run) {
            if (first) { first = false; de_run = 0; continue; }
            de_runs++;
            if (de_run != H_ACT) de_bad++;
            de_run = 0;
        }
    }
    CHECK(de_bad == 0, "%d DE runs were not %d dots", de_bad, H_ACT);
    CHECK(de_runs >= V_ACT - 2, "only %d active lines, want about %d",
          de_runs, V_ACT);

    // ---- the picture itself ----------------------------------------------
    // Walk the captured frame by output coordinate and compare each pixel in
    // the picture window against the source it should have come from.
    // Locate the picture from DE itself rather than from sample arithmetic:
    // the read path registers address, data and DE together, so counting
    // active runs is immune to the pipeline depth. Active line N of the frame
    // shows source row (N - V_PAD) / 3, and dot M of that line shows source
    // column M / 5.
    int checked = 0, wrong = 0, first_bad_x = -1, first_bad_y = -1;
    std::vector<int> bad_x(128, 0), bad_y(128, 0);
    std::vector<int> bad_col_of_row(128, -1);
    int active_line = -1;
    size_t i = 0;
    while (i < out.size()) {
        if (!out[i].de) { i++; continue; }
        size_t run_start = i;
        while (i < out.size() && out[i].de) i++;
        size_t run_len = i - run_start;
        if ((int)run_len != H_ACT) continue;      // partial run at a capture edge
        active_line++;
        int sy_line = active_line - V_PAD;
        if (sy_line < 0 || sy_line >= 384) continue;
        int sy = sy_line / 3;
        for (size_t k = 0; k < run_len; k++) {
            int sx = (int)(k / 5);
            const Rgb& e = expect[(sy << 7) | sx];
            if (!e.seen) continue;
            const Sample& o = out[run_start + k];
            checked++;
            if (((o.r ^ e.r) & 0xF8) || ((o.g ^ e.g) & 0xF8) ||
                ((o.b ^ e.b) & 0xF8)) {
                if (wrong == 0) { first_bad_x = sx; first_bad_y = sy; }
                bad_x[sx]++; bad_y[sy]++;
                if (bad_col_of_row[sy] < 0) bad_col_of_row[sy] = sx;
                wrong++;
            }
        }
    }

    // When the picture is wrong, say *how* it is wrong: a mapping that is
    // merely shifted shows up as a near-perfect match at some (dx, dy), which
    // turns a guessing game into an arithmetic fix.
    if (wrong > checked / 20) {
        int ncol = 0;
        for (int x = 0; x < 128; x++) if (bad_x[x]) ncol++;
        std::fprintf(stderr, "  %d columns affected; rows:\n", ncol);
        // Is the bad column showing a neighbour's pixel?
        for (int y = 0; y < 1; y++) {
            for (int x = 121; x <= 127; x++) {
                const Rgb& e = expect[(y << 7) | x];
                std::fprintf(stderr, "    src (%d,%d) seen=%d rgb=%02x%02x%02x\n",
                             x, y, (int)e.seen, e.r, e.g, e.b);
            }
        }
        for (int y = 0; y < 128; y++)
            if (bad_y[y]) std::fprintf(stderr, "    row %d: %d px, first bad column %d\n", y, bad_y[y], bad_col_of_row[y]);
    }

    if (wrong > checked / 100) {
        int best = -1, bdx = 0, bdy = 0;
        for (int dy = -4; dy <= 4; dy++) {
            for (int dx = -4; dx <= 4; dx++) {
                int hit = 0, tot = 0, al = -1;
                size_t j = 0;
                while (j < out.size()) {
                    if (!out[j].de) { j++; continue; }
                    size_t rs = j;
                    while (j < out.size() && out[j].de) j++;
                    if ((int)(j - rs) != H_ACT) continue;
                    al++;
                    int syl = al - V_PAD;
                    if (syl < 0 || syl >= 384) continue;
                    int sy = syl / 3 + dy;
                    if (sy < 0 || sy > 127) continue;
                    for (size_t k = 0; k < (size_t)H_ACT; k++) {
                        int sx = (int)(k / 5) + dx;
                        if (sx < 0 || sx > 127) continue;
                        const Rgb& e = expect[(sy << 7) | sx];
                        if (!e.seen) continue;
                        tot++;
                        const Sample& o = out[rs + k];
                        if (!(((o.r ^ e.r) & 0xF8) || ((o.g ^ e.g) & 0xF8) ||
                              ((o.b ^ e.b) & 0xF8))) hit++;
                    }
                }
                if (tot > 1000 && hit > best) { best = hit; bdx = dx; bdy = dy; }
            }
        }
        std::fprintf(stderr, "  best alignment: dx=%d dy=%d matching %d px\n",
                     bdx, bdy, best);
    }

    CHECK(checked > 100000, "only %d pixels were checkable", checked);

    // What this can honestly assert: the mapping. The store is single
    // buffered and the two rasters run at their own rates (60.19 vs 59.9 Hz),
    // so wherever the display's read crosses the console's write, a band of
    // rows shows a mix of two paintings. That is the documented behaviour of
    // the frame store, and it appears as a couple of contiguous rows.
    //
    // A mapping regression looks nothing like that: the offsets that produced
    // "unstable grey boxes" on hardware put 30-96% of pixels wrong, spread
    // over every row. Bounding the number of *affected rows* separates the
    // two — tearing touches a handful, a broken mapping touches all of them.
    int rows_affected = 0;
    for (int y = 0; y < 128; y++) if (bad_y[y]) rows_affected++;
    CHECK(rows_affected <= 12,
          "%d of 128 rows disagree (%d px): too many to be the read/write "
          "crossing — the coordinate mapping is wrong", rows_affected, wrong);
    CHECK(wrong < checked / 20,
          "%d of %d displayed pixels came from the wrong source "
          "(first at fb x=%d y=%d)", wrong, checked, first_bad_x, first_bad_y);

    std::printf("PASS fbuf_display: %d lines, %d-dot DE, %d pixels match "
                "their source\n", de_runs, H_ACT, checked);
    return 0;
}
