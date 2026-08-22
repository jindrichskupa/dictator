# lib/core.zsh — shared helpers. Sourced eagerly by dictator.plugin.zsh.
# Everything here is prefixed _dict_ and is private to the plugin.

_dict_state_dir() {
  local d=${DICTATOR_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/dictator}
  [[ -d $d/state ]] || mkdir -p $d/state
  print -r -- $d
}

# dictator runs its own tmux server, on its own socket and its own config file.
# Nothing here can reach — or kill — sessions on the default server, and no
# other tool's config can change how these sessions behave.
# Attach by hand with:  tmux -L dictator attach
_dict_socket() { print -r -- "${DICTATOR_SOCKET:-dictator}" }

_dict_template() { print -r -- "${DICTATOR_TEMPLATE:-$DICTATOR_HOME/tmux/dictator.conf}" }
_dict_conf()     { print -r -- "${DICTATOR_CONF:-$(_dict_state_dir)/tmux.conf}" }

# The template carries @DICTATOR_HOME@ and @CONF@ rather than $DICTATOR_HOME,
# and zsh substitutes them here. tmux would expand a $VAR at parse time using
# whatever environment triggered the load, and every `tmux source-file` run
# outside this plugin — `prefix r` included — has no DICTATOR_HOME. That
# produced bindings reading `source /dictator.plugin.zsh`: popups that flashed
# and vanished. Generating the file removes the question entirely.
_dict_gen_conf() {
  local tpl conf
  tpl=$(_dict_template)
  conf=$(_dict_conf)
  [[ -r $tpl ]] || return 0                 # an explicit DICTATOR_CONF needs no template
  [[ -f $conf && $conf -nt $tpl ]] && return 0
  sed -e "s|@DICTATOR_HOME@|${DICTATOR_HOME}|g" -e "s|@CONF@|${conf}|g" \
      $tpl > $conf.$$ && mv $conf.$$ $conf
}

_dict_tmux() {
  _dict_gen_conf
  command tmux -L "$(_dict_socket)" -f "$(_dict_conf)" "$@"
}

_dict_registry()    { print -r -- "$(_dict_state_dir)/sessions.jsonl" }
_dict_status_file() { print -r -- "$(_dict_state_dir)/state/$1.status" }
_dict_now()         { date -u +%Y-%m-%dT%H:%M:%SZ }

_dict_slug() {
  print -r -- "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-40
}

# The first id in the -2, -3 … series that no session holds. Used when the
# suggested id is taken: an id is also a tmux session name and a branch name,
# so two sessions can never share one.
_dict_free_id() {
  local base=$1
  integer n=1
  while _dict_get $base >/dev/null 2>&1; do
    (( n++ ))
    base=${1}-$n
  done
  print -r -- "$base"
}

