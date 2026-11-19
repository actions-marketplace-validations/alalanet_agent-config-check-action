#!/usr/bin/env bash
# Agent config check by alalanet: collects the repository's agent configuration files exactly as alalanet's
# check_repo_config reads them (services/alalanetd/internal/app/repoconfig.go: repoKind, checkRepoFiles,
# followRepoLinks), sends them to POST $API/v1/repo-config-check {"files": {...}} and shows the verdict as the
# step's exit code, annotations and summary. It runs nothing from the repository and needs no write token.
#
#   check.sh                 the Action (inputs from the environment: see action.yml)
#   check.sh collect DIR     only the collection: DIR/body.json (the request body) and DIR/local.jsonl
#   check.sh classify        NUL-separated paths on stdin -> "kind<TAB>order<TAB>path" NUL-separated (tests)
set -euo pipefail

MAX_FILES=40       # repoMaxFiles
MAX_FILE=262144    # repoMaxFile, 256 KiB
MAX_TOTAL=2097152  # checkRepoFiles: 2 MiB in all
MAX_LINKS=20       # maxRepoLinks
MAX_PATH=300       # checkRepoFiles: a path's bytes
MAX_BODY=3141632   # the server reads 3 MiB of request (io.LimitReader 3<<20); 4 KiB kept for the body's own bytes
UA="alalanet-agent-config-action/1 (+https://alalanet.com)"

# git reads only the folder's own checkout: no repository, index, object store or configuration an earlier step put
# in the environment (GITHUB_ENV) decides what is read (round 4, R3-P3-2).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR \
  GIT_NAMESPACE GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
for v in $(compgen -v GIT_CONFIG_KEY_) $(compgen -v GIT_CONFIG_VALUE_); do unset "$v"; done
unset v

# Case without case as the server's strings.ToLower does it: Unicode, not ASCII only (a KELVIN SIGN is a k, and a
# case-insensitive checkout on macOS reads it as one). Collation stays bytewise: every sort here sets LC_ALL=C.
unset LC_ALL
for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
  if locale -a 2>/dev/null | grep -qx "$l"; then
    export LC_CTYPE=$l
    break
  fi
done

# The .env variables the server reads (modelAPIs and envVarsForChecks); every other line stays on the runner.
ENV_NAMES='ANTHROPIC_BASE_URL|ANTHROPIC_BEDROCK_BASE_URL|ANTHROPIC_VERTEX_BASE_URL|ANTHROPIC_FOUNDRY_BASE_URL|OPENAI_BASE_URL|OPENAI_API_BASE|GOOGLE_GEMINI_BASE_URL|HTTPS_PROXY|HTTP_PROXY|ALL_PROXY|CODEX_HOME|NODE_OPTIONS|LD_PRELOAD|DYLD_INSERT_LIBRARIES|PYTHONSTARTUP|BASH_ENV|NODE_EXTRA_CA_CERTS|SSL_CERT_FILE|REQUESTS_CA_BUNDLE'

# UNISPACE_SED: sed expressions that make an ASCII space of each Unicode space Go's unicode.IsSpace takes beyond
# ASCII (U+0085, U+00A0, U+1680, U+2000-U+200A, U+2028, U+2029, U+202F, U+205F, U+3000), as UTF-8 bytes built
# with printf: the script holds none of them raw.
UNISPACE_SED=""
for cp in '\302\205' '\302\240' '\341\232\200' '\342\200\200' '\342\200\201' '\342\200\202' '\342\200\203' '\342\200\204' \
  '\342\200\205' '\342\200\206' '\342\200\207' '\342\200\210' '\342\200\211' '\342\200\212' '\342\200\250' '\342\200\251' \
  '\342\200\257' '\342\201\237' '\343\200\200'; do
  # shellcheck disable=SC2059 # the octal escapes are the format
  UNISPACE_SED="${UNISPACE_SED}s/$(printf "$cp")/ /g;"
done
unset cp

# Folders an agent reads configuration from (configLinkDirs and repoConfigDirs): a link at, above or inside one
# carries configuration (linkMatters).
LINK_DIRS=(.claude/ .cursor/ .vscode/ .github/ .codex/ .gemini/ .zed/ .devcontainer/ .agents/ .windsurf/ .clinerules/
  .claude/agents/ .claude/commands/ .claude/skills/ .claude/rules/ .claude/output-styles/ .cursor/rules/ .github/instructions/
  .github/prompts/ .github/agents/ .agents/skills/ .windsurf/rules/)

