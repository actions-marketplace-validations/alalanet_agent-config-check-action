#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2155 # adopted as the reviewer wrote it (round 2): backticks are data
# Reviewer's proof tests for CI-ACT-1 (untracked). Each "PROOF" line shows a property the branch states that does
# not hold; "ok" lines are properties checked and holding.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$(dirname "$HERE")/check.sh"
WORK="$(mktemp -d)"
trap 'kill "${SERVER_PID:-0}" 2>/dev/null; rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
newrepo() { local d="$WORK/$1"; mkdir -p "$d"; git -C "$d" init -q; printf '%s\n' "$d"; }
commit() { git -C "$1" add -A && git -C "$1" commit -qm t; }
collect() { local out="$WORK/out-$(basename "$1")"; mkdir -p "$out"; INPUT_PATH="$1" bash "$CHECK" collect "$out"; printf '%s\n' "$out"; }

# 1. A link on a configuration path to .git/config (not a tracked file) sends the checkout's git config, with the
# credential actions/checkout v4/v5 persist there by default; the server's repo mode only follows links to tracked
# blobs. Value built from parts, not a real token.
R="$(newrepo gitcfg)"
printf 'x\n' >"$R/AGENTS.md"
ln -s .git/config "$R/.mcp.json"
commit "$R"
fake="AUTHORIZATION: basic $(printf '%s' 'x-access-token:' 'ghs_' 'FAKEFAKEFAKE' | base64)"
git -C "$R" config --local http.https://github.com/.extraheader "$fake"
O="$(collect "$R")"
if jq -r '.files[".mcp.json"] // ""' "$O/body.json" | grep -q 'extraheader'; then
  echo "PROOF 1 link-to-.git/config: the checkout's .git/config (with its extraheader credential) is sent as .mcp.json"
else echo "ok    1 link-to-.git/config not sent"; fi

# 2. A link to an untracked file (written by an earlier step) bypasses both "tracked files only" and the .env filter.
R="$(newrepo untracked)"
mkdir -p "$R/.claude"
ln -s ../.env.ci "$R/.claude/settings.local.json"
commit "$R"
printf 'DEPLOY_KEY=%s\n' "$(printf '%s' 'not-' 'a-real-' 'secret')" >"$R/.env.ci"
O="$(collect "$R")"
if jq -r '.files[".claude/settings.local.json"] // ""' "$O/body.json" | grep -q 'DEPLOY_KEY='; then
  echo "PROOF 2 link-to-untracked: an untracked .env.ci reached through a link is sent whole (DEPLOY_KEY line)"
else echo "ok    2 link-to-untracked not sent"; fi

# 3. A link to a link: the server holds it ("points to another symbolic link"); the Action follows the chain.
R="$(newrepo chain)"
printf 'real\n' >"$R/b.md"
ln -s b.md "$R/a.md"
ln -s a.md "$R/CLAUDE.md"
commit "$R"
O="$(collect "$R")"
if [ "$(jq -r '.files["CLAUDE.md"] // "none"' "$O/body.json")" = real ] && ! grep -q CLAUDE.md "$O/local.jsonl"; then
  echo "PROOF 3 link-chain: CLAUDE.md -> a.md -> b.md is followed and sent; the server holds check_incomplete:symlink"
else echo "ok    3 link chain held"; fi

# 4. .env: lines the server does not read leave the runner when a listed name is a substring of the key.
R="$(newrepo envsub)"
printf 'HTTP_PROXY_PASSWORD=%s\nCORP_HTTPS_PROXY=http://u:%s@p\nAPI_KEY=k\n' "$(printf '%s' 'hun' 'ter2')" "$(printf '%s' 'pa' 'ss')" >"$R/.env"
commit "$R"
O="$(collect "$R")"
envsent="$(jq -r '.files[".env"] // ""' "$O/body.json")"
case "$envsent" in
  *HTTP_PROXY_PASSWORD*|*CORP_HTTPS_PROXY*) echo "PROOF 4 env-substring: sent [$(printf '%s' "$envsent" | tr '\n' ';')]; the server reads neither key" ;;
  *) echo "ok    4 env lines exact" ;;
