#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016 # "check && pass || fail": pass always succeeds; backticks in single quotes are data
# Tests of the agent config check Action: file collection on real git checkouts, and the request, the
# exit code, the annotations and the summary against a fake alalanet on loopback (fake_server.py).
# Needs bash, git, curl, jq, python3 and realpath. Run: bash actions/agent-config-check/test/test.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ACTION="$(dirname "$HERE")"
CHECK="$ACTION/check.sh"
WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

fails=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# newrepo NAME: an empty git repository; prints its path.
newrepo() {
  local d="$WORK/$1"
  mkdir -p "$d"
  git -C "$d" init -q
  printf '%s\n' "$d"
}
commit() { git -C "$1" add -A && git -C "$1" commit -qm t; }

# finding FILE FILTER: FILE (JSON lines) holds a finding FILTER selects. Not jq -e: jq 1.6 exits 0 on an empty
# input with -e, so an absent finding would pass.
finding() { [ "$(jq -s "[.[] | select($2)] | length" "$1")" -gt 0 ]; }

# collect REPO: runs the collector; body.json and local.jsonl land in $WORK/out-<repo name>.
collect() {
  local out
  out="$WORK/out-$(basename "$1")"
  rm -rf "$out" && mkdir -p "$out"
  INPUT_PATH="$1" bash "$CHECK" collect "$out"
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------------------------
# Collection
# ---------------------------------------------------------------------------------------------

t=collect-paths
R="$(newrepo paths)"
mkdir -p "$R/.claude/skills/deploy" "$R/docs" "$R/src" "$R/shared/agents" "$R/.cursor/rules" "$R/.claude/commands" "$R/.VSCode"
printf 'Use pnpm.\n' >"$R/AGENTS.md"
printf '{"mcpServers":{}}\n' >"$R/.MCP.json"
printf -- '---\nname: deploy\n---\nDeploy.\n' >"$R/.claude/skills/deploy/SKILL.md"
printf 'Docs rules.\n' >"$R/docs/AGENTS.md"
printf 'package main\n' >"$R/src/main.go"
printf 'Not config.\n' >"$R/README.md"
printf '{"tasks":[]}\n' >"$R/.VSCode/tasks.json"
# .env: one variable the server reads, one secret that must never leave the runner
printf 'API_KEY=%s\nexport ANTHROPIC_BASE_URL=https://proxy.example\n# comment\n' "sk-not-a-real-$(printf 'secret')" >"$R/.env"
printf 'agent a\n' >"$R/shared/agents/a.md"
ln -s AGENTS.md "$R/CLAUDE.md"                      # a file link inside the checkout: sent under its own name
ln -s ../shared/agents "$R/.claude/agents"            # a folder link: its files come in under the link's path
ln -s /etc/hostname "$R/.claude/commands/evil.md"     # outside the checkout: never read
head -c 300000 /dev/zero | tr '\0' 'a' >"$R/.cursor/rules/big.md"
commit "$R"
printf '{"untracked":true}\n' >"$R/.cursor/mcp.json"  # not in git: not sent
O="$(collect "$R")"
got="$(jq -r '.files | keys[]' "$O/body.json" | LC_ALL=C sort | tr '\n' ' ')"
want=".MCP.json .VSCode/tasks.json .claude/agents/a.md .claude/skills/deploy/SKILL.md .env AGENTS.md CLAUDE.md docs/AGENTS.md "
[ "$got" = "$want" ] && pass "$t" || fail "$t" "sent [$got], want [$want]"

t=collect-claude-link-content
[ "$(jq -r '.files["CLAUDE.md"]' "$O/body.json")" = "Use pnpm." ] && pass "$t" || fail "$t" "$(jq -c '.files["CLAUDE.md"]' "$O/body.json")"

t=collect-env-filtered
envsent="$(jq -r '.files[".env"]' "$O/body.json")"
case "$envsent" in
  *sk-not-a-real*|*API_KEY*|*comment*) fail "$t" "a line the server does not read left the runner: $envsent" ;;
  *ANTHROPIC_BASE_URL=https://proxy.example*) pass "$t" ;;
  *) fail "$t" "the model API line was not sent: $envsent" ;;
esac

t=collect-local-holds
holds="$(jq -r '[.file, .decision, .reason] | join(" ")' "$O/local.jsonl" | LC_ALL=C sort | tr '\n' ';')"
want=".claude/commands/evil.md hold check_incomplete:symlink;.cursor/rules/big.md hold check_incomplete:file_too_large;"
[ "$holds" = "$want" ] && pass "$t" || fail "$t" "local findings [$holds], want [$want]"

t=collect-never-reads-outside
if grep -q "$(cat /etc/hostname 2>/dev/null || echo no-hostname-file)" "$O/body.json" 2>/dev/null && [ -s /etc/hostname ]; then
  fail "$t" "the content of a file outside the checkout was sent"
else
  pass "$t"
fi

t=collect-link-to-root-holds
R="$(newrepo rootlink)"
mkdir -p "$R/.claude" && printf 'x\n' >"$R/AGENTS.md"
ln -s .. "$R/.claude/skills"
commit "$R"
O="$(collect "$R")"
finding "$O/local.jsonl" '.file == ".claude/skills" and .reason == "check_incomplete:symlink"' && pass "$t" || fail "$t" "$(cat "$O/local.jsonl")"

