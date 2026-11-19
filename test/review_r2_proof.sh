#!/usr/bin/env bash
# Reviewer's proofs for CI-ACT-1 round 2 (untracked). "PROOF" lines: a stated property that does not hold.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$(dirname "$HERE")/check.sh"
WORK="$(mktemp -d)"
chmod 755 "$WORK"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# A. git refuses the checkout (another user owns it: "detected dubious ownership", as in container jobs and
# self-hosted runners whose workspace another account made): git_in_root is false and the Action falls back to
# find, which sends untracked files on disk -- an .npmrc an earlier step wrote with a registry token. Needs root
# (run as root in a container: the repository is made as root, the Action runs as nobody).
if [ "$(id -u)" = 0 ] && command -v setpriv >/dev/null; then
  R="$WORK/owned"
  mkdir -p "$R" && git -C "$R" init -q && printf 'x\n' >"$R/AGENTS.md" && git -C "$R" add -A && git -C "$R" commit -qm t
  printf '//registry.npmjs.org/:_authToken=%s\n' "$(printf '%s' 'npm_' 'NOTAREALTOKEN')" >"$R/.npmrc" # untracked
  chmod -R a+rX "$R"
  mkdir -p "$WORK/outA" && chmod 777 "$WORK/outA"
  setpriv --reuid=65534 --regid=65534 --clear-groups env HOME=/tmp TMPDIR=/tmp INPUT_PATH="$R" bash "$CHECK" collect "$WORK/outA" 2>/dev/null
  if jq -r '.files[".npmrc"] // ""' "$WORK/outA/body.json" | grep -q '_authToken'; then
    echo "PROOF A git-refused-fallback: an untracked .npmrc (registry token) is sent when git refuses the checkout"
  else echo "ok    A git refusal does not send untracked files ($(jq -c '.files|keys' "$WORK/outA/body.json"))"; fi
else
  echo "skip  A (needs root and setpriv)"
fi

# B. .env: Go's strings.TrimSpace trims Unicode spaces (U+00A0, U+0085, U+3000...), so the server's dotenv reads
# "<NBSP>HTTPS_PROXY=..." as HTTPS_PROXY (node's dotenv too: JS \s has NBSP); the Action's [[:space:]] does not,
# drops the line, and the proxy the server would hold is never sent.
R="$WORK/nbsp"
mkdir -p "$R" && git -C "$R" init -q
printf '\302\240HTTPS_PROXY=http://proxy.evil.example:8080\nHTTP_PROXY\302\240=http://proxy.evil.example:8080\n' >"$R/.env"
git -C "$R" add -A && git -C "$R" commit -qm t
mkdir -p "$WORK/outB" && INPUT_PATH="$R" bash "$CHECK" collect "$WORK/outB"
sent="$(jq -r '.files[".env"] // "(no .env)"' "$WORK/outB/body.json")"
case "$sent" in
  *proxy.evil.example*) echo "ok    B NBSP lines sent" ;;
  *) echo "PROOF B env-unicode-space: the server reads these two lines as HTTPS_PROXY/HTTP_PROXY; the Action sent [$sent]" ;;
esac
