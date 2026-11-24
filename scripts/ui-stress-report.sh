#!/usr/bin/env sh
# Run the UI stress tests and benchmarks and assemble one markdown report.
#
#   scripts/ui-stress-report.sh [output-directory]
#
# The default output is `zig-out/ui-stress-report/`; it is disposable build
# output, not a committed artifact. CI passes a runner-temp directory and
# uploads the directory as an artifact. The report contains the filtered stress
# test summary, ReleaseFast timing medians, and an allocation table.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:-"$root/zig-out/ui-stress-report"}

# The report path travels through the benchmark's space-separated
# `-Dbench-args`, so keep it free of spaces (runner temp and zig-out are).
case "$out" in
    *" "*) echo "output directory must not contain spaces: $out" >&2; exit 2 ;;
esac

mkdir -p "$out"

cd "$root/ui"

echo "ui-stress-report: running stress tests"
zig build stress --summary all >"$out/stress-tests.txt" 2>&1

echo "ui-stress-report: running timing benchmark"
zig build bench -Doptimize=ReleaseFast \
    -Dbench-args="--runs 5 --iterations 20 --markdown --report $out/timings.md" \
    >"$out/timings.stdout" 2>&1

echo "ui-stress-report: running allocation benchmark"
zig build bench -Doptimize=ReleaseFast \
    -Dbench-args="--allocated --runs 3 --iterations 10 --markdown --report $out/allocations.md" \
    >"$out/allocations.stdout" 2>&1

{
    echo "# UI stress report"
    echo
    echo "## Stress tests"
    echo '```text'
    cat "$out/stress-tests.txt"
    echo '```'
    echo
    echo "## Timings"
    cat "$out/timings.md"
    echo
    echo "## Allocations"
    cat "$out/allocations.md"
} >"$out/report.md"

printf 'ui-stress-report: wrote %s\n' "$out/report.md"
