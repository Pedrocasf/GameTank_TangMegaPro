// Harness for tang/sdram.sv: a behavioural 16-bit SDRAM on the pins, plus the
// two-clock plumbing the controller expects.
//
// The model is not just storage — it enforces the protocol, so a controller
// that reads without activating, precharges mid-burst, misses tRCD/tRP, or
// lets a refresh interval slip fails here rather than on a board where the
// only symptom is corrupt graphics.
//
// Clocking mirrors the hardware exactly: clk_sdram is 3x clk_bus off one PLL,
// phase-aligned, so a bus edge coincides with every third SDRAM edge.
//
// Edge convention (the thing to get right when reading this):
//   - the value presented on dq_in before an edge is what the DUT latches
//     at that edge;
//   - the command/address the DUT drove during the previous cycle is what
//     the chip samples at this edge.
// So a READ driven out of edge N is received by the chip at N+1, and with
// CL=2 its four words are latchable at N+3, N+4, N+5, N+6.

#pragma once

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <unordered_map>
#include <vector>

#include <verilated.h>
#include "Vsdram.h"
#include "vl_compat.h"

#ifndef CHECK
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
#endif

// Command encoding on {cs_n, ras_n, cas_n, we_n}
enum SdCmd {
    SD_NOP = 0b0111, SD_ACTIVE = 0b0011, SD_READ = 0b0101, SD_WRITE = 0b0100,
    SD_PRE = 0b0010, SD_REFRESH = 0b0001, SD_MRS = 0b0000
};

struct SdPins {
    uint8_t  cmd;          // {cs_n, ras_n, cas_n, we_n}
    uint8_t  ba;
    uint16_t a;
    uint8_t  dqm;
    uint16_t dq;
    bool     dq_oe;
};

class SdramChip {
public:
    static constexpr int BANKS = 4;
    static constexpr int CL    = 2;
    static constexpr int BL    = 4;

    // Sparse storage: the test only touches a handful of the 16M words.
    std::unordered_map<uint32_t, uint16_t> mem;

    int      activeRow[BANKS] = {-1, -1, -1, -1};
    uint64_t lastAct[BANKS]   = {0, 0, 0, 0};
    uint64_t lastPre[BANKS]   = {0, 0, 0, 0};

    bool     initialised = false;   // mode register loaded
    uint64_t lastRefresh = 0;
    // Refresh must not slip further than this. The DUT is built with a small
    // CLK_KHZ in this test so refreshes come often; the bound leaves room for
    // one in-flight transaction.
    uint64_t refreshBound = 400;

    // Scheduled read data, indexed by the edge at which the DUT latches it.
    struct Slot { bool valid = false; uint16_t data = 0; };
    static constexpr int SCHED = 32;
    Slot sched[SCHED];

    // In-progress write burst
    int      wrLeft = 0;
    uint32_t wrAddr = 0;

    uint64_t refreshes = 0;
    uint64_t reads = 0, writes = 0, activates = 0;

    // Set SDRAM_TRACE=1 to dump every command the controller issues.
    bool trace = std::getenv("SDRAM_TRACE") != nullptr;

    static const char* cmdName(uint8_t c) {
        switch (c) {
        case SD_NOP: return "NOP";     case SD_ACTIVE:  return "ACTIVE";
        case SD_READ: return "READ";   case SD_WRITE:   return "WRITE";
        case SD_PRE: return "PRE";     case SD_REFRESH: return "REFRESH";
        case SD_MRS: return "MRS";     default:         return "?";
        }
    }

    static uint32_t cell(int bank, int row, int col) {
        return ((uint32_t)bank << 22) | ((uint32_t)row << 9) | (uint32_t)col;
    }

    uint16_t peek(int bank, int row, int col) const {
        auto it = mem.find(cell(bank, row, col));
        return it == mem.end() ? 0 : it->second;
    }

    // Value the DUT latches at this edge (Z reads back as a recognisable
    // pattern so a mis-timed capture shows up as garbage, not as zero).
    uint16_t dqAtEdge(uint64_t e) {
        Slot& s = sched[e % SCHED];
        return s.valid ? s.data : 0xBAAD;
    }

    void releaseEdge(uint64_t e) { sched[e % SCHED] = Slot{}; }