# kind_of PATH sets KIND (empty: not read) and PRIO (the order the server reads in) as repoKind does, without case.
kind_of() {
  local p=$1 slashes
  KIND="" PRIO=0
  shopt -s nocasematch
  case "$p" in
    .mcp.json | .cursor/mcp.json | .vscode/mcp.json | .gemini/settings.json | .zed/settings.json | .github/mcp.json) KIND=mcp ;;
    .claude/settings.json | .claude/settings.local.json) KIND=claude ;;
    .vscode/settings.json) KIND=editor ;;
    .vscode/tasks.json) KIND=tasks ;;
    .codex/config.toml) KIND=codex ;;
    .env | .gemini/.env) KIND=dotenv ;;
    .github/copilot/settings.json | .github/copilot/settings.local.json) KIND=copilot ;;
    .cursor/hooks.json | .codex/hooks.json) KIND=hooks ;;
    .devcontainer/devcontainer.json | .devcontainer.json) KIND=devcontainer ;;
    claude.md | claude.local.md | agents.md | gemini.md | .cursorrules | .clinerules | .windsurfrules | .github/copilot-instructions.md) KIND=instructions ;;
    .npmrc | .yarnrc | .yarnrc.yml | bunfig.toml | uv.toml | pyproject.toml) KIND=registry ;;
    .alalanet.yml) KIND=policy ;;
  esac
  if [ -z "$KIND" ]; then
    slashes=${p//[!\/]/}
    case "$p" in
      .github/hooks/*.json) [ ${#slashes} -eq 2 ] && KIND=hooks ;;
    esac
  fi
  if [ -z "$KIND" ]; then
    case "$p" in
      .devcontainer/*/devcontainer.json) [ ${#slashes} -eq 2 ] && KIND=devcontainer PRIO=1 ;;
    esac
  fi
  if [ -z "$KIND" ]; then
    case "$p" in
      */.mcp.json) KIND=mcp PRIO=2 ;;
      .claude/agents/*.md | .claude/agents/*.mdc | .claude/commands/*.md | .claude/commands/*.mdc | .claude/skills/*.md | .claude/skills/*.mdc | \
        .claude/rules/*.md | .claude/rules/*.mdc | .claude/output-styles/*.md | .claude/output-styles/*.mdc | .cursor/rules/*.md | .cursor/rules/*.mdc | \
        .github/instructions/*.md | .github/instructions/*.mdc | .github/prompts/*.md | .github/prompts/*.mdc | .github/agents/*.md | .github/agents/*.mdc | \
        .agents/skills/*.md | .agents/skills/*.mdc | .windsurf/rules/*.md | .windsurf/rules/*.mdc | .clinerules/*.md | .clinerules/*.mdc)
        KIND=instructions PRIO=1 ;;
      */claude.md | */claude.local.md | */agents.md) KIND=instructions PRIO=2 ;;
    esac
  fi
  shopt -u nocasematch
}

# link_matters PATH: a symbolic link there carries configuration (linkMatters).
link_matters() {
  local p=$1 d rc=1
  kind_of "$p"
  [ -n "$KIND" ] && return 0
  shopt -s nocasematch
  for d in "${LINK_DIRS[@]}"; do
    case "$d" in "$p/"*) rc=0 && break ;; esac
    case "$p/" in "$d"*) rc=0 && break ;; esac
  done
  shopt -u nocasematch
  return $rc
}

classify() {
  local p
  while IFS= read -r -d '' p; do
    kind_of "$p"
    printf '%s\t%s\t%s\0' "$KIND" "$PRIO" "$p"
  done
}

# hold FILE REASON DETAIL: a finding of the Action's own (what it could not read or send), as the server words it.
hold() {
  jq -cn --arg f "$1" --arg r "$2" --arg d "$3" '{file: $f, decision: "hold", reason: $r, detail: $d}' >>"$LOCAL"
}

