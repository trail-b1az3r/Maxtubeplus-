#!/usr/bin/env bash
# Static checks for MaxTubePlus. Run locally or in CI (Linux or macOS).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
status=0
err() { echo "::error::$*"; status=1; }

echo "== Core unit tests"
Tests/run_tests.sh || err "core unit tests failed"

echo "== IPA tool tests"
python3 -I Tests/test_ipa_tool.py || err "ipa_tool tests failed"
python3 -I Tests/test_fetch_ipa.py || err "fetch_ipa tests failed"

echo "== Logos balance (%hook/%group vs %end)"
for f in $(find MaxTubePlus -name '*.x'); do
  opens=$(grep -cE '^\s*%(hook|group)\b' "$f" || true)
  ends=$(grep -cE '^\s*%end\b' "$f" || true)
  [ "$opens" = "$ends" ] || err "$f: $opens %hook/%group but $ends %end"
done

echo "== Makefile lists every source file"
listed=$(sed -n '/_FILES =/,/^$/p' MaxTubePlus/Makefile | tr ' \\\t' '\n\n\n' | grep -E '\.(x|m|c)$' | sort)
actual=$(cd MaxTubePlus && find . -name '*.x' -o -name '*.m' -o -name '*.c' | grep -v '/\.theos/' | sed 's|^\./||' | sort)
missing=$(comm -13 <(echo "$listed") <(echo "$actual"))
ghost=$(comm -23 <(echo "$listed") <(echo "$actual"))
[ -z "$missing" ] || err "not in Makefile: $missing"
[ -z "$ghost" ] || err "in Makefile but missing: $ghost"

echo "== Every module installer is defined and called"
for fn in $(grep -oE 'MTPInstall[A-Za-z]+' MaxTubePlus/Tweak.x | sort -u); do
  grep -rqE "^void $fn\(void\)" MaxTubePlus --include='*.x' --include='*.m' || err "$fn declared in Tweak.x but not defined"
done
for fn in $(grep -rhoE '^void MTPInstall[A-Za-z]+' MaxTubePlus --include='*.x' --include='*.m' | awk '{print $2}' | sort -u); do
  grep -q "$fn" MaxTubePlus/Tweak.x || err "$fn defined but never called from Tweak.x"
done

echo "== No signing material or app binaries committed"
bad=$(git ls-files | grep -iE '\.(p12|mobileprovision|cer|pem|key|ipa|dylib)$' || true)
[ -z "$bad" ] || err "forbidden files tracked: $bad"
if git grep -qE 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY' -- . ':!scripts/static_checks.sh'; then err "private key material found"; fi

echo "== Workflow YAML parses"
if python3 -c 'import yaml' 2>/dev/null; then
  for f in .github/workflows/*.yml; do python3 -c "import sys,yaml; yaml.safe_load(open(sys.argv[1]))" "$f" || err "invalid YAML: $f"; done
else
  echo "(PyYAML not installed; skipped)"
fi

[ $status -eq 0 ] && echo "All static checks passed"
exit $status