    void edge(const SdPins& p, uint64_t e) {
        // ---- write burst in progress consumes this cycle's data ----------
        if (wrLeft > 0 && p.cmd != SD_WRITE) {
            applyWriteWord(p, e);
        }

        if ((p.cmd & 0b1000) != 0) return;   // cs_n high: deselect

        if (trace && p.cmd != SD_NOP)
            std::printf("[%5llu] %-7s ba=%d a=%04x dqm=%x dq=%04x\n",
                        (unsigned long long)e, cmdName(p.cmd), p.ba, p.a,
                        p.dqm, p.dq);

        switch (p.cmd) {
        case SD_NOP:
            break;

        case SD_MRS: {
            CHECK(!anyRowOpen(), "MRS at %llu with a row still open",
                  (unsigned long long)e);
            int bl = p.a & 7, bt = (p.a >> 3) & 1, cl = (p.a >> 4) & 7;
            CHECK(bl == 2, "mode register burst length field %d (want 2 = BL4)", bl);
            CHECK(bt == 0, "mode register burst type %d (want sequential)", bt);
            CHECK(cl == CL, "mode register CAS latency %d (want %d)", cl, CL);
            initialised = true;
            lastRefresh = e;
            break;
        }

        case SD_REFRESH:
            CHECK(!anyRowOpen(), "AUTO REFRESH at %llu with a row still open",
                  (unsigned long long)e);
            lastRefresh = e;
            refreshes++;
            break;

        case SD_PRE:
            if (p.a & 0x400) {
                for (int b = 0; b < BANKS; b++)
                    if (activeRow[b] >= 0) { activeRow[b] = -1; lastPre[b] = e; }
            }
            else {
                activeRow[p.ba] = -1;
                lastPre[p.ba]   = e;
            }
            break;

        case SD_ACTIVE:
            CHECK(initialised, "ACTIVE at %llu before the mode register was set",
                  (unsigned long long)e);
            CHECK(activeRow[p.ba] < 0,
                  "ACTIVE on bank %d at %llu while row %d is still open",
                  p.ba, (unsigned long long)e, activeRow[p.ba]);
            CHECK(e - lastPre[p.ba] >= 2,
                  "tRP violated on bank %d: ACTIVE %llu cycles after PRECHARGE",
                  p.ba, (unsigned long long)(e - lastPre[p.ba]));
            activeRow[p.ba] = p.a & 0x1FFF;
            lastAct[p.ba]   = e;
            activates++;
            break;

        case SD_READ: {
            CHECK(activeRow[p.ba] >= 0, "READ on bank %d at %llu with no open row",
                  p.ba, (unsigned long long)e);
            CHECK(e - lastAct[p.ba] >= 2,
                  "tRCD violated on bank %d: READ %llu cycles after ACTIVE",
                  p.ba, (unsigned long long)(e - lastAct[p.ba]));
            int col = p.a & 0x1FF;
            for (int j = 0; j < BL; j++) {
                // BL4 sequential wraps inside the aligned four-word block.
                int c = (col & ~3) | ((col + j) & 3);
                uint64_t at = e + CL + j;
                Slot& s = sched[at % SCHED];
                CHECK(!s.valid, "read data collision at edge %llu — a burst was "
                      "overrun by the next READ", (unsigned long long)at);
                s.valid = true;
                s.data  = peek(p.ba, activeRow[p.ba], c);
            }
            CHECK((p.a & 0x400) == 0, "auto-precharge READ is not modelled");
            reads++;
            break;
        }

        case SD_WRITE:
            CHECK(activeRow[p.ba] >= 0, "WRITE on bank %d at %llu with no open row",
                  p.ba, (unsigned long long)e);
            CHECK(e - lastAct[p.ba] >= 2,
                  "tRCD violated on bank %d: WRITE %llu cycles after ACTIVE",
                  p.ba, (unsigned long long)(e - lastAct[p.ba]));
            CHECK((p.a & 0x400) == 0, "auto-precharge WRITE is not modelled");
            wrAddr = cell(p.ba, activeRow[p.ba], p.a & 0x1FF);
            wrLeft = BL;
            applyWriteWord(p, e);      // word 0 rides with the command
            writes++;
            break;

        default:
            CHECK(false, "unknown command %x at edge %llu", p.cmd,
                  (unsigned long long)e);
        }

        if (initialised)
            CHECK(e - lastRefresh <= refreshBound,
                  "refresh slipped: %llu cycles since the last AUTO REFRESH",
                  (unsigned long long)(e - lastRefresh));
    }

private:
    bool anyRowOpen() const {
        for (int b = 0; b < BANKS; b++) if (activeRow[b] >= 0) return true;
        return false;
    }

