# Agent config check by alalanet — GitHub Action

Opening a repository in an AI coding agent or an editor can start its MCP servers, run its hooks and tasks, widen
the agent's permissions, point the model API at another host and load its instruction files into the model's
context. This Action checks that configuration on every pull request, before anyone opens the branch in an agent:
the same check as alalanet's `check_repo_config` (<https://alalanet.com>), with the verdict as the job's result,
annotations on the files and a table in the job summary.

```yaml
on: pull_request            # never pull_request_target: nothing here needs a secret or a write token
permissions:
  contents: read
jobs:
  check:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write       # optional: this repository's own quota (see "Limits")
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6.1.0
        with:
          persist-credentials: false
      - uses: alalanet/agent-config-check-action@v1
        # with:
        #   fail-on: block     # or hold
        #   on-error: fail     # or warn
        #   github-oidc: auto  # or off
        #   path: .            # the folder an agent opens
```

A full workflow is in [`examples/agent-config-check.yml`](examples/agent-config-check.yml).

## What it does

- `allow`: nothing found. `hold`: read the named files before trusting the configuration (hooks, broad permissions,
  servers or skills that download and run code, a model API or proxy pointed elsewhere, injection-like
  instructions, committed secrets…). `block`: do not open the repository with its configuration trusted (a
  known-malicious MCP server, a task that downloads and runs code when the folder opens, invisible Unicode tag
  characters in an instruction file).
- The step fails on `block` (or on `hold` with `fail-on: hold`). Each finding is an annotation on its file; the
  summary lists the findings, the MCP servers that are not `allow`, and a link to the signed record.
- When alalanet cannot check (the daily limit, an outage), the step fails with `on-error: fail` (the default: a
  green check that checked nothing would be a false one), or warns with `on-error: warn`. When alalanet refuses
  the files themselves (HTTP 400), the verdict is `hold` and the step fails whatever `fail-on` and `on-error` say:
  the pull request's configuration was not checked.
- Outputs: `decision`, `attestation` (the id of the signed statement), `files-sha256`.
- Addresses in the summary (`https://`, `www.`, `@`) carry an invisible joiner on purpose, so that text quoted from a
  pull request never becomes a link there: copy a URL or a package name from the annotations, which are plain text.

## What is sent — read this before installing

Installing this Action is the repository owner's choice. When it runs, it sends **the contents of the
repository's agent configuration files** to `https://alalanet.com/v1/repo-config-check` over HTTPS. For a private
repository, that means these files leave GitHub for alalanet. Exactly these paths, without case, as git tracks them
in the checkout (read from git's index, so a file an earlier step wrote or changed is not what is sent):

- MCP and client settings: `.mcp.json` (also in subfolders), `.cursor/mcp.json`, `.vscode/mcp.json`,
  `.vscode/settings.json`, `.vscode/tasks.json`, `.gemini/settings.json`, `.zed/settings.json`, `.github/mcp.json`,
  `.claude/settings.json`, `.claude/settings.local.json`, `.codex/config.toml`, `.github/copilot/settings.json`,
  `.github/copilot/settings.local.json`, `.devcontainer.json`, `.devcontainer/devcontainer.json`,
  `.devcontainer/<name>/devcontainer.json`;
- hooks: `.cursor/hooks.json`, `.codex/hooks.json`, `.github/hooks/<name>.json`;
- instructions: `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md` (also in subfolders), `GEMINI.md`, `.cursorrules`,
  `.clinerules`, `.windsurfrules`, `.github/copilot-instructions.md`, and Markdown (`.md`, `.mdc`) under
  `.claude/agents|commands|skills|rules|output-styles/`, `.cursor/rules/`, `.github/instructions|prompts|agents/`,
  `.agents/skills/`, `.windsurf/rules/`, `.clinerules/`;
- package registry settings an MCP launcher reads: `.npmrc`, `.yarnrc`, `.yarnrc.yml`, `bunfig.toml`, `uv.toml`,
  `pyproject.toml`; alalanet's own policy file `.alalanet.yml`;
- from `.env` and `.gemini/.env`, **only the lines** that set exactly one of these variables (spaces and `export `
  allowed before the name, as alalanet reads them): `ANTHROPIC_BASE_URL`, `ANTHROPIC_BEDROCK_BASE_URL`,
  `ANTHROPIC_VERTEX_BASE_URL`, `ANTHROPIC_FOUNDRY_BASE_URL`, `OPENAI_BASE_URL`, `OPENAI_API_BASE`,
  `GOOGLE_GEMINI_BASE_URL`, `HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY`, `CODEX_HOME`, `NODE_OPTIONS`, `LD_PRELOAD`,
  `DYLD_INSERT_LIBRARIES`, `PYTHONSTARTUP`, `BASH_ENV`, `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`.
  Every other line, such as an API key, stays on the runner.

At most 40 files, 2 MB of content and 3 MB of request in one check; a file over 256 KiB, or a path with a backslash
or over 300 bytes, is not sent, and the verdict says so (`hold`). A symbolic link is followed as alalanet's
repository check follows it: only when git tracks it as a link and its target is a tracked file or folder of the
checkout. A link to another link, to an untracked file, into `.git` or out of the checkout is not followed and holds.
Links work the same on Windows runners, where git checks them out as plain files.

The Action reads the folder's own checkout only: git variables an earlier step left in the environment (`GIT_DIR`,
`GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_CONFIG_*` and the like) are ignored, and nothing a git configuration names
(an fsmonitor hook, hooks) is run. When git cannot list the index (a corrupt index, a bare repository), nothing is
sent and the verdict is `hold`.