_dict_require() {
  local c
  local -a missing
  for c in "$@"; do (( $+commands[$c] )) || missing+=$c; done
  (( $#missing )) || return 0
  print -ru2 -- "dict: missing required command(s): ${missing[*]}"
  print -ru2 -- "dict: install with: brew install ${missing[*]}"
  return 1
}

_dict_add() { print -r -- "$1" >> "$(_dict_registry)" }

# Print every well-formed line; warn about the rest instead of dying.
_dict_all() {
  local reg line
  integer n=0
  reg=$(_dict_registry)
  [[ -f $reg ]] || return 0
  while IFS= read -r line; do
    (( n++ ))
    [[ -n $line ]] || continue
    if print -r -- "$line" | jq -e . >/dev/null 2>&1; then
      print -r -- "$line"
    else
      print -ru2 -- "dict: skipping malformed registry line $n"
    fi
  done < $reg
}

_dict_get() {
  local out
  out=$(_dict_all 2>/dev/null | jq -c --arg id "$1" 'select(.id == $id)' | tail -1)
  [[ -n $out ]] || return 1
  print -r -- "$out"
}

# Rewrite through a temp file so an interrupted run cannot truncate the registry.
_dict_rewrite() {   # $1 = jq program, remaining args passed to jq
  local reg tmp prog=$1; shift
  reg=$(_dict_registry)
  [[ -f $reg ]] || return 0
  tmp=$(mktemp "${reg}.XXXXXX") || return 1
  if _dict_all 2>/dev/null | jq -c "$@" "$prog" > $tmp; then
    mv $tmp $reg
  else
    rm -f $tmp
    return 1
  fi
}

_dict_set() {
  _dict_rewrite 'if .id == $id then .[$k] = $v else . end' \
    --arg id "$1" --arg k "$2" --arg v "$3"
}

_dict_remove() { _dict_rewrite 'select(.id != $id)' --arg id "$1" }

_dict_status_set() { print -r -- "$2 $(_dict_now)" > "$(_dict_status_file $1)" }

_dict_status_get() {
  local f
  f=$(_dict_status_file $1)
  [[ -f $f ]] || return 1
  local line="$(<$f)"
  print -r -- "${line%% *}"
}

# BSD date on macOS; -j means "do not set the clock", -f gives the input format.
_dict_age() {
  local ts=$1
  integer then now diff
  then=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null) || { print -r -- '?'; return }
  (( then )) || { print -r -- '?'; return }
  now=$(date -u +%s)
  diff=$(( now - then ))
  (( diff < 3600 ))  && { print -r -- "$(( diff / 60 ))m";    return }
  (( diff < 86400 )) && { print -r -- "$(( diff / 3600 ))h";  return }
  print -r -- "$(( diff / 86400 ))d"
}

# orphan and dead are derived, not written: after a reboot no hook will ever fire.
_dict_state_of() {
  local entry dir tname s
  entry=$(_dict_get "$1") || return 1
  dir=$(print -r -- "$entry" | jq -r '.dir')
  [[ -d $dir ]] || { print -r -- orphan; return 0 }
  tname=$(print -r -- "$entry" | jq -r '.tmux')
  _dict_tmux has-session -t "=$tname" 2>/dev/null || { print -r -- dead; return 0 }
  s=$(_dict_status_get "$1") || s=unknown
  print -r -- "$s"
}

_dict_roots() {
  local cfg=${XDG_CONFIG_HOME:-$HOME/.config}/dictator/config
  [[ -r $cfg ]] && source $cfg
  # Not ${DICTATOR_ROOTS:-a b}: zsh does no word splitting, so that default
  # would expand to a single element containing a space.
  local -a roots
  if (( ${+DICTATOR_ROOTS} )) && (( ${#DICTATOR_ROOTS} )); then
    roots=($DICTATOR_ROOTS)
  else
    roots=($HOME/Work $HOME/Src)
  fi
  print -rl -- $roots
}

# `-name .git` matches both a directory (normal clone) and a file (worktree).
_dict_repos() {
  local cache
  cache=$(_dict_state_dir)/repos.cache
  if [[ ${1:-} == --refresh ]] || [[ ! -f $cache ]] || [[ -n $(find $cache -mtime +1 2>/dev/null) ]]; then
    local -a roots
    roots=(${(f)"$(_dict_roots)"})
    roots=(${^roots}(N/))          # drop roots that do not exist
    if (( $#roots )); then
      find $roots -maxdepth 6 -name .git -print 2>/dev/null \
        | sed 's|/\.git$||' | sort -u > $cache
    else
      : > $cache
    fi
  fi
  cat $cache
}

# Creates the worktree at a path we choose, so the registry can record it.
# `claude -w` would also work but picks the path itself.
_dict_worktree_add() {
  # Never name a local `path` here: zsh ties $path to $PATH, so declaring it
  # local empties PATH inside the function and every command goes missing.
  local repo=$1 id=$2 wtpath
  git -C $repo rev-parse --git-dir >/dev/null 2>&1 || {
    print -ru2 -- "dict: not a git repository: $repo"
    return 1
  }
  wtpath=$(_dict_state_dir)/worktrees/${repo:t}/$id
  [[ -e $wtpath ]] && { print -ru2 -- "dict: worktree already exists: $wtpath"; return 1 }
  mkdir -p ${wtpath:h}
  if git -C $repo show-ref --verify --quiet refs/heads/$id; then
    git -C $repo worktree add $wtpath $id >/dev/null 2>&1 || return 1
  else
    git -C $repo worktree add -b $id $wtpath >/dev/null 2>&1 || return 1
  fi
  print -r -- $wtpath
}

# A repository's identity is what is left after the root: ~/Work/acme/api is
# "acme/api", ~/Src/gitlab.com/contoso/cms/backend is "contoso/cms/
# backend". Strip the configured root first — it is the same on every row and
# identifies nothing — then keep up to three components that fit.
_dict_repo_label() {
  local r=${1%/} cand rt
  [[ -n $r ]] || { print -r -- '-'; return }
  for rt in ${(f)"$(_dict_roots)"}; do
    [[ $r == $rt/* ]] && { r=${r#$rt/}; break }
  done
  local -a parts
  parts=(${(s:/:)r})
  (( $#parts )) || { print -r -- '/'; return }
  integer n
  for n in 3 2 1; do
    (( $#parts >= n )) || continue
    cand=${(j:/:)parts[-n,-1]}
    (( ${#cand} <= 28 )) && { print -r -- "$cand"; return }
  done
  print -r -- "${parts[-1]}"
}

# One look for every dialog, so `dict new` and `dict sw` feel like one tool.
# $1 = border label, $2 = header line, rest passed through.
_dict_fzf() {
  local label=$1 header=$2; shift 2
  fzf --ansi --layout=reverse --height=100% \
      --border=rounded --border-label=" $label " --border-label-pos=3 \
      --info=inline-right --separator='' \
      --pointer='▌' --marker='✓' --prompt='  ' \
      --header="$header" --header-first \
      --color='fg:-1,bg:-1,hl:3,fg+:15,bg+:-1,hl+:3:bold,border:6,label:6:bold,prompt:6,pointer:4,marker:2,info:8,header:8,spinner:6,gutter:-1' \
      "$@"
}

# A one-line text prompt that looks like the pickers rather than like `read`.
# fzf with an empty list: whatever is typed comes back as the query.
_dict_ask() {   # $1 = label, $2 = header, $3 = optional default
  local out
  out=$(: | _dict_fzf "$1" "$2" --print-query --query="${3:-}" \
          --height=8 --no-info --preview-window=hidden 2>/dev/null | head -1)
  print -r -- "$out"
}

# A yes/no dialog in the same style. Returns 0 for yes.
_dict_confirm() {   # $1 = label, $2 = question, $3 = default (yes|no)
  local pick
  local -a opts
  [[ ${3:-no} == yes ]] && opts=(yes no) || opts=(no yes)
  pick=$(print -rl -- $opts | _dict_fzf "$1" "$2" --height=8 --no-info --preview-window=hidden)
  [[ $pick == yes ]]
}

_dict_trunc() {   # $1 = text, $2 = width
  local s=$1
  (( ${#s} <= $2 )) && { print -r -- "$s"; return }
  print -r -- "${s[1,$2-1]}…"
}

# One row builder for both `dict ls` and the fzf picker, so they cannot drift.
# Emits:  <id> \x1f <display>
# $1 = 'color' or 'plain', $2 = optional state filter.
_dict_rows() {
  local mode=${1:-plain} only=${2:-} alive=${3:-}
  local -a raw
  raw=(${(f)"$(_dict_all 2>/dev/null | jq -r '[.id, (.title // ""), (.repo // .dir // ""), (.dir // ""), (.tmux // ""), (.worktree | tostring), (.created // ""), (.note // "")] | @tsv')"})
  (( $#raw )) || return 1

  # One tmux query for the whole table, not one per row. _dict_state_of stays
  # for single lookups; here it would cost a jq scan and a tmux round trip per
  # session, which is what made `dict ls` feel slow in a popup.
  local -a live
  live=(${(f)"$(_dict_tmux list-sessions -F '#S' 2>/dev/null)"})

  local -A sym=( running '●' waiting '◆' done '✓' ended '·' dead '✗' orphan '!' unknown '?' )
  local -A col=( running $'\e[34m' waiting $'\e[33;1m' done $'\e[32m' ended $'\e[2m'
                 dead $'\e[31;2m' orphan $'\e[35m' unknown $'\e[2m' )
  local reset=$'\e[0m' dim=$'\e[2m' label_col=$'\e[36m'
  [[ $mode == color ]] || { col=(); reset=''; dim=''; label_col=''; }

  local line id title repo dir tname wt created note state label
  local -a keep
  integer wid=2 wst=0 wti=0 wla=0
  for line in $raw; do
    IFS=$'\t' read -r id title repo dir tname wt created note <<< "$line"
    if [[ ! -d $dir ]]; then
      state=orphan
    elif (( ! ${live[(I)$tname]} )); then
      state=dead
    else
      state=$(_dict_status_get $id) || state=unknown
    fi
    [[ -n $only  && $state != $only ]] && continue
    [[ -n $alive && $state == (dead|orphan) ]] && continue
    title=$(_dict_trunc "$title" 38)
    label=$(_dict_repo_label "$repo")
    [[ $wt == true ]] && label="$label ⑂"
    keep+=("$id"$'\t'"$state"$'\t'"$title"$'\t'"$label"$'\t'"$created"$'\t'"$note")
    (( ${#id}    > wid )) && wid=${#id}
    (( ${#state} > wst )) && wst=${#state}
    (( ${#title} > wti )) && wti=${#title}
    (( ${#label} > wla )) && wla=${#label}
  done
  (( $#keep )) || return 1

  for line in $keep; do
    IFS=$'\t' read -r id state title label created note <<< "$line"
    # Title and repository first: they are what you recognise a session by.
    # The id doubles as the branch name, so it goes last and dimmed.
    print -r -- "$id"$'\x1f'"${col[$state]:-}${sym[$state]:-?} ${(r:$wst:)state}${reset}  ${(r:$wti:)title}  ${label_col}${(r:$wla:)label}${reset}  ${dim}${(l:3:)$(_dict_age "$created")}${reset}  ${dim}${(r:$wid:)id}${reset}${note:+  ${dim}“${note}”${reset}}"
  done
}

# Shared fzf picker over those rows. The id travels in a hidden first field, so
# the visible column layout is free to change without breaking selection.
# DICT_PICK_LINES_ONLY=1 prints the rows and skips fzf, so tests can assert.
_dict_pick() {
  # The verb names the dialog and the enter key: one picker serves sw, kill,
  # rm, up, rename and cd, and they are indistinguishable without it.
  local query='' only='' multi='' alive='' action=switch
  while (( $# )); do
    case $1 in
      --multi)  multi=--multi; shift ;;
      --action) action=$2; shift 2 ;;
      --only)  only=$2; shift 2 ;;
      # "alive" is not a state: running, waiting, done and ended all still have
      # a tmux session behind them. Only dead and orphan do not.
      --alive) alive=yes; shift ;;
      *)       query=$1; shift ;;
    esac
  done

  local -a rows
  rows=(${(f)"$(_dict_rows color "$only" "$alive")"}) || true
  (( $#rows )) || {
    print -ru2 -- "dict: no ${alive:+running }sessions${only:+ in state '$only'}"
    return 1
  }

  if [[ -n ${DICT_PICK_LINES_ONLY:-} ]]; then
    print -rl -- $rows
    return 0
  fi

  # fzf runs the preview in its own shell, where _dict_tmux does not exist —
  # the socket and config must be baked into the command string.
  # The trailing colon matters: capture-pane wants a PANE target, and
  # "=dict-foo" is a SESSION target that it refuses to resolve. "=dict-foo:"
  # means "the active pane of exactly that session" — the "=" keeps tmux from
  # prefix-matching dict-foo against dict-foo-2.
  local preview_cmd="tmux -L $(_dict_socket) capture-pane -pt '=dict-{1}:' 2>/dev/null || echo '(not running)'"

  local header="type to filter by title or repo      enter  $action      esc  cancel"
  [[ -n $multi ]] && header="type to filter      tab  mark      enter  $action      esc  cancel"

  # A query that already narrows it to one session needs no keystroke to
  # confirm: `dict sw helm` should just switch.
  local -a decisive
  [[ -n $query && -z $multi ]] && decisive=(--select-1 --exit-0)

  print -rl -- $rows \
    | _dict_fzf "$action" "$header" \
        --delimiter=$'\x1f' --with-nth=2 $multi --query="$query" $decisive \
        --preview=$preview_cmd \
        --preview-window='right,50%,border-left,follow,<220(down,55%,border-top,follow)' \
    | cut -d $'\x1f' -f1
}

# The projects directory name is derived from the path *and* a hash, so it is
# cheaper to search for the transcript than to recompute the slug.
_dict_transcript_exists() {
  local hit
  hit=$(find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" -name "$1.jsonl" -print -quit 2>/dev/null)
  [[ -n $hit ]]
}

_dict_revive() {
  local id=$1 entry dir tname uuid cmd
  entry=$(_dict_get $id) || { print -ru2 -- "dict: unknown session: $id"; return 1 }
  dir=$(print -r -- $entry | jq -r '.dir')
  [[ -d $dir ]] || { print -ru2 -- "dict: $id: directory is gone ($dir), skipped"; return 1 }

  tname=$(print -r -- $entry | jq -r '.tmux')
  if _dict_tmux has-session -t "=$tname" 2>/dev/null; then
    print -r -- "dict: $id is already running"
    return 0
  fi

  uuid=$(print -r -- $entry | jq -r '.claude_session // ""')
  if [[ -n $uuid && $uuid != null ]] && _dict_transcript_exists $uuid; then
    cmd="$(_dict_program) --resume $uuid"
  else
    print -ru2 -- "dict: $id: no transcript for '$uuid', starting a fresh conversation"
    cmd="$(_dict_program)"
  fi

  if [[ -n ${DICT_REVIVE_DRY_RUN:-} ]]; then
    print -r -- "$cmd"
    return 0
  fi

  _dict_tmux new-session -d -s $tname -c $dir -e DICTATOR_ID=$id \
    "$(_dict_launch_cmd "$cmd")" || return 1
  _dict_status_set $id running
  print -r -- "dict: revived $id"
}

# The program a session runs. Overridable so tests can launch something cheap.
_dict_program() { print -r -- "${DICTATOR_PROGRAM:-claude}" }

# Build the command tmux runs as the session's first process.
#
# Deterministic launch, not `send-keys`: send-keys types into a shell that may
# still be starting (p10k instant prompt, direnv), and races it. Here the shell
# IS the launch, so the program always starts.
#
# `zsh -ic` gives a full interactive environment (~/.zshrc, PATH, tooling).
# direnv is exported explicitly because its hook fires on precmd, which never
# runs when zsh is handed a command up front.
#
# On a clean exit the shell ends with it, so quitting Claude closes the tmux
# session — no empty shells piling up. On a non-zero exit it drops to a shell
# instead, because a session that vanishes takes the error message with it.
_dict_launch_cmd() {   # $1 = program plus arguments, already quoted
  print -r -- "zsh -ic 'command -v direnv >/dev/null 2>&1 && eval \"\$(direnv export zsh)\" 2>/dev/null; $1; rc=\$?; (( rc )) && { print -u2 \"dict: exited with \$rc\"; exec zsh }'"
}

# Last activity, not creation: for deciding what is stale, "when did I last
# touch this" is the useful clock. The status file is rewritten by every hook,
# so its mtime is exactly that. Falls back to the created timestamp.
_dict_last_activity() {   # $1 = id, $2 = created (ISO8601) -> epoch seconds
  local f
  f=$(_dict_status_file $1)
  if [[ -f $f ]]; then
    stat -f %m $f 2>/dev/null && return
  fi
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "${2:-}" +%s 2>/dev/null || print -r -- 0
}

# Does this worktree still hold work that only exists here?
# Returns 0 (yes, keep it) when there are uncommitted changes, or commits that
# are not reachable from the repository's main line, or when we cannot tell.
# Undeterminable counts as "yes" on purpose: deleting is irreversible.
_dict_worktree_has_work() {   # $1 = worktree dir
  local dir=$1 base
  [[ -d $dir ]] || return 1
  git -C $dir rev-parse --git-dir >/dev/null 2>&1 || return 0

  [[ -n $(git -C $dir status --porcelain 2>/dev/null) ]] && return 0

  for base in origin/HEAD origin/main origin/master main master; do
    if git -C $dir rev-parse --verify --quiet $base >/dev/null 2>&1; then
      [[ -n $(git -C $dir log --oneline $base..HEAD 2>/dev/null) ]] && return 0
      return 1
    fi
  done
  return 0
}

# Everything `dict rm` and `dict prune` need to forget one session safely.
_dict_forget() {   # $1 = id
  local id=$1 entry tname dir repo
  entry=$(_dict_get $id) || { print -ru2 -- "dict: unknown session: $id"; return 1 }
  tname=$(print -r -- $entry | jq -r '.tmux')
  dir=$(print -r -- $entry | jq -r '.dir')
  repo=$(print -r -- $entry | jq -r '.repo')

  _dict_tmux kill-session -t "=$tname" 2>/dev/null

  if [[ $(print -r -- $entry | jq -r '.worktree') == true && -d $dir ]]; then
    if _dict_worktree_has_work $dir; then
      print -r -- "dict: $id: worktree kept, it still has work — $dir"
    elif git -C $repo worktree remove --force $dir 2>/dev/null; then
      print -r -- "dict: $id: worktree removed"
    else
      print -ru2 -- "dict: $id: could not remove the worktree, left at $dir"
    fi
  fi

  _dict_remove $id
  rm -f "$(_dict_status_file $id)"
  print -r -- "dict: forgot $id"
}

# Which sessions are safe to propose forgetting: not alive, and untouched for
# longer than $1 days. Running and waiting sessions are never candidates, no
# matter how old — age is not abandonment while something is still working.
_dict_stale() {   # $1 = days
  integer days=${1:-7}
  integer cutoff=$(( $(date -u +%s) - days * 86400 ))
  local line id created state
  while IFS=$'\t' read -r id created; do
    state=$(_dict_state_of $id) || continue
    [[ $state == (dead|ended|orphan|done) ]] || continue
    (( $(_dict_last_activity $id "$created") < cutoff )) && print -r -- $id
  done < <(_dict_all 2>/dev/null | jq -r '[.id, (.created // "")] | @tsv')
}
