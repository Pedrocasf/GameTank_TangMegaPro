// Directed test for tang/tmds_encoder.sv.
//
// The encoder is the one block in the Tang video path with no observable
// output short of a working monitor, so it is checked by decoding: every
// symbol it emits is run back through the inverse of DVI 1.0 §3.2.2 and
// compared with the byte that went in. That catches the failure modes a
// display just shows as "no signal" — wrong XOR/XNOR sense, a mis-built
// inversion bit, or a disparity counter that walks away.
//
// Also checked: the four control tokens during blanking, and that the
// running disparity stays inside the bound the standard guarantees.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include <verilated.h>
#include "Vtmds_encoder.h"
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

static Vtmds_encoder top;

static uint16_t step(uint8_t din, uint8_t ctrl, bool de) {
    top.din  = din;
    top.ctrl = ctrl;
    top.de   = de;
    top.clk  = 1; top.eval();
    top.clk  = 0; top.eval();
    return (uint16_t)top.dout;
}

// Inverse of the transition-minimised, DC-balanced encoding.
static uint8_t decode(uint16_t q) {
    uint8_t qm[9];
    for (int i = 0; i < 8; i++) {
        int bit = (q >> i) & 1;
        if (q & (1 << 9)) bit ^= 1;          // bit 9: the byte was inverted
        qm[i] = (uint8_t)bit;
    }
    qm[8] = (uint8_t)((q >> 8) & 1);         // bit 8: XOR (1) or XNOR (0)

    uint8_t d = 0;
    d |= qm[0];
    for (int i = 1; i < 8; i++) {
        int bit = qm[8] ? (qm[i] ^ qm[i - 1]) : !(qm[i] ^ qm[i - 1]);
        d |= (uint8_t)(bit << i);
    }
    return d;
}

static int ones(uint16_t q) {
    int n = 0;
    for (int i = 0; i < 10; i++) n += (q >> i) & 1;
    return n;
}

int main() {
    // Settle once before the first edge: Verilator 5 treats the very first
    // eval() as initialisation, so a model clocked straight from the
    // constructor misses its first posedge.
    top.clk = 0;
    top.eval();

    // ---- control tokens --------------------------------------------------
    static const uint16_t TOKEN[4] = {0x354, 0x0AB, 0x154, 0x2AB};
    for (int c = 0; c < 4; c++) {
        uint16_t q = step(0x00, (uint8_t)c, false);
        CHECK(q == TOKEN[c], "ctrl %d token %03x, want %03x", c, q, TOKEN[c]);
    }

    // ---- every byte survives a round trip --------------------------------
    // Run the whole range twice: the second pass starts from whatever
    // disparity the first left behind, so both polarity choices get taken.
    for (int pass = 0; pass < 2; pass++) {
        for (int v = 0; v < 256; v++) {
            uint16_t q = step((uint8_t)v, 0, true);
            uint8_t  d = decode(q);
            CHECK(d == v, "pass %d: byte %02x encoded %03x decoded %02x",
                  pass, v, q, d);
        }
    }

    // ---- disparity stays bounded ----------------------------------------
    // The encoder exists to keep the link DC balanced; an unbounded counter
    // is invisible in a round-trip check but fatal on real hardware.
    int  disparity = 0, worst = 0;
    uint32_t rng = 12345;
    step(0, 0, false);                        // reset the running disparity
    for (int i = 0; i < 20000; i++) {
        rng = rng * 1664525u + 1013904223u;
        uint8_t v = (uint8_t)(rng >> 16);
        uint16_t q = step(v, 0, true);
        CHECK(decode(q) == v, "random byte %02x round trip", v);
        disparity += 2 * ones(q) - 10;
        if (std::abs(disparity) > std::abs(worst)) worst = disparity;
        CHECK(std::abs(disparity) <= 10,
              "running disparity ran away to %d after %d symbols", disparity, i);
    }

    std::printf("PASS tmds_encoder: 512 round trips + 20000 random, "
                "4 control tokens, worst disparity %d\n", worst);
    return 0;
}
