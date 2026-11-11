#!/usr/bin/env bash
# Produces a standalone MaxTubePlus.dylib for injection with other tools
# (Feather, ESign, Sideloadly, TrollFools, cyan, jailbreak package managers).
#
# Usage: scripts/make_dylib.sh INPUT OUTPUT [--linkage rpath|rootful|rootless]
#   INPUT    a MaxTubePlus .deb or a built MaxTubePlus.dylib
#   OUTPUT   path of the dylib to write
#   --linkage install name (and, for older builds, the Substrate path):
#     rpath    (default) @rpath/MaxTubePlus.dylib — for sideloading
#     rootful  /Library/MobileSubstrate/DynamicLibraries/MaxTubePlus.dylib
#     rootless /var/jb/Library/MobileSubstrate/DynamicLibraries/MaxTubePlus.dylib
#   MaxTubePlus hooks with the Objective-C runtime only and does not link
#   Cydia Substrate, so it needs no Substrate/ElleKit framework. If an older
#   build still references Substrate, that reference is rewritten to match.
#
# Needs otool, install_name_tool and ldid (from PATH or $THEOS's toolchain),
# plus dpkg-deb when INPUT is a .deb.
set -euo pipefail

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 2 ] || usage
INPUT="$1"; OUTPUT="$2"; shift 2
LINKAGE=rpath
while [ $# -gt 0 ]; do
  case "$1" in
    --linkage) LINKAGE="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

fail() { echo "::error::$*" >&2; exit 1; }

tool() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return; fi
  for dir in "${THEOS:-}/toolchain/linux/iphone/bin" "${THEOS:-}/toolchain/mac/iphone/bin"; do
    [ -x "$dir/$name" ] && { echo "$dir/$name"; return; }
  done
  fail "$name not found (install it or set THEOS)"
}
OTOOL=$(tool otool)
INT=$(tool install_name_tool)
LDID=$(tool ldid)

case "$LINKAGE" in
  rpath)    SUBSTRATE="@rpath/CydiaSubstrate.framework/CydiaSubstrate"; INSTALL_NAME="@rpath/MaxTubePlus.dylib" ;;
  rootful)  SUBSTRATE="/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"; INSTALL_NAME="/Library/MobileSubstrate/DynamicLibraries/MaxTubePlus.dylib" ;;
  rootless) SUBSTRATE="/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"; INSTALL_NAME="/var/jb/Library/MobileSubstrate/DynamicLibraries/MaxTubePlus.dylib" ;;
  *) fail "unknown linkage '$LINKAGE' (use rpath, rootful or rootless)" ;;
esac

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

case "$INPUT" in
  *.deb)
    command -v dpkg-deb >/dev/null || fail "dpkg-deb is required to read $INPUT"
    dpkg-deb -x "$INPUT" "$WORK/deb"
    SRC=$(find "$WORK/deb" -name 'MaxTubePlus.dylib' -type f | head -n1)
    [ -n "$SRC" ] || fail "MaxTubePlus.dylib not found inside $INPUT"
    ;;
  *.dylib) SRC="$INPUT" ;;
  *) fail "INPUT must be a .deb or .dylib" ;;
esac

cp "$SRC" "$WORK/MaxTubePlus.dylib"
DYLIB="$WORK/MaxTubePlus.dylib"

# Rewrite whatever Substrate reference the build produced.
CURRENT=$("$OTOOL" -L "$DYLIB" | sed '1,2d' | awk '/CydiaSubstrate|libsubstrate|ellekit/ {print $1}' | head -n1)
if [ -n "$CURRENT" ]; then
  [ "$CURRENT" = "$SUBSTRATE" ] || "$INT" -change "$CURRENT" "$SUBSTRATE" "$DYLIB"
fi
"$INT" -id "$INSTALL_NAME" "$DYLIB"

# install_name_tool invalidates the signature; re-sign ad hoc (the injector
# or your signing service re-signs with your certificate).
"$LDID" -S "$DYLIB"

# Verify the result instead of trusting the tools.
LINKS=$("$OTOOL" -L "$DYLIB")
if [ -n "$CURRENT" ]; then echo "$LINKS" | grep -qF "$SUBSTRATE" || fail "substrate path was not rewritten"; fi
# Every non-system dependency must be something iOS provides; anything else
# would make dyld abort YouTube at launch.
UNEXPECTED=$(echo "$LINKS" | sed '1,2d' | awk '{print $1}' | grep -vE '^(/System/Library/|/usr/lib/)' | grep -vF "$SUBSTRATE" || true)
[ -z "$UNEXPECTED" ] || fail "unexpected load-time dependencies: $UNEXPECTED"
echo "$LINKS" | sed -n '2p' | grep -qF "$INSTALL_NAME" || fail "install name was not set"
"$OTOOL" -hv "$DYLIB" | grep -q 'ARM64' || fail "output is not an arm64 dylib"
"$LDID" -h "$DYLIB" >/dev/null 2>&1 || fail "output is not code-signed"

mkdir -p "$(dirname "$OUTPUT")"
cp "$DYLIB" "$OUTPUT"
echo "Created $OUTPUT ($LINKAGE linkage, $(wc -c < "$OUTPUT" | tr -d ' ') bytes)"
echo "$LINKS" | sed '1d' | sed 's/^/  /'