# candidate PATH SOURCE: a configuration file to send under PATH, read from SOURCE: "blob:<sha>" (git's index) or
# "file:<path>" (a folder that is not a git checkout).
candidate() {
  kind_of "$1"
  [ -n "$KIND" ] || return 0
  SRC[NC]=$2
  KINDS[NC]=$KIND
  printf '%s\t%s\t%s\0' "$PRIO" "$1" "$NC" >>"$TMP/candidates"
  NC=$((NC + 1))
}

# git_in_root: the folder is a git work tree (its index says what is tracked, and how).
# Every git call goes through g: the folder's own checkout, and nothing a configuration (the repository's, or one an
# earlier step wrote) names is run: no fsmonitor hook, no hooks, no implicit bare repository (round 4, R3-P3-2).
g() {
  git -c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.untrackedCache=false -c safe.bareRepository=explicit \
    -C "$ROOT" "$@"
}

# git_in_root: the folder is a git work tree (its index says what is tracked, and how). rev-parse must print "true":
# a bare repository (core.bare) exits 0 and prints "false" (round 4, R3-P3-1).
git_in_root() { [ "$(g rev-parse --is-inside-work-tree 2>/dev/null)" = true ]; }

# git_above: a .git (folder or file) in the folder or any folder above it: a checkout, whether git can read it or not.
git_above() {
  local d
  d=$(cd "$ROOT" && pwd -P) || return 1
  while :; do
    [ ! -e "$d/.git" ] || return 0
    [ "$d" != / ] && [ -n "$d" ] || return 1
    d=$(dirname "$d")
  done
}

# git_refusal: why git cannot read a checkout (its first line of error), for the hold that sends nothing.
git_refusal() {
  local why
  why=$(g rev-parse --is-inside-work-tree 2>&1 | head -n 1 | cut -c1-160) || true
  [ "$why" != false ] || why="not a work tree (a bare repository)"
  printf '%s' "${why:-git gave no reason}"
}

# clean_path PATH sets CLEAN to Go's path.Clean of a relative PATH ("." for nothing; ".." kept where it climbs).
clean_path() {
  local IFS=/ part n=0 i
  local -a parts=()
  set -f
  for part in $1; do
    case "$part" in
      "" | .) ;;
      ..)
        if [ "$n" -gt 0 ] && [ "${parts[n - 1]}" != .. ]; then
          n=$((n - 1))
          unset 'parts[n]'
        else
          parts[n]=..
          n=$((n + 1))
        fi
        ;;
      *)
        parts[n]=$part
        n=$((n + 1))
        ;;
    esac
  done
  set +f
  CLEAN=""
  for ((i = 0; i < n; i++)); do CLEAN=${CLEAN:+$CLEAN/}${parts[i]}; done
  [ -n "$CLEAN" ] || CLEAN=.
}

# clip TEXT: at most 80 characters, as the server quotes a link's text.
clip() { if [ "${#1}" -gt 80 ]; then printf '%s...' "${1:0:80}"; else printf '%s' "$1"; fi; }

