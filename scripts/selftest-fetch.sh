#!/usr/bin/env bash
# Cases for the CLI's GitHub fetching. Sourced by gauntlet-selftest.sh, so it
# shares that script's $HERE, $TMP, $N, $PASS and $FAIL rather than counting
# its own.

# ------------------------------------------------- which headers reach which host
# raw.githubusercontent.com is not the API and does not take an API token: sent
# one it answers 503, while the same URL without the header returns 200. The CLI
# passed its API headers to every raw fetch, so a machine with `gh auth token`
# set lost most skill files to "Failed to fetch ..., skipping" and installed a
# partial set, while a machine without gh worked fine.
#
# Asserting that files arrived would not catch it — the CLI "succeeds" by
# skipping. This intercepts fetch and asserts the header list per host, which is
# the thing that was wrong.
echo "github fetch headers"
newrepo cli_headers
node -e "
  const calls = [];
  globalThis.fetch = async (url, opts = {}) => {
    const u = String(url);
    calls.push([new URL(u).host, (opts.headers || {}).Authorization ? 'auth' : 'none']);
    const api = u.includes('api.github.com');
    const dir = u.endsWith('/skills') || u.endsWith('/commands') || u.endsWith('/agents');
    const body = api
      ? JSON.stringify(dir ? [{ name: 'sql', type: 'dir' }] : [{ name: 'SKILL.md', type: 'file' }])
      : '---\nname: sql\n---\n';
    return { ok: true, status: 200, json: async () => JSON.parse(body), text: async () => body };
  };
  process.env.GITHUB_TOKEN = 'ghp_fake_token_for_the_test';
  import('$HERE/../cli/lib/github.mjs').then(async (gh) => {
    await gh.fetchSkills();
    const api = calls.filter((c) => c[0] === 'api.github.com');
    const raw = calls.filter((c) => c[0] === 'raw.githubusercontent.com');
    console.log('api=' + api.length + ':' + (api.every((c) => c[1] === 'auth') ? 'all-auth' : 'some-bare'));
    console.log('raw=' + raw.length + ':' + (raw.every((c) => c[1] === 'none') ? 'all-bare' : 'some-auth'));
  });
" > "$TMP/hdr.out" 2>"$TMP/hdr.err"

hdr() {  # hdr <label> <expected line> [file, default hdr.out]
  N=$((N+1))
  f="$TMP/${3:-hdr.out}"
  if grep -qx "$2" "$f"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s — want %s, got: %s\n' "$1" "$2" "$(tr '\n' ' ' < "$f")"; fi
}

hdr "the token goes to the API" "api=2:all-auth"
hdr "and never to raw"          "raw=1:all-bare"

# raw.githubusercontent.com served intermittent 503s for a few minutes and the
# CLI turned that into seven "skipping" warnings and an exit code of 0 — a
# half-installed catalog that looked like a successful run. The headers were
# blamed first and were not the cause: bare requests failed at the same rate.
#
# Two behaviours, and only the pair is safe. Retrying without failing hard would
# still exit 0 on a real outage; failing hard without retrying would turn every
# blip into a dead install.
echo "raw fetch retries, then fails loudly"
node -e "
  let n = 0;
  globalThis.fetch = async (url) => {
    const u = String(url);
    if (u.includes('api.github.com')) {
      const dir = u.endsWith('/skills');
      return { ok: true, status: 200, json: async () =>
        dir ? [{ name: 'sql', type: 'dir' }] : [{ name: 'SKILL.md', type: 'file' }] };
    }
    // Unwell for the first two attempts, exactly like the real window.
    if (++n <= 2) return { ok: false, status: 503, statusText: 'Service Unavailable' };
    return { ok: true, status: 200, text: async () => '---\nname: sql\n---\n' };
  };
  import('$HERE/../cli/lib/github.mjs').then(async (gh) => {
    const s = await gh.fetchSkills();
    console.log('recovered=' + s.length + ' attempts=' + n);
  }).catch((e) => console.log('threw=' + e.message));
" > "$TMP/retry.out" 2>&1
hdr "a blip is retried, not skipped" "recovered=1 attempts=3" retry.out

node -e "
  globalThis.fetch = async (url) => {
    const u = String(url);
    if (u.includes('api.github.com')) {
      const dir = u.endsWith('/skills');
      return { ok: true, status: 200, json: async () =>
        dir ? [{ name: 'sql', type: 'dir' }] : [{ name: 'SKILL.md', type: 'file' }] };
    }
    return { ok: false, status: 503, statusText: 'Service Unavailable' };
  };
  import('$HERE/../cli/lib/github.mjs').then(async (gh) => {
    const s = await gh.fetchSkills();
    console.log('SILENTLY-RETURNED=' + s.length);
  }).catch(() => console.log('threw'));
" > "$TMP/dead.out" 2>&1
N=$((N+1))
if grep -qx "threw" "$TMP/dead.out"; then
  PASS=$((PASS+1)); printf '  ok   %s\n' "an outage that never clears fails the install"
else
  FAIL=$((FAIL+1)); printf '  FAIL %s — got: %s\n' "an outage that never clears fails the install" "$(cat "$TMP/dead.out")"
fi

# A file the repo does not have is an answer. Retrying it three more times only
# makes the user wait to hear the same thing.
node -e "
  let n = 0;
  globalThis.fetch = async (url) => {
    const u = String(url);
    if (u.includes('api.github.com')) {
      const dir = u.endsWith('/skills');
      return { ok: true, status: 200, json: async () =>
        dir ? [{ name: 'sql', type: 'dir' }] : [{ name: 'SKILL.md', type: 'file' }] };
    }
    n++;
    return { ok: false, status: 404, statusText: 'Not Found' };
  };
  import('$HERE/../cli/lib/github.mjs')
    .then((gh) => gh.fetchSkills())
    .then(() => console.log('no-throw'))
    .catch(() => console.log('attempts=' + n));
" > "$TMP/nf.out" 2>&1
hdr "a 404 is not retried" "attempts=1" nf.out