When git cannot read the checkout (another account owns it, as in some container jobs and self-hosted runners:
add it to git's `safe.directory`; or its `.git` is broken) or git is not installed, the Action sends **nothing**:
it cannot tell what git tracks from what an earlier step wrote, and the verdict is `hold`. Only in a folder with no
`.git` anywhere above it (not a git checkout at all) does it send the listed files as they are on disk, untracked
ones included, and it follows no symbolic link there.

Nothing else leaves the runner: no source code and no other file. (The OIDC token below, when sent, carries what
GitHub puts in it.) alalanet reads the files to answer and does not store them; the answer is held in memory for 10 minutes
under a hash of the files. The public signed record of the check holds only the decision, bare reason codes and a
salted hash of the files: no paths, names or contents. Details: <https://alalanet.com/privacy>.

With `id-token: write` on the repository's own runs, the Action also sends a GitHub OIDC token whose audience is
`https://alalanet.com`. GitHub puts in it the repository's name and id, its owner, the ref, the commit, the event,
the workflow and who ran it. alalanet checks its signature against GitHub's published keys, uses the repository's
numeric id as the key of this repository's daily limits for that UTC day (kept in memory only) and keeps nothing
else from it; each token is accepted once. Without `id-token: write`, or with `github-oidc: off`, no token is sent.

## Limits

Free, no account, no token. Each check counts one of the free daily checks (100 a day, more for each MCP server the
files name — see <https://alalanet.com/pricing>); the same files checked again within 10 minutes count nothing.
GitHub's hosted runners share addresses, so without a token the daily limit is shared with every other job on the
same address. With `id-token: write`, the repository's own runs count against daily limits of their own (every limit an
address has); when they are spent, the runs are refused until 00:00 UTC rather than moved to the address. A fork's
pull request gets no token from GitHub and counts against the address.

Two settings give a fork's code tokens for **your** repository, so a fork could spend your repository's day:
`pull_request_target` with `id-token: write` (never use it with this Action: it also runs with your secrets), and,
on a private repository, "Send write tokens to workflows from fork pull requests". With either on, set
`github-oidc: off`.

Needs `bash`, `curl`, `jq`, `git` and `realpath` (all present on GitHub-hosted runners). The Action uses no other
action and downloads nothing.

License: MIT-0.
