# dictator

[![test](https://github.com/jindrichskupa/dictator/actions/workflows/test.yml/badge.svg)](https://github.com/jindrichskupa/dictator/actions/workflows/test.yml)

One registry of your Claude Code sessions **across every repository**: what is
running, what is waiting for you, what a reboot killed — and one keystroke to
any of it.

```
● running  fix billing rounding      acme/api ⑂             12m  acme-1234
◆ waiting  refactor auth middleware  acme/wallet             3h  abc-99
✓ done     bump helm chart           contoso/cms/helm        1d  helm-42
✗ dead     upgrade traefik           contoso/cms/terraform   2d  traefik-v41
```

## Why

Tools that run several agents in parallel already exist. They are scoped to
**one repository**: you start them inside a checkout and see that checkout's
sessions. If your work is spread over dozens of repositories, running one
instance per repository reproduces exactly the problem you were trying to
solve — no single place answers *"what am I working on, where, and in what
state?"*

dictator is that single place. It does not replace Claude Code's own features;
it deliberately reuses them (`--session-id`, `--resume`, `git worktree`) and
adds only the missing part: a registry that spans repositories, live state, and
fast switching.

## Requirements

`zsh`, `tmux` 3.2+ (for `display-popup`), `fzf`, `jq`, `git`, and
[Claude Code](https://claude.com/claude-code).

Developed on macOS. On Linux, `_dict_age` and `_dict_last_activity` use BSD
`date`/`stat` flags and need adjusting — see [Portability](#portability).

## Install

Clone it anywhere; nothing hardcodes the location.

### Homebrew

```bash
brew install jindrichskupa/tap/dictator
```

The formula prints the two lines you need afterwards. Dependencies (`tmux`,
`fzf`, `jq`) come with it.

### Clone

```bash
git clone https://github.com/jindrichskupa/dictator ~/.local/share/dictator
```

**1. Load the plugin** — add to `~/.zshrc` (Homebrew installs print their own
path; `brew --prefix dictator` gives it):

```zsh
source ~/.local/share/dictator/dictator.plugin.zsh
```

It is an ordinary zsh plugin, so a plugin manager works too:

```zsh
# zinit
zinit light jindrichskupa/dictator

# antidote — add to your plugins file
jindrichskupa/dictator

# oh-my-zsh
git clone https://github.com/jindrichskupa/dictator \
  ~/.oh-my-zsh/custom/plugins/dictator     # then add `dictator` to plugins=(…)
```

**2. Register the hooks** — merge into the `hooks` object of
`~/.claude/settings.json`, replacing `<DICTATOR>` with the clone path. If that
file already has hooks, **add** to it rather than overwriting.

```json
{
  "UserPromptSubmit": [
    { "hooks": [{ "type": "command", "command": "<DICTATOR>/hooks/dict-status.sh running" }] }
  ],
  "Notification": [
    { "hooks": [{ "type": "command", "command": "<DICTATOR>/hooks/dict-status.sh waiting" }] }
  ],
  "Stop": [
    { "hooks": [{ "type": "command", "command": "<DICTATOR>/hooks/dict-status.sh done" }] }
  ],
  "SessionEnd": [
    { "hooks": [{ "type": "command", "command": "<DICTATOR>/hooks/dict-status.sh ended" }] }
  ]
}
```

Nothing is added to `~/.tmux.conf` — dictator brings its own, see
[Isolation](#isolation).

Without the hooks everything works except the state column, which stays
`unknown`. The hook exits silently for any Claude Code session dictator did not
start, so your other sessions are unaffected.

## Commands

| | |
|---|---|
| `dict new [--refresh]` | pick a repository, name the work, optionally get a worktree |
| `dict ls` | every session with its state and age |
| `dict sw [query]` | switch; a query matching one session goes straight there |
| `dict up [id…]` | revive sessions a reboot killed, conversation intact |
| `dict cd [id]` | move the calling shell into a session's directory |
| `dict note <id> <text>` | annotate |
| `dict rename [id] [title…]` | retitle a session; the id, branch and worktree stay as they are |
| `dict kill [id…]` | stop a session, keep it in the list |
| `dict rm [id…]` | end sessions for good |
| `dict prune [days]` | forget everything stale (default: 7 days) |
| `dict help` | every command, key and state |
| `dict reload` | re-source the library after editing it |

## Keys

The prefix is `C-a`. dictator's tmux server has its own config, so this does
not affect your other tmux sessions.

| | |
|---|---|
| `prefix N` | new session |
| `prefix S` | switch — fzf, with a live preview of each pane |
| `prefix R` | rename a session (title only) |
| `prefix K` | stop a session (reversible) |
| `prefix X` | forget a session (permanent) |
| `prefix Enter` | a shell in the session's directory, as a popup |
| `prefix c` / `\|` / `-` | the same as a window / horizontal split / vertical split |
| `prefix ?` | help |
| `prefix r` | reload the tmux config |
| `prefix w` `(` `)` `L` `d` | tree, previous, next, last, detach — native tmux |

In the picker, typing filters on title, repository and id at once.

`prefix Enter` is the one worth remembering: a throwaway shell already in the
session's directory (worktree included), for everything that is quicker to type
than to ask for. Close it and you are back in the conversation.

## States

| | |
|---|---|
| `● running` | Claude is working |
| `◆ waiting` | **Claude wants input or permission** |
| `✓ done` | Claude finished its turn |
| `· ended` | the session was closed |
| `✗ dead` | registered, but not running — usually a reboot; `dict up` it |
| `! orphan` | its directory is gone |

The first four are written by the Claude Code hooks. `dead` and `orphan` are
derived when the list is read, because after a reboot no hook will ever fire
again.

## How it works

### A session is a tmux session running Claude

Claude is the session's **first process**, not something typed into a shell
afterwards:

```
zsh -ic 'eval "$(direnv export zsh)"; claude --session-id <uuid>
         rc=$?; (( rc )) && { print "exited with $rc"; exec zsh }'
```

- `zsh -ic` gives it your full interactive environment
- `direnv export` is explicit because direnv's hook runs on `precmd`, which
  never fires when zsh is handed a command up front
- quitting Claude closes the tmux session, so finished work does not leave
  empty shells behind. A **non-zero** exit drops to a shell instead — a session
  that vanishes takes its error message with it

Deliberately not `tmux send-keys`: that types into a shell that may still be
starting and loses characters when it loses the race.

### Resume is addressed, not guessed

`dict new` generates a UUID and passes `--session-id <uuid>`, so the
conversation has a known address from the start. `dict up` recreates the tmux
session and runs `claude --resume <uuid>`. No picker, no matching on titles.

If the transcript is gone, `dict up` says so and starts a fresh conversation in
the right directory rather than failing. Nothing starts at boot — reviving
everything unconditionally would resurrect work that was already finished.

### Stopping versus ending

| | | |
|---|---|---|
| `dict kill` | `prefix K` | stops the process; record, worktree and conversation stay. `dict up` brings it all back. |
| `dict rm` | `prefix X` | forgets it. Irreversible, and always asks first. |

`dict prune [days]` is the weekly sweep: everything not alive and untouched for
longer than the window, listed, then forgotten on one confirmation. Running and
waiting sessions are never offered however old they are — age is not
abandonment while something is still working. "Untouched" means the last time a
hook fired, not when the session was created.

**A worktree that still holds work is never deleted**, by any of these. The
registry entry goes, the directory stays, and you are told where it is. "Holds
work" means uncommitted changes, commits on no other branch, or a directory git
cannot make sense of — undeterminable counts as work, because deleting is the
irreversible direction.

### Isolation

dictator runs its **own tmux server**, on its own socket and its own config:

```
tmux -L dictator -f <clone>/tmux/dictator.conf
```

- Its sessions are invisible to `tmux ls` and untouched by `tmux kill-server`
  on the default socket, and vice versa. Another tool driving tmux cannot take
  dictator's sessions down, and dictator cannot take that tool's.
- `~/.tmux.conf` is neither read nor written. `tmux/dictator.conf` is the only
  configuration these sessions obey; edit it and press `prefix r`.

`tmux/dictator.conf` is a **template**. Absolute paths are substituted into
`$DICTATOR_STATE/tmux.conf`, and that generated file is what tmux loads.
Deliberately not `$DICTATOR_HOME` in the config itself: tmux expands variables
at parse time from whatever environment triggered the load, and a
`tmux source-file` run from an ordinary shell has no `DICTATOR_HOME` — which
silently turned every popup into `source /dictator.plugin.zsh` and made it
flash and vanish.

Attach by hand with `tmux -L dictator attach`.

### Data

Everything lives in `$DICTATOR_STATE` (default `~/.local/state/dictator`):

```
sessions.jsonl          one JSON object per session, append-only
tmux.conf               generated from tmux/dictator.conf, with real paths
state/<id>.status       "<state> <timestamp>", rewritten by the hooks
repos.cache             discovered repositories, refreshed daily
worktrees/<repo>/<id>   worktrees dictator created
```

The registry is a plain text file on purpose. A different front end — a TUI, a
status bar, a script — is another reader of the same data, not a rewrite.

## Configuration

| Variable | Default |
|---|---|
| `DICTATOR_ROOTS` | `($HOME/Work $HOME/Src)` — a zsh **array** of directories to search for repositories |
| `DICTATOR_STATE` | `~/.local/state/dictator` |
| `DICTATOR_PROGRAM` | `claude` — the program a session starts |
| `DICTATOR_SOCKET` | `dictator` — the tmux socket name |
| `DICTATOR_TEMPLATE` | `<clone>/tmux/dictator.conf` — the tmux config template |
| `DICTATOR_CONF` | `$DICTATOR_STATE/tmux.conf` — the generated file tmux loads |

Set them in `~/.config/dictator/config`, which is sourced if present:

```zsh
DICTATOR_ROOTS=(~/code ~/work ~/src)
```

Repository discovery looks for `.git` under those roots, up to six levels deep,
so both `~/work/client/project` and `~/src/host/org/repo` are found. A `.git`
*file* counts too, so existing worktrees show up.

## Portability

Two helpers use BSD (macOS) flags and are the only things standing between this
and Linux:

- `_dict_age` — `date -u -j -f <format>`; GNU is `date -u -d`
- `_dict_last_activity` — `stat -f %m`; GNU is `stat -c %Y`

Patches welcome.

## Releases

Versions are git tags. Pushing `vX.Y.Z` runs the suite and, only if it passes,
publishes a GitHub release with generated notes and updates the Homebrew
formula in `jindrichskupa/homebrew-tap`:

```bash
git tag -a v0.1.0 -m 'v0.1.0'
git push origin v0.1.0
```

To install a specific version, check out the tag in your clone:

```bash
git -C ~/.local/share/dictator fetch --tags
git -C ~/.local/share/dictator checkout v0.1.0
```

## Tests

```bash
zsh test/dict_test.sh
```

CI runs the suite on macOS for every push and pull request, plus a parse check
of every file on Linux.

128 assertions, no framework. The suite points `DICTATOR_STATE` at a temp
directory and `DICTATOR_SOCKET` at a per-run socket, so it can never touch real
state or a real tmux server — one test asserts exactly that. It creates and
kills real tmux sessions and real git worktrees rather than mocking them.

## Prior art

[claude-squad](https://github.com/smtg-ai/claude-squad) is the closest thing and
worth using if you work in one repository at a time; multi-repository support is
an [open request](https://github.com/smtg-ai/claude-squad/issues/56).
[Conductor](https://conductor.build) and
[Crystal](https://github.com/stravu/crystal) solve a similar problem with a GUI.

## License

MIT — see [LICENSE](LICENSE).
