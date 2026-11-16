#!/usr/bin/env bash
#
# mayhem/build.sh — build solidity's fuzz targets and its test suite.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem, and again, offline, every
# time a patch is graded. The base image (ghcr.io/savantenvs/base) exports the build contract:
#   CC, CXX, SANITIZER_FLAGS (ASan + UBSan, halting), SRC=/mayhem
#
# What it builds:
#   build-fuzz/   upstream's own fuzzing binary `solfuzzer` (test/tools/afl_fuzzer.cpp, "for use with
#                 AFL") and the `solc` command-line compiler, both compiled with afl-clang-fast plus
#                 $SANITIZER_FLAGS and $DEBUG_FLAGS. Upstream chose AFL for its in-tree harness, so the
#                 targets stay AFL targets (Mayhemfile `afl: true`); an AFL binary is its own
#                 reproducer, so there are no -standalone binaries.
#   build-tests/  `soltest`, upstream's Boost.Test suite, with the project's normal flags
#                 (mayhem/test.sh only runs it).
# Both directories match upstream's `/build*/` .gitignore rule. Nothing is downloaded: Boost comes
# from apt (mayhem/Dockerfile) and fmt / nlohmann-json / range-v3 are the repo's own submodules.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# SANITIZER_FLAGS uses `=` (no colon) on purpose: an explicit EMPTY value builds with no sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DWARF must be < 4 for Mayhem's triage; clang-19's plain -g emits DWARF 5.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default; appended to the TEST build only.
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Options shared by both builds.
#   PEDANTIC=OFF  upstream's -Werror; a new compiler warning must not break the weekly sync build.
#   CCACHE=OFF    upstream's cmake/EthCcache.cmake launches any `ccache` it finds on PATH by itself;
#                 the compile cache is the image's and the grader's business, not the build's.
COMMON_OPTS=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DPEDANTIC=OFF -DCCACHE=OFF -DTESTS=ON)

# ---- 1) the fuzz build: AFL instrumentation + sanitizers + DWARF 3 -------------------------------
FUZZ_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
mkdir -p build-fuzz
FUZZ_LINK=""
case " $SANITIZER_FLAGS " in
  *address*)
    # Leak detection off at build time (ASan and UBSan stay on): mayhem/lsan_off.cc is linked into
    # every fuzz executable. Upstream's CMake targets are not edited, so the object rides in on the
    # link line.
    $CXX $FUZZ_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o build-fuzz/lsan_off.o
    FUZZ_LINK="$SRC/build-fuzz/lsan_off.o"
    ;;
esac
# CMake takes the compiler from $CC/$CXX on the first configure and keeps it in its cache after.
CC=afl-clang-fast CXX=afl-clang-fast++ cmake -S . -B build-fuzz "${COMMON_OPTS[@]}" \
  -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$FUZZ_LINK"
cmake --build build-fuzz -j"$MAYHEM_JOBS" --target solfuzzer solc

# ---- 2) the test suite: the project's normal flags -----------------------------------------------
cmake -S . -B build-tests "${COMMON_OPTS[@]}" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS"
cmake --build build-tests -j"$MAYHEM_JOBS" --target soltest

ls -l build-fuzz/test/tools/solfuzzer build-fuzz/solc/solc build-tests/test/soltest
