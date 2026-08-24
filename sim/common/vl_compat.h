// Verilator compatibility shim, included by every harness.
//
// Verilator 5.05x still emits a reference to the legacy SystemC time hook
// from verilated.cpp even for a plain C++ testbench, so linking fails with
// "undefined reference to sc_time_stamp()". Defining it costs nothing on the
// builds that do not need it.
//
// Must not be `inline`: the reference comes from verilated.cpp, which never
// sees this header, so the symbol has to be emitted here.

#pragma once

double sc_time_stamp() { return 0; }
