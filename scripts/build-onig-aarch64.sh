#!/usr/bin/env sh
# Build Oniguruma for aarch64 musl (the unkernel user-space architecture).
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:-"$root/aarch64-onig"}

sources="regparse regcomp regexec regenc regerror regext regsyntax regtrav
regversion st reggnu unicode unicode_unfold_key unicode_fold1_key
unicode_fold2_key unicode_fold3_key ascii utf8 utf16_be utf16_le utf32_be
utf32_le euc_jp euc_jp_prop sjis sjis_prop iso8859_1 iso8859_2 iso8859_3
iso8859_4 iso8859_5 iso8859_6 iso8859_7 iso8859_8 iso8859_9 iso8859_10
iso8859_11 iso8859_13 iso8859_14 iso8859_15 iso8859_16 euc_tw euc_kr big5
gb18030 koi8_r cp1251 onig_init"

mkdir -p "$out/obj"
for source in $sources; do
  zig cc -target aarch64-linux-musl -O2 \
    -I "$root/third_party/oniguruma" \
    -I "$root/third_party/oniguruma/src" \
    -I "$root/third_party/oniguruma-config-aarch64" \
    -c "$root/third_party/oniguruma/src/$source.c" \
    -o "$out/obj/$source.o"
done
zig ar rcs "$out/libonig.a" "$out"/obj/*.o
printf 'built %s\n' "$out/libonig.a"