# follow_link PATH SHA: a symbolic link on a configuration path, read from git's index exactly as the server's
# followRepoLinks reads it from the tree (round 2, P2-1): the link's text, joined to its folder and cleaned, must
# name a tracked file (sent under the link's name) or a folder with tracked files (each under the link's path).
# A text that is empty, absolute or climbs out, a target not in the index (untracked files, .git/*), another link
# or a submodule hold check_incomplete:symlink and nothing is read. Nothing on disk is resolved; on Windows
# (core.symlinks=false) the index still says what is a link.
follow_link() {
  local p=$1 sha=$2 size nul text dir target rec meta mode rest esha path found=0
  size=$(g cat-file -s "$sha" 2>/dev/null) || size=-1
  if [ "$size" -lt 0 ] || [ "$size" -gt 4096 ]; then
    hold "$p" check_incomplete:symlink "the link could not be read"
    return
  fi
  nul=$(g cat-file blob "$sha" | tr -dc '\000' | wc -c | tr -d ' ')
  text=$(g cat-file blob "$sha" && printf x) || text=x
  text=${text%x}
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  case "$text" in
    "" | /* | *$'\n'*)
      hold "$p" check_incomplete:symlink "points outside the repository ($(clip "$text"))"
      return
      ;;
  esac
  if [ "$nul" -gt 0 ] || ! printf '%s' "$text" | LC_ALL=C grep -qE '^[!-~](.*[!-~])?$'; then
    # a byte the server's strings.TrimSpace may read as space (or a NUL): not followed here, held
    hold "$p" check_incomplete:symlink "the link's text is not followed by this Action"
    return
  fi
  dir=${p%/*}
  [ "$dir" != "$p" ] || dir=""
  clean_path "${dir:+$dir/}$text"
  target=$CLEAN
  case "$target" in
    . | .. | ../*)
      hold "$p" check_incomplete:symlink "points outside the repository ($(clip "$text"))"
      return
      ;;
  esac
  while IFS= read -r -d '' rec; do
    meta=${rec%%$'\t'*}
    path=${rec#*$'\t'}
    mode=${meta%% *}
    rest=${meta#* }
    esha=${rest%% *}
    if [ "$path" = "$target" ]; then
      found=1
      case "$mode" in
        120000) hold "$p" check_incomplete:symlink "points to another symbolic link ($(clip "$target"))" ;;
        160000) hold "$p" check_incomplete:symlink "points to $(clip "$target"), which alalanet cannot read (commit)" ;;
        *) candidate "$p" "blob:$esha" ;;
      esac
    elif [ "${path#"$target"/}" != "$path" ]; then
      found=1
      case "$mode" in
        120000) hold "$p/${path#"$target"/}" check_incomplete:symlink "a symbolic link inside a linked folder" ;;
        160000) ;;
        *) candidate "$p/${path#"$target"/}" "blob:$esha" ;;
      esac
    fi
  done < <(g ls-files -s -z -- ":(literal)$target")
  [ "$found" = 1 ] || hold "$p" check_incomplete:symlink "points to $(clip "$target"), which is not in the repository"
}

# body_of SOURCE KIND: what is sent for the file (.env: only the lines that set a variable the server reads, keyed
# exactly as its dotenv reads them: spaces, an optional "export ", the name, spaces, "=").
body_of() {
  case "$1" in
    blob:*) g cat-file blob "${1#blob:}" >"$TMP/raw" ;;
    file:*) cat -- "${1#file:}" >"$TMP/raw" ;;
  esac
  if [ "$2" = dotenv ]; then
    # The server's dotenv trims with strings.TrimSpace, which takes Go's unicode.IsSpace: Unicode spaces too, not
    # only [[:space:]] (round 3, R2-P3-1). They are made ASCII spaces in a copy that is matched; the lines sent
    # are the file's own, by number.
    LC_ALL=C sed -e "$UNISPACE_SED" "$TMP/raw" >"$TMP/norm"
    LC_ALL=C grep -naE "^[[:space:]]*(export )?[[:space:]]*($ENV_NAMES)[[:space:]]*=" -- "$TMP/norm" | cut -d: -f1 >"$TMP/lines" || true
    LC_ALL=C awk 'NR == FNR { keep[$1]; next } FNR in keep' "$TMP/lines" "$TMP/raw"
  else
    cat -- "$TMP/raw"
  fi
}

# raw_size SOURCE: bytes of the file before anything is read.
raw_size() {
  case "$1" in
    blob:*) g cat-file -s "${1#blob:}" 2>/dev/null || echo -1 ;;
    file:*) wc -c <"${1#file:}" | tr -d ' ' ;;
  esac
}

# files_mode_path PATH: a path the server's files mode reads (checkRepoFiles): no backslash, at most 300 bytes.
files_mode_path() {
  case "$1" in *\\*) return 1 ;; esac
  [ "$(printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' ')" -le "$MAX_PATH" ]
}

# collect_disk: a folder with no .git anywhere above it is read from disk as it is; no link is followed there.
collect_disk() {
  local p
  while IFS= read -r -d '' p; do
    p=${p#./}
    if [ -L "$ROOT/$p" ]; then
      if link_matters "$p"; then hold "$p" check_incomplete:symlink "not a git checkout: symbolic links are not followed"; fi
    else
      candidate "$p" "file:$ROOT/$p"
    fi
  done < <(cd "$ROOT" && find . \( -name .git -o -name node_modules \) -prune -o \( -type f -o -type l \) -print0)
}

# collect OUT: OUT/body.json and OUT/local.jsonl.
collect() {
  local out=$1 p rec n size raw frag body sent=0 total=0 more=0 meta mode rest sha nlinks=0
  LOCAL="$out/local.jsonl"
  : >"$LOCAL"
  : >"$TMP/candidates"
  : >"$TMP/fragments"
  : >"$TMP/links"
  NC=0
  SRC=() KINDS=()
  if ! command -v git >/dev/null 2>&1; then
    # what git tracks cannot be told from what an earlier step wrote: nothing is sent (round 3, R2-P2-2)
    hold "" check_incomplete:file_not_read "git is not installed on the runner, so what the checkout tracks cannot be read: nothing was sent"
  elif ! git_in_root; then
    if git_above; then
      # a checkout git refuses (another user owns it, a broken .git, a bare repository): nothing is sent, never the
      # files on disk
      hold "" check_incomplete:file_not_read "git could not read this checkout, so nothing was sent ($(git_refusal)); for a checkout another user owns, add it to git's safe.directory"
    else
      # a folder with no .git anywhere above it: the files on disk, as they are
      collect_disk
    fi
  elif ! g ls-files -s -z >"$TMP/index" 2>"$TMP/giterr"; then
    # git found the work tree but cannot list its index (a corrupt index): an empty listing is not "nothing to
    # check" (round 4, R3-P3-1)
    hold "" check_incomplete:file_not_read "git could not list this checkout's index, so nothing was sent ($(head -n 1 "$TMP/giterr" | cut -c1-160))"
  else
    while IFS= read -r -d '' rec; do
      meta=${rec%%$'\t'*}
      p=${rec#*$'\t'}
      mode=${meta%% *}
      rest=${meta#* }
      sha=${rest%% *}
      [ "${rest##* }" = 0 ] || continue # a merge stage: not a checked-out file
      case "$mode" in
        120000) if link_matters "$p"; then printf '%s\t%s\0' "$p" "$sha" >>"$TMP/links"; fi ;;
        160000) if link_matters "$p"; then hold "$p" check_incomplete:submodule "a submodule on a configuration path is not read"; fi ;;
        *) candidate "$p" "blob:$sha" ;;
      esac
    done <"$TMP/index"
    while IFS= read -r -d '' rec; do
      nlinks=$((nlinks + 1))
      [ "$nlinks" -le "$MAX_LINKS" ] && follow_link "${rec%$'\t'*}" "${rec##*$'\t'}"
    done < <(LC_ALL=C sort -z "$TMP/links")
    if [ "$nlinks" -gt "$MAX_LINKS" ]; then
      hold "" check_incomplete:symlink "$nlinks symbolic links on configuration paths; the first $MAX_LINKS were followed"
    fi
  fi

  body=12 # {"files":{}}
  while IFS= read -r -d '' rec; do
    n=${rec##*$'\t'}
    p=${rec%$'\t'*}
    p=${p#*$'\t'}
    if ! files_mode_path "$p"; then
      hold "$p" check_incomplete:file_not_read "a path alalanet's files mode does not take (a backslash, or over $MAX_PATH bytes)"
      continue
    fi
    raw=$(raw_size "${SRC[n]}")
    if [ "$raw" -lt 0 ]; then
      hold "$p" check_incomplete:file_not_read "git could not read the file"
      continue
    fi
    if [ "$raw" -gt "$MAX_FILE" ]; then
      hold "$p" check_incomplete:file_too_large ""
      continue
    fi
    if ! body_of "${SRC[n]}" "${KINDS[n]}" >"$TMP/one"; then
      hold "$p" check_incomplete:file_not_read "git could not read the file"
      continue
    fi
    size=$(jq -Rrs 'utf8bytelength' <"$TMP/one")
    if [ "$size" -gt "$MAX_FILE" ]; then
      hold "$p" check_incomplete:file_too_large ""
      continue
    fi
    jq -cRs --arg p "$p" '{($p): .}' <"$TMP/one" >"$TMP/frag"
    frag=$(($(LC_ALL=C wc -c <"$TMP/frag") - 3 + 1)) # the member without its braces and newline, and its comma
    if [ "$sent" -ge "$MAX_FILES" ] || [ $((total + size)) -gt "$MAX_TOTAL" ] || [ $((body + frag)) -gt "$MAX_BODY" ]; then
      more=$((more + 1))
      continue
    fi
    cat "$TMP/frag" >>"$TMP/fragments"
    sent=$((sent + 1))
    total=$((total + size))
    body=$((body + frag))
  done < <(LC_ALL=C sort -z "$TMP/candidates")
  if [ "$more" -gt 0 ]; then
    hold "" check_incomplete:more_config_files "$more more configuration files not sent: at most $MAX_FILES files, 2 MB of content and 3 MB of request in one check"
  fi
  jq -cs '{files: (add // {})}' "$TMP/fragments" >"$out/body.json"
}

# ---------------------------------------------------------------------------------------------
# The request and the answer
# ---------------------------------------------------------------------------------------------

# oidc_token: a fresh GitHub OIDC token for our audience, when the workflow granted id-token: write.
oidc_token() {
  TOKEN=""
  [ "$OIDC" = auto ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] || return 0
  printf 'Authorization: bearer %s\n' "$ACTIONS_ID_TOKEN_REQUEST_TOKEN" >"$TMP/idreq"
  local aud
  aud=$(jq -rn --arg a "$API" '$a | @uri')
  if curl -sS -f --max-time 20 -H @"$TMP/idreq" -o "$TMP/id.json" "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${aud}" 2>/dev/null; then
    TOKEN=$(jq -r '.value // empty' "$TMP/id.json" 2>/dev/null || true)
  fi
  rm -f "$TMP/id.json"
  if [ -n "$TOKEN" ]; then
    echo "::add-mask::$TOKEN"
  else
    echo "::notice title=alalanet::no GitHub OIDC token; the check counts against the runner address's daily quota"
  fi
}

# post: sends the body; sets CODE and leaves the answer in $TMP/answer, its headers in $TMP/headers.
post() {
  local attempt delay
  for attempt in 1 2 3 4; do
    oidc_token
    {
      printf 'Content-Type: application/json\n'
      printf 'User-Agent: %s\n' "$UA"
      if [ -n "$TOKEN" ]; then printf 'X-Alalanet-GitHub-OIDC: %s\n' "$TOKEN"; fi
    } >"$TMP/reqhdr"
    TOKEN=""
    : >"$TMP/headers"
    CODE=$(curl -sS --max-time 120 -o "$TMP/answer" -D "$TMP/headers" -w '%{http_code}' -H @"$TMP/reqhdr" \
      --data-binary @"$TMP/body.json" "$API/v1/repo-config-check" 2>"$TMP/curlerr") || CODE=000
    rm -f "$TMP/reqhdr"
    case "$CODE" in
      000 | 502 | 503 | 504) ;;
      429) [ "$(jq -r '.error // ""' "$TMP/answer" 2>/dev/null)" = host_busy ] || return 0 ;;
      *) return 0 ;;
    esac
    [ "$attempt" -lt 4 ] || return 0
    delay=$(tr -d '\r' <"$TMP/headers" | awk 'tolower($1) == "retry-after:" && $2 ~ /^[0-9]+$/ { print $2 }' | tail -n 1)
    delay=${delay:-10}
    [ "$delay" -le "$RETRY_SLEEP_MAX" ] || delay=$RETRY_SLEEP_MAX
    sleep "$delay"
  done
}

# shellcheck disable=SC2016 # jq's own $variables and backticks, not the shell's
# jq definitions: workflow-command escaping; in table cells Markdown and HTML become numeric references, and a
# zero-width joiner (U+200D, jq's escape: no raw character here) breaks "://", "www." and "@", so no bare address
# autolinks (round 3, R2-P3-2). All server text is untrusted.
JQ_DEFS='
def data: tostring | gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A");
def prop: data | gsub(":"; "%3A") | gsub(","; "%2C");
def cell: tostring | gsub("[\r\n]+"; " ") | gsub("(?<c>[&<>|\\\\`*_\\[\\]()!#~])"; "&#\(.c | explode[0]);")
  | gsub("://"; ":\u200d//") | gsub("(?<w>[Ww][Ww][Ww])\\."; "\(.w)\u200d.") | gsub("@"; "\u200d@");
def code: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|") as $c | ([$c | scan("`+") | length] | max // 0) as $n
  | ("`" * ($n + 1)) as $f | if ($c | test("^`|`$")) then "\($f) \($c) \($f)" else "\($f)\($c)\($f)" end;
def level: if . == "block" then "error" elif . == "hold" then "warning" else "notice" end;
'

rank() { case "$1" in block) echo 2 ;; hold) echo 1 ;; *) echo 0 ;; esac; }

fail_service() {
  local msg=$1
  {
    echo "## alalanet agent config check — not checked"
    echo
    printf '%s\n' "$msg" | jq -Rr "$JQ_DEFS"' cell'
  } >>"$SUMMARY"
  if [ "$ON_ERROR" = warn ]; then
    jq -nr --arg m "$msg" "$JQ_DEFS"' "::warning title=alalanet::\($m | data)"'
    exit 0
  fi
  jq -nr --arg m "$msg" "$JQ_DEFS"' "::error title=alalanet::\($m | data)"'
  exit 1
}

run() {
  case "$FAIL_ON" in block | hold) ;; *) echo "::error title=alalanet::fail-on must be block or hold" && exit 2 ;; esac
  case "$ON_ERROR" in fail | warn) ;; *) echo "::error title=alalanet::on-error must be fail or warn" && exit 2 ;; esac
  case "$OIDC" in auto | off) ;; *) echo "::error title=alalanet::github-oidc must be auto or off" && exit 2 ;; esac
  command -v jq >/dev/null || { echo "::error title=alalanet::jq is required on the runner" && exit 2; }
  [ -d "$ROOT" ] || { echo "::error title=alalanet::path is not a folder" && exit 2; }

  collect "$TMP"
  local nsent quota="the runner address's" decision server_decision local_decision att="" refused=""
  nsent=$(jq '.files | length' "$TMP/body.json")

  if [ "$nsent" -eq 0 ]; then
    echo '{"decision":"allow","reasons":[],"advice":"No agent configuration files in this checkout.","findings":[],"mcp_servers":[],"files_read":[]}' >"$TMP/answer"
  else
    post
    if [ "$CODE" = 400 ]; then
      # The server refused the request for what it carries: the pull request's own files. Not "could not check"
      # (which on-error: warn lets pass): a hold that fails the step whatever fail-on says (round 2, P2-2).
      refused="HTTP 400 $(jq -r '.error // ""' "$TMP/answer" 2>/dev/null | tr -cd 'a-z_')"
      hold "" check_incomplete:file_not_read "alalanet refused the files sent ($refused): the check did not run on them"
      echo '{"decision":"hold","reasons":[],"advice":"alalanet refused the files this Action sent, so they were not checked: treat this configuration as unchecked.","findings":[],"mcp_servers":[],"files_read":[]}' >"$TMP/answer"
    elif [ "$CODE" != 200 ]; then
      fail_service "alalanet could not check the files: HTTP $CODE $(jq -r '[.error, .hint] | map(select(. != null)) | join(": ")' "$TMP/answer" 2>/dev/null || head -c 200 "$TMP/curlerr")"
    fi
    if tr -d '\r' <"$TMP/headers" | grep -qi '^x-alalanet-quota: github-repository$'; then quota="this repository's (GitHub OIDC)"; fi
  fi
  # not jq -e: jq 1.6 exits 0 on an empty answer
  case "$(jq -r '.decision // ""' "$TMP/answer" 2>/dev/null)" in allow | hold | block) ;; *) fail_service "alalanet's answer has no decision" ;; esac
  local_decision=$(jq -rs 'if length > 0 then "hold" else "allow" end' "$LOCAL")

  server_decision=$(jq -r '.decision' "$TMP/answer")
  decision=$server_decision
  [ "$(rank "$local_decision")" -le "$(rank "$decision")" ] || decision=$local_decision
  att=$(jq -r '.attestation.event.id // "" | select(test("^[0-9a-f]{64}$"))' "$TMP/answer")

  # Annotations: the server's findings and servers, then the Action's own.
  jq -r "$JQ_DEFS"'
    (.findings // [])[] | . as $f | ($f.decision | level) as $l
      | "::\($l) \(if ($f.file // "") != "" then "file=\($f.file | prop)," else "" end)title=\("alalanet " + $f.reason | prop)::\((if ($f.detail // "") == "" then $f.reason else $f.detail end) | data)"' "$TMP/answer"
  jq -r "$JQ_DEFS"'
    (.mcp_servers // [])[] | select(.decision != "allow") | . as $s | ($s.decision | level) as $l
      | "::\($l) \(if ($s.file // "") != "" then "file=\($s.file | prop)," else "" end)title=\("alalanet MCP server " + $s.name | prop)::\(("\($s.target // "") \($s.decision): " + (($s.reasons // []) | join(", "))) | data)"' "$TMP/answer"
  jq -r "$JQ_DEFS"'
    . as $f | ($f.decision | level) as $l
      | "::\($l) \(if ($f.file // "") != "" then "file=\($f.file | prop)," else "" end)title=\("alalanet " + $f.reason | prop)::\(($f.detail | if . == "" then $f.reason else . end) | data)"' "$LOCAL"

  {
    echo "## alalanet agent config check — **$decision**"
    echo
    jq -r "$JQ_DEFS"' .advice // "" | cell' "$TMP/answer"
    echo
    if [ "$(jq '(.findings | length) + ([.mcp_servers[] | select(.decision != "allow")] | length)' "$TMP/answer")" -gt 0 ] || [ -s "$LOCAL" ]; then
      echo "| decision | file | reason | detail |"
      echo "|---|---|---|---|"
      jq -r "$JQ_DEFS"' (.findings // [])[] | "| \(.decision | cell) | \(.file // "" | cell) | \(.reason | code) | \(.detail // "" | cell) |"' "$TMP/answer"
      jq -r "$JQ_DEFS"' (.mcp_servers // [])[] | select(.decision != "allow") | "| \(.decision | cell) | \(.file // "" | cell) | MCP server \(.name | code) \(.target // "" | cell) | \((.reasons // []) | join(", ") | cell) |"' "$TMP/answer"
      jq -r "$JQ_DEFS"' "| \(.decision | cell) | \(.file | cell) | \(.reason | code) (this Action) | \(.detail | cell) |"' "$LOCAL"
      echo
    fi
    echo "Files sent: $nsent (contents only of the agent configuration files git tracks, listed in the Action's README; no other file leaves the runner). Quota: $quota."
    if [ -n "$att" ]; then
      echo
      echo "Signed record (kind 4315, the decision, reason codes and a salted hash of the files; no paths or names): $API/v1/attestations/$att (log index $(jq -r '.attestation.log_index // "pending" | tostring | select(test("^[0-9a-z]+$"))' "$TMP/answer"))."
    fi
  } >>"$SUMMARY"
  {
    echo "decision=$decision"
    echo "attestation=$att"
    echo "files-sha256=$(jq -r '.files_sha256 // "" | select(test("^[0-9a-f]{64}$"))' "$TMP/answer")"
  } >>"$OUTPUT"

  if [ -n "$refused" ]; then
    echo "::error title=alalanet::alalanet refused the files sent ($refused): this pull request's agent configuration was not checked"
    exit 1
  fi
  if [ "$(rank "$decision")" -ge "$(rank "$FAIL_ON")" ]; then
    echo "::error title=alalanet::agent configuration verdict: $decision (fail-on: $FAIL_ON)"
    exit 1
  fi
  echo "alalanet agent configuration verdict: $decision"
}

ROOT=${INPUT_PATH:-.}
ROOT=${ROOT%/}
[ -n "$ROOT" ] || ROOT=/
API=${API:-https://alalanet.com}
API=${API%/}
FAIL_ON=${FAIL_ON:-block}
ON_ERROR=${ON_ERROR:-fail}
OIDC=${OIDC:-auto}
RETRY_SLEEP_MAX=${RETRY_SLEEP_MAX:-30}
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/null}
OUTPUT=${GITHUB_OUTPUT:-/dev/null}
TOKEN=""
CODE=000
TMP=$(mktemp -d)
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

case "${1:-}" in
  classify) classify ;;
  collect) collect "$2" ;;
  "") run ;;
  *) echo "usage: check.sh [collect DIR | classify]" >&2 && exit 2 ;;
esac