    void applyWriteWord(const SdPins& p, uint64_t e) {
        (void)e;
        CHECK(p.dq_oe, "write burst with the data bus not driven");
        uint32_t base = wrAddr & ~3u;
        uint32_t off  = (wrAddr + (BL - wrLeft)) & 3u;
        uint32_t a    = base | off;
        uint16_t old  = mem.count(a) ? mem[a] : 0;
        uint16_t val  = old;
        if (!(p.dqm & 1)) val = (uint16_t)((val & 0xFF00) | (p.dq & 0x00FF));
        if (!(p.dqm & 2)) val = (uint16_t)((val & 0x00FF) | (p.dq & 0xFF00));
        if (trace)
            std::printf("        write cell %08x <= %04x (dqm %x, was %04x)\n",
                        a, val, p.dqm, old);
        mem[a] = val;
        wrLeft--;
    }
};

class SdramSim {
public:
    Vsdram      top;
    SdramChip   chip;
    uint64_t    sdcycle = 0;
    std::vector<uint64_t> beats;    // collected from dout_ready pulses

    SdramSim() {
        top.clk_bus = 0;
        top.clk_sdram = 0;
        top.reset = 1;
        top.rd = top.we = 0;
        top.addr = 0;
        top.din = 0;
        top.be = 0xFF;
        top.burstcnt = 1;
        top.eval();
    }

    ~SdramSim() { top.final(); }

    // One SDRAM clock. A bus edge lands on every third one, matching the 3:1
    // PLL relationship.
    void sdramEdge() {
        top.dq_in = chip.dqAtEdge(sdcycle);

        SdPins p;
        p.cmd   = (uint8_t)((top.sd_cs_n << 3) | (top.sd_ras_n << 2) |
                            (top.sd_cas_n << 1) | top.sd_we_n);
        p.ba    = top.sd_ba;
        p.a     = top.sd_a;
        p.dqm   = top.sd_dqm;
        p.dq    = top.dq_out;
        p.dq_oe = top.dq_oe;

        bool busEdge = (sdcycle % 3) == 0;

        top.clk_sdram = 1;
        top.clk_bus   = busEdge ? 1 : 0;
        top.eval();
        top.clk_sdram = 0;
        top.clk_bus   = 0;
        top.eval();

        if (busEdge && top.dout_ready) beats.push_back(top.dout);

        // While the controller is held in reset its command pins mean
        // nothing (power-up state decodes as MRS), exactly as on a board
        // where the part is still in its power-up pause.
        if (!top.reset) chip.edge(p, sdcycle);
        chip.releaseEdge(sdcycle);
        sdcycle++;
    }

    void run(int sdramCycles) { for (int i = 0; i < sdramCycles; i++) sdramEdge(); }

    // Exactly one bus edge per call. The naive "run until the phase wraps"
    // version can finish without ever producing one, depending on where the
    // SDRAM phase happens to sit — which silently breaks any handshake timed
    // against it.
    void busTick() {
        while (sdcycle % 3 != 0) sdramEdge();   // align to the bus edge
        sdramEdge();                            // the bus edge itself
        while (sdcycle % 3 != 0) sdramEdge();   // finish the bus period
    }

    void reset() {
        top.reset = 1;
        run(12);
        top.reset = 0;
    }

    void waitInit(int cap = 200000) {
        for (int i = 0; i < cap && !top.init_done; i++) sdramEdge();
        CHECK(top.init_done, "init never completed within %d cycles", cap);
        CHECK(chip.initialised, "controller reports init_done but the chip "
                                "never saw a mode-register load");
    }

    // Issue one command the way rtl/ddr_mux.sv does: hold it until the bus
    // edge at which busy is low, which is the acceptance.
    void issue(bool isWrite, uint32_t wordAddr, uint64_t data, uint8_t be,
               int burst) {
        top.rd       = isWrite ? 0 : 1;
        top.we       = isWrite ? 1 : 0;
        top.addr     = wordAddr;
        top.din      = data;
        top.be       = be;
        top.burstcnt = (uint8_t)burst;

        for (int guard = 0; guard < 100000; guard++) {
            bool preBusy = top.busy;
            busTick();
            if (!preBusy) {
                top.rd = top.we = 0;
                return;
            }
        }
        CHECK(false, "command never accepted (busy stuck)");
    }

    void write64(uint32_t wordAddr, uint64_t data, uint8_t be = 0xFF) {
        issue(true, wordAddr, data, be, 1);
        for (int guard = 0; guard < 100000; guard++) {
            if (!top.busy) return;
            busTick();
        }
        CHECK(false, "write never completed");
    }

    std::vector<uint64_t> read64(uint32_t wordAddr, int burst = 1) {
        beats.clear();
        issue(false, wordAddr, 0, 0xFF, burst);
        for (int guard = 0; guard < 100000; guard++) {
            if ((int)beats.size() >= burst && !top.busy) break;
            busTick();
        }
        CHECK((int)beats.size() == burst,
              "expected %d beats, got %zu", burst, beats.size());
        return beats;
    }
};