t=collect-max-files
R="$(newrepo many)"
mkdir -p "$R/.cursor/rules"
for i in $(seq -w 1 45); do printf 'rule %s\n' "$i" >"$R/.cursor/rules/r$i.md"; done
printf 'top\n' >"$R/AGENTS.md"
commit "$R"
O="$(collect "$R")"
n="$(jq '.files | length' "$O/body.json")"
first="$(jq -r '.files | has("AGENTS.md")' "$O/body.json")"   # order 0 goes first, as the server sorts
last="$(jq -r '.files | has(".cursor/rules/r39.md") and (has(".cursor/rules/r40.md") | not)' "$O/body.json")"
more="$(jq -r 'select(.reason == "check_incomplete:more_config_files") | .decision' "$O/local.jsonl")"
[ "$n" = 40 ] && [ "$first" = true ] && [ "$last" = true ] && [ "$more" = hold ] && pass "$t" || fail "$t" "n=$n first=$first last=$last more=$more"

t=collect-max-total
R="$(newrepo total)"
mkdir -p "$R/.cursor/rules"
for i in 1 2 3 4 5 6 7 8 9; do head -c 250000 /dev/zero | tr '\0' 'b' >"$R/.cursor/rules/r$i.md"; done
commit "$R"
O="$(collect "$R")"
n="$(jq '.files | length' "$O/body.json")"
total="$(jq '[.files[] | utf8bytelength] | add' "$O/body.json")"
more="$(jq -r 'select(.reason == "check_incomplete:more_config_files") | .decision' "$O/local.jsonl")"
[ "$n" = 8 ] && [ "$total" -le 2097152 ] && [ "$more" = hold ] && pass "$t" || fail "$t" "n=$n total=$total more=$more"

t=collect-file-exactly-256k-sent
R="$(newrepo edge)"
head -c 262144 /dev/zero | tr '\0' 'c' >"$R/AGENTS.md"
head -c 262145 /dev/zero | tr '\0' 'c' >"$R/GEMINI.md"
commit "$R"
O="$(collect "$R")"
sent="$(jq -r '.files | keys | join(",")' "$O/body.json")"
big="$(jq -r 'select(.reason == "check_incomplete:file_too_large") | .file' "$O/local.jsonl")"
[ "$sent" = AGENTS.md ] && [ "$big" = GEMINI.md ] && pass "$t" || fail "$t" "sent=$sent big=$big"

t=collect-reads-the-index
# what is sent is what git tracks, as the server reads the tree: a file changed or removed on disk by an earlier step
# is sent as committed; a blob git cannot read holds
R="$(newrepo sparse)"
printf 'x\n' >"$R/AGENTS.md" && printf 'y\n' >"$R/GEMINI.md" && printf 'z\n' >"$R/CLAUDE.md"
commit "$R"
rm "$R/GEMINI.md"
printf 'changed on disk\n' >"$R/AGENTS.md"
blob="$(git -C "$R" rev-parse HEAD:CLAUDE.md)"
rm "$R/.git/objects/${blob:0:2}/${blob:2}"
O="$(collect "$R")"
if [ "$(jq -r '.files["GEMINI.md"]' "$O/body.json")" = y ] && [ "$(jq -r '.files["AGENTS.md"]' "$O/body.json")" = x ] &&
  [ "$(jq -r '.files | has("CLAUDE.md")' "$O/body.json")" = false ] &&
  finding "$O/local.jsonl" '.file == "CLAUDE.md" and .reason == "check_incomplete:file_not_read"'; then
  pass "$t"
else
  fail "$t" "$(cat "$O/body.json") / $(cat "$O/local.jsonl")"
fi

# links as the server's followRepoLinks reads them (round 2, P2-1): only to tracked files and folders, never through
# another link, untracked files or .git
t=collect-links-as-the-server
R="$(newrepo links)"
mkdir -p "$R/.claude" "$R/docs" "$R/shared/rules"
printf 'real\n' >"$R/docs/b.md"
ln -s b.md "$R/docs/a.md"
ln -s docs/a.md "$R/CLAUDE.md"              # a link to a link: held
ln -s ../.env.ci "$R/.claude/settings.local.json" # untracked target: held
ln -s .git/config "$R/.mcp.json"            # .git is never tracked: held
ln -s docs/b.md "$R/AGENTS.md"              # a tracked file: sent under the link's name
printf 'rule\n' >"$R/shared/rules/r.md"
ln -s r.md "$R/shared/rules/l.md"
ln -s ../shared/rules "$R/.claude/rules"     # a folder: its tracked files come in, a link inside it holds
commit "$R"
printf 'DEPLOY_KEY=%s\n' "$(printf '%s' 'not-' 'real')" >"$R/.env.ci"
O="$(collect "$R")"
sent="$(jq -r '.files | keys | join(",")' "$O/body.json")"
holds="$(jq -r 'select(.reason == "check_incomplete:symlink") | .file + "=" + .detail' "$O/local.jsonl" | LC_ALL=C sort | tr '\n' ';')"
want_holds=".claude/rules/l.md=a symbolic link inside a linked folder;.claude/settings.local.json=points to .env.ci, which is not in the repository;.mcp.json=points to .git/config, which is not in the repository;CLAUDE.md=points to another symbolic link (docs/a.md);"
if [ "$sent" = ".claude/rules/r.md,AGENTS.md" ] && [ "$(jq -r '.files["AGENTS.md"]' "$O/body.json")" = real ] && [ "$holds" = "$want_holds" ]; then
  pass "$t"