esac

# 5. Paths the server's files mode refuses as a whole request (bad_files): a backslash, or more than 300 bytes.
R="$(newrepo badpath)"
mkdir -p "$R/.claude/agents" "$R/$(printf 'd%.0s' $(seq 1 200))/$(printf 'e%.0s' $(seq 1 100))"
printf 'x\n' >"$R/.claude/agents/a\\b.md"
printf 'y\n' >"$R/$(printf 'd%.0s' $(seq 1 200))/$(printf 'e%.0s' $(seq 1 100))/AGENTS.md"
printf 'z\n' >"$R/AGENTS.md"
commit "$R"
O="$(collect "$R")"
n_bs="$(jq '[.files | keys[] | select(contains("\\"))] | length' "$O/body.json")"
n_long="$(jq '[.files | keys[] | select(utf8bytelength > 300)] | length' "$O/body.json")"
if [ "$n_bs" -gt 0 ] || [ "$n_long" -gt 0 ]; then
  echo "PROOF 5 server-refused-paths: body holds $n_bs path(s) with a backslash and $n_long over 300 bytes; the server answers 400 bad_files for the whole check"
else echo "ok    5 refused paths held locally"; fi

# 6. JSON size: 2 MiB of content can be over the server's 3 MiB body limit once JSON-escaped (control bytes are 6).
R="$(newrepo escape)"
mkdir -p "$R/.cursor/rules"
for i in 1 2 3; do head -c 250000 /dev/zero | tr '\0' '\001' >"$R/.cursor/rules/r$i.md"; done
commit "$R"
O="$(collect "$R")"
bytes="$(wc -c <"$O/body.json" | tr -d ' ')"
if [ "$bytes" -gt 3145728 ]; then
  echo "PROOF 6 json-size: body.json is $bytes bytes, over the server's 3 MiB read limit (io.LimitReader 3<<20): 400 bad_request"
else echo "ok    6 body under 3 MiB ($bytes)"; fi

# 7. Markdown injection into the step summary through server text (the server quotes lines of the PR's files).
SRV="$WORK/srv"; mkdir -p "$SRV"
python3 -I "$HERE/fake_server.py" "$SRV" &
SERVER_PID=$!
for _ in $(seq 1 100); do [ -f "$SRV/port" ] && break; sleep 0.1; done
API="http://127.0.0.1:$(cat "$SRV/port")"
printf '[{"status":200,"body":{"decision":"hold","reasons":["x"],"advice":"Read [the fix](https://evil.example/approve) ![p](https://evil.example/p.png)","findings":[{"file":"AGENTS.md","decision":"hold","reason":"inj` [x](https://evil.example) `","detail":"**Approved** by [security](https://evil.example)"}],"mcp_servers":[]}}]' >"$SRV/responses.json"
R="$(newrepo md)"; printf 'x\n' >"$R/AGENTS.md"; commit "$R"
env -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN INPUT_PATH="$R" API="$API" FAIL_ON=block ON_ERROR=fail OIDC=auto RETRY_SLEEP_MAX=0 \
  GITHUB_STEP_SUMMARY="$WORK/md.summary" GITHUB_OUTPUT="$WORK/md.output" bash "$CHECK" >"$WORK/md.log" 2>&1
# round 2: reason codes and names are code spans (a fence longer than any backtick run in them), whose text renders
# literally; what renders as Markdown is the text outside them (CommonMark code spans stripped before the check)
outside="$(python3 -I -c 'import re,sys; print(re.sub(r"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)", "", sys.stdin.read()))' <"$WORK/md.summary")"
if printf '%s' "$outside" | grep -qF '](https://evil.example'; then
  echo "PROOF 7 summary-markdown: server text renders as links/images in the summary:"
  grep -F 'evil.example' "$WORK/md.summary" | sed 's/^/        /'
else echo "ok    7 summary markdown neutral"; fi
