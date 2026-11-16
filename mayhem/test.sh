#!/usr/bin/env bash
#
# mayhem/test.sh — RUN solidity's own test suite (`soltest`, built by mayhem/build.sh with the
# project's normal flags). It never compiles.
#
# soltest is upstream's Boost.Test runner: unit tests of the libraries plus the file-based
# expectation tests under test/ (syntax tests, AST/ABI/NatSpec JSON, Yul optimizer and object
# compiler tests, assembly tests, ...), each comparing the compiler's output with the expectation
# stored next to the input. Two groups are left out because they need programs the image does not
# carry: the semantic tests execute compiled contracts in evmone, a shared library loaded at run
# time (--no-semantic-tests), and the SMTChecker tests call an SMT solver (--no-smt).
#
# Output: a CTRF summary (file + one `CTRF {...}` line on stdout); exit non-zero iff a test failed.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

RUNNER="$SRC/build-tests/test/soltest"
if [ ! -x "$RUNNER" ]; then
  echo "test.sh: $RUNNER is missing — mayhem/build.sh should have built it" >&2
  emit_ctrf boost-test 0 1
  exit 1
fi

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
# --report_level=short ends the run with Boost.Test's result summary, e.g.
#   Test module "SolidityTests" has passed with:
#     5123 test cases out of 5200 passed
#     77 test cases out of 5200 skipped
"$RUNNER" --color_output=no --report_level=short --log_level=error \
  -- --testpath "$SRC/test" --no-semantic-tests --no-smt >"$log" 2>&1
rc=$?
tail -n 40 "$log"

count() { sed -n -E "s/^[[:space:]]*([0-9]+) test cases? out of [0-9]+ $1\$/\1/p" "$log" | head -1; }
passed="$(count passed)"; failed="$(count failed)"; skipped="$(count skipped)"
: "${passed:=0}" "${failed:=0}" "${skipped:=0}"
# A run that died before printing its summary (crash, bad option) is a failure, not zero tests.
if [ "$rc" -ne 0 ] && [ "$failed" -eq 0 ]; then failed=1; fi
if [ "$passed" -eq 0 ] && [ "$failed" -eq 0 ]; then failed=1; fi
emit_ctrf boost-test "$passed" "$failed" "$skipped"
