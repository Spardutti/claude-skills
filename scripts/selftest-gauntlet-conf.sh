#!/usr/bin/env bash
[ -n "${SELFTEST_SANDBOX:-}" ] || { echo "$(basename "$0"): run it through scripts/gauntlet-selftest.sh, never on its own" >&2; exit 1; }

echo "the gauntlet.conf the installer writes"
GC="$TMP/gconf"; rm -rf "$GC"; mkdir -p "$GC/.claude/hooks"
cp "$HERE/gate-config.sh" "$GC/.claude/hooks/"
LIB="$HERE/../cli/lib/gauntlet-conf.mjs"
gc_check() {  # gc_check <label> <want> <got>
  N=$((N+1))
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fi
}
gc_write() {  # gc_write <chosen as JSON> — prints the path written, or null
  node --input-type=module -e "
    import { readDefaults, writeGauntletConf } from '$LIB';
    const d = readDefaults('$GC/.claude/hooks');
    console.log(await writeGauntletConf('$GC', d, $1));"
}
gc_read() { bash -c '. "$1/.claude/hooks/gate-config.sh"; . "$1/.claude/gauntlet.conf"
  printf "%s;%s;%s;%s" "$GAUNTLET_MAX_LINES" "$GAUNTLET_KIND_FOLDERS" "${GAUNTLET_TEST-unset}" "${GAUNTLET_TYPECHECK-unset}"' _ "$GC"; }

gc_write "{ GAUNTLET_MAX_LINES: '300', GAUNTLET_KIND_FOLDERS: 'components|services', GAUNTLET_TEST: \"pnpm test -- --run 'it''s'\", GAUNTLET_TYPECHECK: '' }" >/dev/null
gc_check "the answers come back through the hook's own loader, quotes and all" \
  "300;components|services;pnpm test -- --run 'it''s';" "$(gc_read)"
gc_check "only the answers are set; every other setting is listed, commented out" \
  "GAUNTLET_KIND_FOLDERS GAUNTLET_MAX_LINES GAUNTLET_TEST GAUNTLET_TYPECHECK|11" \
  "$(grep -oE '^GAUNTLET_[A-Z_]+' "$GC/.claude/gauntlet.conf" | sort | tr '\n' ' ' | sed 's/ $//')|$(grep -cE '^#? ?GAUNTLET_' "$GC/.claude/gauntlet.conf")"

before=$(cat "$GC/.claude/gauntlet.conf")
gc_check "an existing gauntlet.conf is never overwritten" "null" "$(gc_write "{ GAUNTLET_MAX_LINES: '50' }")"
gc_check "and its content is unchanged" "$before" "$(cat "$GC/.claude/gauntlet.conf")"

rm "$GC/.claude/gauntlet.conf"
gc_write "{ GAUNTLET_MAX_LINES: '200', GAUNTLET_KIND_FOLDERS: 'components|hooks|api|queries|schemas|types|utils|stores|test' }" >/dev/null
gc_check "answers equal to the defaults are left commented, so a new default still reaches them" \
  "" "$(grep -E '^GAUNTLET_' "$GC/.claude/gauntlet.conf")"
gc_check "a kind-folder answer with commas becomes the hook's | list" "components|services|api" \
  "$(node --input-type=module -e "import { toKindFolders } from '$LIB'; console.log(toKindFolders('components, services,api'))")"