else
  fail "$t" "sent [$sent] holds [$holds]"
fi

t=collect-links-absolute-and-climbing
R="$(newrepo absclimb)"
mkdir -p "$R/.claude/commands"
printf 'Use pnpm.\n' >"$R/AGENTS.md"
ln -s /AGENTS.md "$R/GEMINI.md"                         # absolute, though /AGENTS.md cleaned would be a tracked path
ln -s ../../../outside.md "$R/.claude/commands/up.md"   # climbs out of the checkout
commit "$R"
O="$(collect "$R")"
holds="$(jq -r 'select(.reason == "check_incomplete:symlink") | .file + "=" + .detail' "$O/local.jsonl" | LC_ALL=C sort | tr '\n' ';')"
if [ "$(jq -r '.files | keys | join(",")' "$O/body.json")" = AGENTS.md ] &&
  [ "$holds" = ".claude/commands/up.md=points outside the repository (../../../outside.md);GEMINI.md=points outside the repository (/AGENTS.md);" ]; then
  pass "$t"
else
  fail "$t" "$(cat "$O/body.json") / $holds"
fi

t=collect-index-stages-and-submodules
# a merge stage is not a checked-out file; a submodule on a configuration path holds
R="$(newrepo stages)"
printf 'x\n' >"$R/AGENTS.md"
commit "$R"
blob="$(printf 'conflict\n' | git -C "$R" hash-object -w --stdin)"
head="$(git -C "$R" rev-parse HEAD)"
printf '100644 %s 1\tGEMINI.md\n100644 %s 2\tGEMINI.md\n100644 %s 3\tGEMINI.md\n' "$blob" "$blob" "$blob" | git -C "$R" update-index --index-info
git -C "$R" update-index --add --cacheinfo "160000,$head,.claude/skills/ext"
O="$(collect "$R")"
if [ "$(jq -r '.files | keys | join(",")' "$O/body.json")" = AGENTS.md ] &&
  [ "$(jq -s '[.[] | select(.file == ".claude/skills/ext" and .reason == "check_incomplete:submodule")] | length' "$O/local.jsonl")" = 1 ]; then
  pass "$t"
else
  fail "$t" "$(cat "$O/body.json") / $(cat "$O/local.jsonl")"
fi

