#!/bin/sh
# Check an ELF binary is loadable on the Xiaomi LX06 firmware:
#   NEEDED libs within an allow-list, GLIBC_ <= 2.25, GLIBCXX_ <= 3.4.22, CXXABI <= 1.3.10.
# Usage: tools/check_abi.sh path/to/mico-agent [readelf]
set -eu
BIN=${1:?usage: $0 binary [readelf]}
READELF=${2:-${READELF:-readelf}}
ALLOWED="libc.so.6 libm.so.6 libstdc++.so.6 libgcc_s.so.1 libcurl.so.4 libdl.so.2 libpthread.so.0 ld-linux-armhf.so.3"
fail=0

needed=$($READELF -d "$BIN" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p')
echo "NEEDED:"; for n in $needed; do echo "  $n"; done
for n in $needed; do
    case " $ALLOWED " in *" $n "*) ;; *) echo "FAIL: disallowed NEEDED $n"; fail=1;; esac
done

# max version of a symbol-version family, from .gnu.version_r
maxver() {
    $READELF -V "$BIN" | grep -o "Name: $1[0-9.]*" | sed "s/Name: $1//" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1
}
# verle A B: true if version A <= B
verle() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)" = "$1" ]; }

check() { # family limit
    v=$(maxver "$1")
    if [ -z "$v" ]; then echo "$1: (none)"; return; fi
    if verle "$v" "$2"; then echo "$1$v <= $2 OK"; else echo "FAIL: $1$v > $2"; fail=1; fi
}
check GLIBC_ 2.25
check GLIBCXX_ 3.4.22
check CXXABI_ 1.3.10

[ $fail -eq 0 ] && echo "ABI check passed" || echo "ABI check FAILED"
exit $fail
