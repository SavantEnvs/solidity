// Turns LeakSanitizer off at build time for the fuzz binaries (ASan and UBSan stay fully active).
// Leaks are not the defect class these targets are fuzzed for. Linked by mayhem/build.sh.
extern "C" int __lsan_is_turned_off() { return 1; }
