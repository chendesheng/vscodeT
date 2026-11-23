#!/usr/bin/env sh
# Build the Oniguruma static library for 32-bit x86 musl.
#
# Used by the x86 CI build and the WebVM/CheerpX image. The native x86_64
# build keeps using the system libonig; this cross build uses the submodule and
# the ILP32 config in third_party/oniguruma-config.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:-"$root/i386-onig"}

sources="regparse regcomp regexec regenc regerror regext regsyntax regtrav
regversion st reggnu unicode unicode_unfold_key unicode_fold1_key
unicode_fold2_key unicode_fold3_key ascii utf8 utf16_be utf16_le utf32_be
utf32_le euc_jp euc_jp_prop sjis sjis_prop iso8859_1 iso8859_2 iso8859_3
iso8859_4 iso8859_5 iso8859_6 iso8859_7 iso8859_8 iso8859_9 iso8859_10
iso8859_11 iso8859_13 iso8859_14 iso8859_15 iso8859_16 euc_tw euc_kr big5
gb18030 koi8_r cp1251 onig_init"

mkdir -p "$out/obj"
for source in $sources; do
  zig cc -target x86-linux-musl -O2 \
    -I "$root/third_party/oniguruma" \
    -I "$root/third_party/oniguruma/src" \
    -I "$root/third_party/oniguruma-config" \
    -c "$root/third_party/oniguruma/src/$source.c" \
    -o "$out/obj/$source.o"
done
zig ar rcs "$out/libonig.a" "$out"/obj/*.o
printf 'built %s\n' "$out/libonig.a"
