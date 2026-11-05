#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }
# design-variants' check.mjs. Designers must reach exit 0 on it, so a check that
# stops firing lets a broken variant through silently.

dc_check() {  # dc_check <label> <0|1 passed> [detail]
  N=$((N+1))
  if [ "$2" = 1 ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n%s\n' "$1" "${3:-}"; fi
}

echo "design-variants check.mjs"
DC="$TMP/design-check"; mkdir -p "$DC"
CHECK="$HERE/../skills/design-variants/check.mjs"
fails() { node "$CHECK" "$1" | node -e 'for (const r of JSON.parse(require("fs").readFileSync(0))) console.log(r.fails.join("\n"))'; }

cat > "$DC/bad.html" <<'H'
<!doctype html><html><head><meta name="contrast-pairs" content="--fg/--bg --muted/--bg"><style>:root{--bg:#141b2a;--fg:#e8edf5;--muted:#4a5568}</style></head>
<body><button></button><a href="#"><svg></svg></a><input id="q"><img src="x.png"></body></html>
H
want='<html> has no lang
no <title>
no viewport meta
img without alt: <img src="x.png">
empty button with no aria-label: <button>
empty a with no aria-label: <a href="#">
input without label: <input id="q">
--muted/--bg in ":root": 2.29:1, needs 4.5:1'
got=$(fails "$DC/bad.html")
node "$CHECK" "$DC/bad.html" >/dev/null; rc=$?
dc_check "a broken page lists every failure, in order, and exits 1" \
  "$([ "$got" = "$want" ] && [ "$rc" = 1 ] && echo 1)" "exit $rc, got:
$got"

cat > "$DC/good.html" <<'H'
<!doctype html><html lang="en"><head><meta name="viewport" content="width=device-width"><title>T</title>
<meta name="contrast-pairs" content="--fg/--bg --line/--bg:3"><style>:root{--bg:#141b2a;--fg:#e8edf5;--line:#7a869a}</style></head>
<body><button aria-label="Locate"><svg></svg></button><label for="q">Search</label><input id="q"><input type="hidden" name="x"></body></html>
H
node "$CHECK" "$DC/good.html" >/dev/null; rc=$?
dc_check "a clean page exits 0 with no failures" \
  "$([ "$rc" = 0 ] && [ -z "$(fails "$DC/good.html")" ] && echo 1)" "exit $rc: $(fails "$DC/good.html")"

sed 's#</style>#@media (prefers-color-scheme: light){:root:not([data-theme="dark"]){--bg:\#ffffff;--fg:\#f0f0f0}}</style>#' \
  "$DC/good.html" > "$DC/light.html"
got=$(fails "$DC/light.html")
dc_check "the light block is checked too, inheriting tokens it does not redefine" \
  "$([ "$got" = '--fg/--bg in ":root:not([data-theme="dark"])": 1.14:1, needs 4.5:1' ] && echo 1)" "got:
$got"
