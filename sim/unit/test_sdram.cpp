// Directed test for tang/sdram.sv against the behavioural chip model in
// sim/common/sdram_harness.h. The model enforces the protocol (activate before
// access, tRCD/tRP, no precharge mid-burst, refresh cadence, mode register
// contents), so most failures report themselves; this file adds the data-path
// and client-protocol checks on top.
//
// The DUT is built with a small CLK_KHZ (see sim/Makefile) so the 200 us
// power-up and the refresh interval are short enough to sit inside a unit
// test — and so refreshes land often enough to interleave with traffic.

#include "sdram_harness.h"

// Beat addresses are 64-bit word indices above the base the core uses.
static constexpr uint32_t BASE = 0x0600'0000;

// One beat is 4 columns, one row is 128 beats, one bank is 8192 rows.
static constexpr uint32_t BEATS_PER_ROW  = 128;
static constexpr uint32_t BEATS_PER_BANK = BEATS_PER_ROW * 8192;

static uint64_t pattern(uint32_t beat) {
    return 0x0123'4567'89AB'CDEFull ^ ((uint64_t)beat * 0x1000'0001'0000'0011ull);
}

int main() {
    SdramSim sim;
    sim.reset();
    sim.waitInit();

    // ---- 1. single beat round trip ---------------------------------------
    sim.write64(BASE + 0, pattern(0));
    auto b = sim.read64(BASE + 0);
    CHECK(b[0] == pattern(0), "beat 0 read back %016llx, want %016llx",
          (unsigned long long)b[0], (unsigned long long)pattern(0));

    // ---- 2. several beats, same row --------------------------------------
    for (uint32_t i = 1; i < 8; i++) sim.write64(BASE + i, pattern(i));
    for (uint32_t i = 1; i < 8; i++) {
        auto r = sim.read64(BASE + i);
        CHECK(r[0] == pattern(i), "beat %u read back %016llx, want %016llx",
              i, (unsigned long long)r[0], (unsigned long long)pattern(i));
    }

    // ---- 3. burst read returns consecutive beats in order ----------------
    auto burst = sim.read64(BASE + 0, 8);
    for (uint32_t i = 0; i < 8; i++)
        CHECK(burst[i] == pattern(i), "burst beat %u = %016llx, want %016llx",
              i, (unsigned long long)burst[i], (unsigned long long)pattern(i));

    // ---- 4. byte enables leave the masked bytes alone --------------------
    sim.write64(BASE + 20, 0xFFFF'FFFF'FFFF'FFFFull);
    sim.write64(BASE + 20, 0x0000'0000'0000'0000ull, 0b0011'0011);
    auto masked = sim.read64(BASE + 20);
    CHECK(masked[0] == 0xFFFF'0000'FFFF'0000ull,
          "byte enables gave %016llx, want FFFF0000FFFF0000",
          (unsigned long long)masked[0]);

    // ---- 5. a burst that crosses a row boundary --------------------------
    // Start three beats before the end of row 0 and read six.
    const uint32_t cross = BEATS_PER_ROW - 3;
    for (uint32_t i = 0; i < 6; i++) sim.write64(BASE + cross + i, pattern(cross + i));
    auto xb = sim.read64(BASE + cross, 6);
    for (uint32_t i = 0; i < 6; i++)
        CHECK(xb[i] == pattern(cross + i),
              "row-crossing beat %u = %016llx, want %016llx", i,
              (unsigned long long)xb[i], (unsigned long long)pattern(cross + i));

    // ---- 6. different rows and banks -------------------------------------
    const uint32_t elsewhereRow  = BASE + BEATS_PER_ROW * 5 + 9;
    const uint32_t elsewhereBank = BASE + BEATS_PER_BANK * 2 + 77;
    sim.write64(elsewhereRow,  0xDEAD'BEEF'CAFE'F00Dull);
    sim.write64(elsewhereBank, 0x1122'3344'5566'7788ull);
    // Re-read the first beat in between, forcing rows to close and reopen.
    CHECK(sim.read64(BASE + 0)[0] == pattern(0), "row 0 disturbed by other rows");
    CHECK(sim.read64(elsewhereRow)[0] == 0xDEAD'BEEF'CAFE'F00Dull,
          "other-row beat corrupted");
    CHECK(sim.read64(elsewhereBank)[0] == 0x1122'3344'5566'7788ull,
          "other-bank beat corrupted");

    // ---- 7. client protocol: busy brackets the transaction ---------------
    // busy must be low before acceptance and high immediately after, so a
    // client that holds its command cannot have it taken twice.
    CHECK(!sim.top.busy, "controller busy while idle");
    sim.top.rd       = 1;
    sim.top.addr     = BASE + 0;
    sim.top.burstcnt = 4;
    sim.busTick();                       // acceptance edge
    sim.top.rd = 0;
    CHECK(sim.top.busy, "busy did not rise on acceptance");
    int seen = 0;
    for (int i = 0; i < 10000 && (seen < 4 || sim.top.busy); i++) {
        sim.busTick();
        if (sim.top.dout_ready) seen++;
    }
    CHECK(seen == 4, "expected exactly 4 dout_ready pulses, saw %d", seen);
    CHECK(!sim.top.busy, "busy never fell after the burst");

    // ---- 8. refresh actually happened ------------------------------------
    CHECK(sim.chip.refreshes > 8, "only %llu refreshes over the whole run",
          (unsigned long long)sim.chip.refreshes);

    std::printf("PASS sdram: %llu reads, %llu writes, %llu activates, "
                "%llu refreshes\n",
                (unsigned long long)sim.chip.reads,
                (unsigned long long)sim.chip.writes,
                (unsigned long long)sim.chip.activates,
                (unsigned long long)sim.chip.refreshes);
    return 0;
}