t=collect-links-from-the-index-on-windows
# Git for Windows (core.symlinks=false) checks a link out as a file holding its text; the index still says link
R="$(newrepo windows)"
git -C "$R" config core.symlinks false
mkdir -p "$R/skills/deploy"
printf 'Use pnpm.\n' >"$R/AGENTS.md"
printf -- '---\nname: deploy\n---\n' >"$R/skills/deploy/SKILL.md"
commit "$R"
for l in "CLAUDE.md:AGENTS.md" ".claude/skills:../skills"; do
  name=${l%%:*}
  sha="$(printf '%s' "${l#*:}" | git -C "$R" hash-object -w --stdin)"
  git -C "$R" update-index --add --cacheinfo "120000,$sha,$name"
  mkdir -p "$R/$(dirname "$name")"
  printf '%s' "${l#*:}" >"$R/$name"
done
git -C "$R" commit -qm links
O="$(collect "$R")"
if [ "$(jq -r '.files["CLAUDE.md"]' "$O/body.json")" = "Use pnpm." ] && [ "$(jq -r '.files | has(".claude/skills/deploy/SKILL.md")' "$O/body.json")" = true ]; then
  pass "$t"
else
  fail "$t" "$(cat "$O/body.json") / $(cat "$O/local.jsonl")"
fi

t=collect-more-than-20-links
R="$(newrepo manylinks)"
mkdir -p "$R/.claude/commands"
printf 'c\n' >"$R/c.md"
for i in $(seq -w 1 21); do ln -s ../../c.md "$R/.claude/commands/l$i.md"; done
commit "$R"
O="$(collect "$R")"
n="$(jq '.files | length' "$O/body.json")"
if [ "$n" = 20 ] && [ "$(jq -r '.files | has(".claude/commands/l21.md")' "$O/body.json")" = false ] &&
  finding "$O/local.jsonl" '.file == "" and .reason == "check_incomplete:symlink" and (.detail | startswith("21 symbolic links"))'; then
  pass "$t"
else
  fail "$t" "n=$n $(cat "$O/local.jsonl")"
fi

# paths and sizes the server's files mode refuses are held here and never sent (round 2, P2-2)
t=collect-paths-the-server-refuses
R="$(newrepo badpath)"
long="$(printf 'd%.0s' $(seq 1 200))/$(printf 'e%.0s' $(seq 1 100))"
edge="$(printf 'f%.0s' $(seq 1 140))/$(printf 'g%.0s' $(seq 1 149))" # 290 bytes in two names (macOS takes 255 a name)
mkdir -p "$R/.claude/agents" "$R/$long" "$R/$edge"
printf 'x\n' >"$R/.claude/agents/a\\b.md"
printf 'y\n' >"$R/$long/AGENTS.md"
printf 'w\n' >"$R/$edge/AGENTS.md" # 300 bytes: sent
mkdir -p "$R/$edge/h"
printf 'v\n' >"$R/$edge/h/CLAUDE.md" # 290 + "/h/CLAUDE.md": 302 bytes, held
mkdir -p "$R/${edge}x"
printf 'u\n' >"$R/${edge}x/AGENTS.md" # 301 bytes: held
printf 'z\n' >"$R/AGENTS.md"
commit "$R"
O="$(collect "$R")"
sent="$(jq -r '.files | keys | map(length) | join(",")' "$O/body.json")"
nheld="$(jq -s '[.[] | select(.reason == "check_incomplete:file_not_read")] | length' "$O/local.jsonl")"
if [ "$sent" = "9,300" ] && [ "$nheld" = 4 ]; then pass "$t"; else fail "$t" "sent lengths [$sent] held $nheld"; fi

t=collect-json-size-under-3mib
R="$(newrepo escape)"
mkdir -p "$R/.cursor/rules"
for i in 1 2 3; do head -c 250000 /dev/zero | tr '\0' '\001' >"$R/.cursor/rules/r$i.md"; done
commit "$R"
O="$(collect "$R")"
bytes="$(wc -c <"$O/body.json" | tr -d ' ')"
if [ "$bytes" -le 3145728 ] && [ "$(jq '.files | length' "$O/body.json")" = 2 ] &&
  finding "$O/local.jsonl" '.reason == "check_incomplete:more_config_files"'; then
  pass "$t"
else
  fail "$t" "body $bytes bytes, $(jq '.files | length' "$O/body.json") files"
fi

t=collect-env-exact-names
R="$(newrepo envexact)"
{
  printf 'HTTP_PROXY_PASSWORD=%s\n' "$(printf '%s' 'hun' 'ter2')"
  printf 'CORP_HTTPS_PROXY=http://u:%s@p\n' "$(printf '%s' 'pa' 'ss')"
  printf 'MY_NODE_OPTIONS_TOKEN=t\n'
  printf 'A=1 HTTP_PROXY=x\n'
  printf 'export   HTTP_PROXY = http://proxy.example\n'
  printf '  NODE_OPTIONS=--require ./x.js\n'
  printf 'exportCODEX_HOME=.codex\n'
} >"$R/.env"
commit "$R"
O="$(collect "$R")"
got="$(jq -j '.files[".env"]' "$O/body.json" | tr '\n' ';')"
want="export   HTTP_PROXY = http://proxy.example;  NODE_OPTIONS=--require ./x.js;"
[ "$got" = "$want" ] && pass "$t" || fail "$t" "sent [$got]"

t=collect-env-unicode-spaces
# the server's dotenv trims with Go's strings.TrimSpace: Unicode spaces count, NBSP and U+3000 among them
R="$(newrepo envuni)"
nbsp="$(printf '\302\240')" ideo="$(printf '\343\200\200')" nel="$(printf '\302\205')"
{
  printf '%sHTTPS_PROXY=http://a.example\n' "$nbsp"
  printf 'HTTP_PROXY%s=http://b.example\n' "$nbsp"
  printf '%sNODE_OPTIONS%s=--require ./c.js\n' "$ideo" "$nel"
  printf 'HTTP_PROXY_PASSWORD%s=%s\n' "$nbsp" "$(printf '%s' 'hun' 'ter2')"
  printf 'X%sHTTP_PROXY=d\n' "$nbsp"
} >"$R/.env"
commit "$R"
O="$(collect "$R")"
got="$(jq -j '.files[".env"]' "$O/body.json" | LC_ALL=C tr '\n' ';')"
want="$(printf '%sHTTPS_PROXY=http://a.example;HTTP_PROXY%s=http://b.example;%sNODE_OPTIONS%s=--require ./c.js;' "$nbsp" "$nbsp" "$ideo" "$nel")"
[ "$got" = "$want" ] && pass "$t" || fail "$t" "sent [$got]"

# git cannot read the checkout, or is not installed: nothing is sent, never the files on disk (round 3, R2-P2-2)
t=collect-git-refuses-the-checkout
R="$(newrepo broken)"
printf 'x\n' >"$R/AGENTS.md"
commit "$R"
printf '//registry.npmjs.org/:_authToken=%s\n' "$(printf '%s' 'npm_' 'NOTAREAL')" >"$R/.npmrc" # untracked
printf 'not a ref\n' >"$R/.git/HEAD"
O="$(collect "$R")"
if [ "$(jq '.files | length' "$O/body.json")" = 0 ] &&
  finding "$O/local.jsonl" '.file == "" and .reason == "check_incomplete:file_not_read" and (.detail | startswith("git could not read this checkout, so nothing was sent"))'; then
  pass "$t"
else
  fail "$t" "$(cat "$O/body.json") / $(cat "$O/local.jsonl")"
fi

t=collect-git-refuses-a-subfolder
# the folder the Action reads is below the checkout's root: the .git above it still counts
mkdir -p "$R/sub" && printf 'y\n' >"$R/sub/AGENTS.md"
O="$(collect "$R/sub")"
[ "$(jq '.files | length' "$O/body.json")" = 0 ] && finding "$O/local.jsonl" '.reason == "check_incomplete:file_not_read"' &&
  pass "$t" || fail "$t" "$(cat "$O/body.json") / $(cat "$O/local.jsonl")"

t=collect-without-git-installed
NOGIT="$WORK/nogit-bin"
mkdir -p "$NOGIT"
IFS=: read -r -a pathdirs <<<"$PATH"
for d in "${pathdirs[@]}"; do
  for f in "$d"/*; do
    b="$(basename "$f")"
    [ "$b" != git ] && [ -x "$f" ] && [ ! -e "$NOGIT/$b" ] && ln -s "$f" "$NOGIT/$b"
  done
done
R="$(newrepo nogitinstalled)"
printf 'x\n' >"$R/AGENTS.md"
commit "$R"
out="$WORK/out-nogitinstalled"
mkdir -p "$out"
PATH="$NOGIT" INPUT_PATH="$R" bash "$CHECK" collect "$out"
if [ "$(jq '.files | length' "$out/body.json")" = 0 ] &&
  finding "$out/local.jsonl" '.reason == "check_incomplete:file_not_read" and (.detail | startswith("git is not installed"))'; then
  pass "$t"
else
  fail "$t" "$(cat "$out/body.json") / $(cat "$out/local.jsonl")"
fi

# git's own state cannot turn into an unchecked allow, another repository, or code run (round 4, R3-P3-1 and -2)
t=collect-corrupt-index-holds
R="$(newrepo corruptidx)"
printf '{"mcpServers":{}}\n' >"$R/.mcp.json"
commit "$R"
printf 'not an index' >"$R/.git/index"
O="$(collect "$R")"
if [ "$(jq '.files | length' "$O/body.json")" = 0 ] &&
  finding "$O/local.jsonl" '.reason == "check_incomplete:file_not_read" and (.detail | startswith("git could not list this checkout'"'"'s index"))'; then
  pass "$t"
else
  fail "$t" "$(cat "$O/body.json") / $(cat "$O/local.jsonl")"
fi

t=collect-bare-holds
R="$(newrepo bare)"
printf '{"mcpServers":{}}\n' >"$R/.mcp.json"
commit "$R"
git -C "$R" config core.bare true
O="$(collect "$R")"
[ "$(jq '.files | length' "$O/body.json")" = 0 ] &&
  finding "$O/local.jsonl" '.reason == "check_incomplete:file_not_read" and (.detail | contains("bare repository"))' &&
  pass "$t" || fail "$t" "$(cat "$O/body.json") / $(cat "$O/local.jsonl")"

t=collect-ignores-git-environment
R="$(newrepo envck)"
printf 'checkout rules\n' >"$R/AGENTS.md"
commit "$R"
OTHER="$(newrepo envother)"
printf '//registry.npmjs.org/:_authToken=%s\n' "$(printf '%s' 'npm_' 'NOTAREAL')" >"$OTHER/.npmrc"
printf 'other rules\n' >"$OTHER/AGENTS.md"
commit "$OTHER"
out="$WORK/out-gitenv" && mkdir -p "$out"
GIT_DIR="$OTHER/.git" GIT_WORK_TREE="$OTHER" GIT_INDEX_FILE="$WORK/empty-index" GIT_OBJECT_DIRECTORY="$OTHER/.git/objects" \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.bare GIT_CONFIG_VALUE_0=true INPUT_PATH="$R" bash "$CHECK" collect "$out"
[ "$(jq -r '.files | keys | join(",")' "$out/body.json")" = AGENTS.md ] && [ "$(jq -r '.files["AGENTS.md"]' "$out/body.json")" = "checkout rules" ] &&
  pass "$t" || fail "$t" "$(cat "$out/body.json") / $(cat "$out/local.jsonl")"

t=collect-runs-no-repository-hook
R="$(newrepo fsmon)"
printf 'x\n' >"$R/AGENTS.md"
commit "$R"
printf '#!/bin/sh\ntouch "%s/RAN"\necho\n' "$WORK" >"$WORK/fsmonitor.sh"
chmod +x "$WORK/fsmonitor.sh"
git -C "$R" config core.fsmonitor "$WORK/fsmonitor.sh"
O="$(collect "$R")"
[ ! -e "$WORK/RAN" ] && [ "$(jq -r '.files | keys | join(",")' "$O/body.json")" = AGENTS.md ] && pass "$t" || fail "$t" "the repository's fsmonitor hook ran ($(ls "$WORK"))"

t=collect-no-git
D="$WORK/plain"
mkdir -p "$D/node_modules/x" "$D/.git-not" && printf 'x\n' >"$D/AGENTS.md" && printf 'vendored\n' >"$D/node_modules/x/AGENTS.md"
ln -s AGENTS.md "$D/CLAUDE.md" # without git's index a link is not followed
O="$(collect "$D")"
[ "$(jq -r '.files | keys | join(",")' "$O/body.json")" = AGENTS.md ] &&
  [ "$(jq -s '[.[] | select(.file == "CLAUDE.md" and .reason == "check_incomplete:symlink")] | length' "$O/local.jsonl")" = 1 ] &&
  pass "$t" || fail "$t" "$(jq -c '.files | keys' "$O/body.json") $(cat "$O/local.jsonl")"

t=classify-case-and-order
got="$(printf '%s\0' '.CLAUDE/Settings.JSON' 'a/b/.mcp.json' '.github/hooks/x.json' '.github/hooks/a/x.json' 'x/CLAUDE.md' '.claude/agents/CLAUDE.md' 'README.md' | bash "$CHECK" classify | tr '\0' ';')"
want=$'claude\t0\t.CLAUDE/Settings.JSON;mcp\t2\ta/b/.mcp.json;hooks\t0\t.github/hooks/x.json;\t0\t.github/hooks/a/x.json;instructions\t2\tx/CLAUDE.md;instructions\t1\t.claude/agents/CLAUDE.md;\t0\tREADME.md;'
[ "$got" = "$want" ] && pass "$t" || fail "$t" "got [$got]"

# ---------------------------------------------------------------------------------------------
# Request, exit code, annotations, summary (fake server)
# ---------------------------------------------------------------------------------------------

SRV="$WORK/srv"
mkdir -p "$SRV"
printf '[{"status":200,"body":{}}]' >"$SRV/responses.json"
python3 -I "$HERE/fake_server.py" "$SRV" &
SERVER_PID=$!
for _ in $(seq 1 100); do [ -f "$SRV/port" ] && break; sleep 0.1; done
API="http://127.0.0.1:$(cat "$SRV/port")"

R="$(newrepo run)"
mkdir -p "$R/.vscode"
printf 'Use pnpm.\n' >"$R/AGENTS.md"
printf '{"tasks":[]}\n' >"$R/.vscode/tasks.json"
commit "$R"

# respond JSON...: the fake server's answers, in order
respond() { printf '%s' "$1" >"$SRV/responses.json"; rm -f "$SRV"/req-*.json "$SRV/served"; }
reqs() { find "$SRV" -name 'req-*.json' | wc -l | tr -d ' '; }
apireqs() { cat "$SRV"/req-*.json 2>/dev/null | jq -s '[.[] | select(.path == "/v1/repo-config-check")] | length'; }

# run NAME [VAR=value...]: runs the Action over $R; stdout+stderr in $WORK/NAME.log, summary and output files next
# to it, the exit code in RC.
run() {
  local name=$1
  shift
  : >"$WORK/$name.summary"
  : >"$WORK/$name.output"
  set +e
  env -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN \
    INPUT_PATH="$R" API="$API" FAIL_ON=block ON_ERROR=fail OIDC=auto RETRY_SLEEP_MAX=0 \
    GITHUB_STEP_SUMMARY="$WORK/$name.summary" GITHUB_OUTPUT="$WORK/$name.output" "$@" \
    bash "$CHECK" >"$WORK/$name.log" 2>&1
  RC=$?
  set -e
}

ALLOW='{"decision":"allow","reasons":[],"advice":"Nothing found.","files_read":["AGENTS.md",".vscode/tasks.json"],"findings":[],"mcp_servers":[],"files_sha256":"'"$(printf 'ab%.0s' $(seq 1 32))"'","attestation":{"event":{"id":"'"$(printf 'cd%.0s' $(seq 1 32))"'"},"log_index":77}}'

t=run-allow
respond "[{\"status\":200,\"body\":$ALLOW}]"
run allow
body="$(jq -r '.body' "$SRV/req-1.json")"
ua="$(jq -r '.headers["user-agent"]' "$SRV/req-1.json")"
oidc="$(jq -r '.headers["x-alalanet-github-oidc"] // "none"' "$SRV/req-1.json")"
if [ "$RC" = 0 ] && [ "$(jq -r '.files | keys | join(",")' <<<"$body")" = ".vscode/tasks.json,AGENTS.md" ] &&
  [ "${ua%%/*}" = alalanet-agent-config-action ] && [ "$oidc" = none ] &&
  grep -q '^decision=allow$' "$WORK/allow.output" && grep -q "^attestation=$(printf 'cd%.0s' $(seq 1 32))$" "$WORK/allow.output" &&
  grep -q "/v1/attestations/$(printf 'cd%.0s' $(seq 1 32))" "$WORK/allow.summary" && grep -qi "runner address" "$WORK/allow.summary"; then
  pass "$t"
else
  fail "$t" "rc=$RC ua=$ua oidc=$oidc $(cat "$WORK/allow.log")"
fi

HOLD='{"decision":"hold","reasons":["task_on_folder_open"],"advice":"Read them.","files_read":[".vscode/tasks.json"],"findings":[{"file":".vscode/tasks.json","decision":"hold","reason":"task_on_folder_open","detail":"runs npm i"}],"mcp_servers":[{"file":".mcp.json","name":"x","target":"x@1","decision":"hold","reasons":["new_package"]}]}'

t=run-hold-warns
respond "[{\"status\":200,\"body\":$HOLD}]"
run hold
if [ "$RC" = 0 ] && grep -q '^::warning file=.vscode/tasks.json,title=alalanet task_on_folder_open::runs npm i$' "$WORK/hold.log" &&
  grep -q '^::warning file=.mcp.json,title=alalanet MCP server x::' "$WORK/hold.log" && grep -q 'task_on_folder_open' "$WORK/hold.summary"; then
  pass "$t"
else
  fail "$t" "rc=$RC $(cat "$WORK/hold.log")"
fi

t=run-hold-fails-on-hold
run holdfail FAIL_ON=hold
[ "$RC" = 1 ] && pass "$t" || fail "$t" "rc=$RC"

t=run-block-fails
respond '[{"status":200,"body":{"decision":"block","reasons":["known_malicious"],"advice":"Do not.","files_read":[".mcp.json"],"findings":[{"file":".mcp.json","decision":"block","reason":"known_malicious","detail":"evil"}],"mcp_servers":[]}}]'
run block
[ "$RC" = 1 ] && grep -q '^::error file=.mcp.json,title=alalanet known_malicious::evil$' "$WORK/block.log" && pass "$t" || fail "$t" "rc=$RC $(cat "$WORK/block.log")"

t=run-escapes-untrusted-text
respond '[{"status":200,"body":{"decision":"hold","reasons":["x"],"advice":"a","files_read":[],"findings":[{"file":"a,b:c.md","decision":"hold","reason":"inj","detail":"100% sure\n::add-mask::oops\r\n::stop-commands::x | <b>"}],"mcp_servers":[]}}]'
run inject
if grep -q '^::add-mask::oops' "$WORK/inject.log" || grep -q '^::stop-commands' "$WORK/inject.log"; then
  fail "$t" "untrusted text started a workflow command: $(cat "$WORK/inject.log")"
elif grep -qF '::warning file=a%2Cb%3Ac.md,title=alalanet inj::100%25 sure%0A::add-mask::oops%0D%0A::stop-commands::x | <b>' "$WORK/inject.log" &&
  ! grep -q '<b>' "$WORK/inject.summary" && grep -qF '&#60;b&#62;' "$WORK/inject.summary"; then
  pass "$t"
else
  fail "$t" "$(cat "$WORK/inject.log") / $(cat "$WORK/inject.summary")"
fi

t=run-summary-no-autolinks
# bare addresses in server text (it quotes the pull request) do not autolink: a zero-width joiner breaks them
zwj="$(printf '\342\200\215')"
respond '[{"status":200,"body":{"decision":"hold","reasons":["x"],"advice":"a","files_read":[],"findings":[{"file":"www.evil.example/AGENTS.md","decision":"hold","reason":"r","detail":"approve at https://evil.example/approve or HTTP://EVIL.example, www.evil.example, WWW.Evil.example, ops@evil.example"}],"mcp_servers":[{"file":".mcp.json","name":"n","target":"https://mcp.evil.example/mcp","decision":"hold","reasons":["r"]}]}}]'
run autolink
if grep -qiE '://|www\.|[a-z]@' "$WORK/autolink.summary"; then
  fail "$t" "an address that autolinks reached the summary: $(grep -iE '://|www\.|[a-z]@' "$WORK/autolink.summary")"
elif grep -qF "https:$zwj//evil.example/approve" "$WORK/autolink.summary" && grep -qF "HTTP:$zwj//EVIL" "$WORK/autolink.summary" &&
  grep -qF "www$zwj.evil.example/AGENTS.md" "$WORK/autolink.summary" && grep -qF "WWW$zwj.Evil" "$WORK/autolink.summary" &&
  grep -qF "ops$zwj@evil" "$WORK/autolink.summary" && grep -qF "https:$zwj//mcp.evil.example" "$WORK/autolink.summary"; then
  pass "$t"
else
  fail "$t" "$(cat "$WORK/autolink.summary")"
fi

t=run-summary-markdown-neutral
respond '[{"status":200,"body":{"decision":"hold","reasons":["x"],"advice":"Read [the fix](https://evil.example/approve) ![p](https://evil.example/p.png) _x_ #h ~s~","files_read":[],"findings":[{"file":"AGENTS.md","decision":"hold","reason":"inj` **x** ``","detail":"**Approved** by [security](https://evil.example) a\\\\b"}],"mcp_servers":[{"file":".mcp.json","name":"n`|`m","decision":"hold","reasons":["r"]}]}}]'
run md
if grep -qF '](' "$WORK/md.summary" || grep -qF '**Approved' "$WORK/md.summary" || grep -qF '![' "$WORK/md.summary" || grep -qF '_x_' "$WORK/md.summary"; then
  fail "$t" "Markdown from server text reached the summary: $(cat "$WORK/md.summary")"
elif grep -qF '| ``` inj` **x** `` ``` |' "$WORK/md.summary" && grep -qF 'MCP server ``n`\|`m``' "$WORK/md.summary" &&
  grep -qF '&#42;&#42;Approved&#42;&#42; by &#91;security&#93;&#40;https' "$WORK/md.summary"; then
  pass "$t"
else
  fail "$t" "$(cat "$WORK/md.summary")"
fi

t=run-refused-body-holds-and-fails
respond '[{"status":400,"body":{"error":"bad_files","hint":"files: ..."}}]'
run refused ON_ERROR=warn FAIL_ON=block
if [ "$RC" = 1 ] && grep -q '^decision=hold$' "$WORK/refused.output" && grep -q '^::error title=alalanet::alalanet refused the files sent (HTTP 400 bad_files)' "$WORK/refused.log" &&
  ! grep -q '^::warning title=alalanet::alalanet could not check' "$WORK/refused.log"; then
  pass "$t"
else
  fail "$t" "rc=$RC $(cat "$WORK/refused.log")"
fi

t=run-local-hold-raises-allow
R2="$R"
R="$(newrepo localhold)"
printf 'x\n' >"$R/AGENTS.md"
ln -s /etc/hostname "$R/CLAUDE.md"
commit "$R"
respond "[{\"status\":200,\"body\":$ALLOW}]"
run localhold FAIL_ON=hold
[ "$RC" = 1 ] && grep -q '^decision=hold$' "$WORK/localhold.output" && grep -q '^::warning file=CLAUDE.md,title=alalanet check_incomplete%3Asymlink::' "$WORK/localhold.log" && pass "$t" || fail "$t" "rc=$RC $(cat "$WORK/localhold.log")"
R="$R2"

t=run-nothing-to-send
R2="$R"
R="$(newrepo empty)"
printf 'x\n' >"$R/README.md"
commit "$R"
respond "[{\"status\":200,\"body\":$ALLOW}]"
run empty
[ "$RC" = 0 ] && [ "$(reqs)" = 0 ] && grep -q '^decision=allow$' "$WORK/empty.output" && pass "$t" || fail "$t" "rc=$RC reqs=$(reqs) $(cat "$WORK/empty.log")"
R="$R2"

t=run-quota-not-retried-fails
respond '[{"status":429,"headers":{"Retry-After":"3600"},"body":{"error":"quota_exceeded","hint":"Daily limit."}}]'
run quota
[ "$RC" = 1 ] && [ "$(apireqs)" = 1 ] && grep -q '^::error title=alalanet::' "$WORK/quota.log" && pass "$t" || fail "$t" "rc=$RC api=$(apireqs) $(cat "$WORK/quota.log")"

t=run-quota-on-error-warn
respond '[{"status":429,"body":{"error":"quota_exceeded","hint":"Daily limit."}}]'
run quotawarn ON_ERROR=warn
[ "$RC" = 0 ] && grep -q '^::warning title=alalanet::' "$WORK/quotawarn.log" && ! grep -q '^decision=allow$' "$WORK/quotawarn.output" && pass "$t" || fail "$t" "rc=$RC $(cat "$WORK/quotawarn.log")"

t=run-retries-busy-with-fresh-token
respond "[{\"status\":503,\"headers\":{\"Retry-After\":\"1\"},\"body\":{\"error\":\"restarting\"}},{\"status\":429,\"body\":{\"error\":\"host_busy\"}},{\"status\":200,\"headers\":{\"X-Alalanet-Quota\":\"github-repository\"},\"body\":$ALLOW}]"
run retry ACTIONS_ID_TOKEN_REQUEST_URL="$API/idtoken?api-version=2.0" ACTIONS_ID_TOKEN_REQUEST_TOKEN="req$(printf -- '-tok')"
toks="$(cat "$SRV"/req-*.json | jq -rs '[.[] | select(.path == "/v1/repo-config-check") | .headers["x-alalanet-github-oidc"]] | join(",")')"
aud="$(cat "$SRV"/req-*.json | jq -rs '[.[] | select(.path | startswith("/idtoken")) | .path] | first')"
auth="$(cat "$SRV"/req-*.json | jq -rs '[.[] | select(.path | startswith("/idtoken")) | .headers.authorization] | first')"
leak="$(grep -v '^::add-mask::' "$WORK/retry.log" | grep -c 'fake-oidc-' || true)"
if [ "$RC" = 0 ] && [ "$(apireqs)" = 3 ] && [ "$toks" = "fake-oidc-1,fake-oidc-2,fake-oidc-3" ] &&
  [ "$aud" = "/idtoken?api-version=2.0&audience=$(jq -rn --arg a "$API" '$a|@uri')" ] && [ "$auth" = "bearer req-tok" ] &&
  [ "$leak" = 0 ] && grep -qi "this repository" "$WORK/retry.summary"; then
  pass "$t"
else
  fail "$t" "rc=$RC api=$(apireqs) toks=$toks aud=$aud auth=$auth leak=$leak $(cat "$WORK/retry.log")"
fi

t=run-oidc-off
respond "[{\"status\":200,\"body\":$ALLOW}]"
run oidcoff OIDC=off ACTIONS_ID_TOKEN_REQUEST_URL="$API/idtoken?api-version=2.0" ACTIONS_ID_TOKEN_REQUEST_TOKEN=x
[ "$RC" = 0 ] && [ "$(reqs)" = 1 ] && [ "$(jq -r '.headers["x-alalanet-github-oidc"] // "none"' "$SRV/req-1.json")" = none ] && pass "$t" || fail "$t" "rc=$RC reqs=$(reqs)"

t=run-empty-answer-fails
respond '[{"status":200,"body":""}]'
run emptyanswer ON_ERROR=fail
[ "$RC" = 1 ] && grep -q "has no decision" "$WORK/emptyanswer.log" && ! grep -q '^decision=' "$WORK/emptyanswer.output" && pass "$t" || fail "$t" "rc=$RC $(cat "$WORK/emptyanswer.log")"

t=run-bad-input
run badinput FAIL_ON=sometimes
[ "$RC" = 2 ] && pass "$t" || fail "$t" "rc=$RC"

t=run-server-error-fails
respond '[{"status":400,"body":{"error":"bad_files","hint":"files: paths from the repository root"}}]'
run badfiles
[ "$RC" = 1 ] && grep -q 'bad_files' "$WORK/badfiles.log" && pass "$t" || fail "$t" "rc=$RC $(cat "$WORK/badfiles.log")"

t=review-r3-proofs
# the round 3 re-review's proofs (review_r3_proof.sh): C1, C3 and C4 printed PROOF on f8819f1
proofs="$(bash "$HERE/review_r3_proof.sh" 2>&1)"
if printf '%s\n' "$proofs" | grep -q '^PROOF'; then fail "$t" "$proofs"; else pass "$t"; fi

t=review-r2-proofs
# the re-review's proofs of round 2 (review_r2_proof.sh); A runs only as root with setpriv
proofs="$(bash "$HERE/review_r2_proof.sh" 2>&1)"
if printf '%s\n' "$proofs" | grep -q '^PROOF'; then fail "$t" "$proofs"; else pass "$t"; fi

t=review-proofs
# the independent review's proofs of round 1 (review_proof.sh): each prints PROOF while its finding holds
proofs="$(bash "$HERE/review_proof.sh" 2>&1)"
if printf '%s\n' "$proofs" | grep -q '^PROOF'; then fail "$t" "$proofs"; else pass "$t"; fi

echo
if [ "$fails" -ne 0 ]; then
  echo "$fails test(s) failed"
  exit 1
fi
echo "all tests passed"
