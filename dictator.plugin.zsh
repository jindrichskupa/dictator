# dictator — one registry of Claude Code sessions across every repository.
#
# Install: add to ~/.zshrc
#   source /path/to/dictator/dictator.plugin.zsh

0=${(%):-%N}
# Exported, not just set: tmux expands $DICTATOR_HOME when it parses
# tmux/dictator.conf, which is what keeps this repository relocatable.
export DICTATOR_HOME=${0:A:h}

source $DICTATOR_HOME/lib/core.zsh

fpath=($DICTATOR_HOME/functions $fpath)
autoload -Uz dict-new dict-adopt dict-ls dict-sw dict-up dict-rm dict-note dict-rename dict-cd dict-prune dict-help dict-kill dict-where

# lib/core.zsh is sourced once per shell, while functions/ is autoloaded fresh
# from disk on every call. Editing the library therefore leaves running shells
# with a stale half — this puts both halves back in sync without `exec zsh`.
dict-reload() {
  # Every autoloaded dict-* function starts this way; these two are defined
  # here instead, so they have to ask for standard options themselves. Without
  # it a shell with, say, bare_glob_qual off takes (N) literally and reload
  # dies with "no matches found".
  emulate -L zsh
  source $DICTATOR_HOME/lib/core.zsh || return 1
  # Plain glob plus :t afterwards, not dict-*(:t): the modifier-in-parentheses
  # form depends on shell options this function cannot count on, and when it is
  # taken literally the glob matches nothing and reload dies with "no matches
  # found". (N) keeps an empty directory from being an error too.
  local f
  for f in $DICTATOR_HOME/functions/dict-*(N); do
    unfunction ${f:t} 2>/dev/null
    autoload -Uz ${f:t}
  done
  # Regenerate the tmux config and push it into a running server, so editing
  # the template takes effect without restarting anything.
  rm -f "$(_dict_conf)"
  _dict_gen_conf
  _dict_tmux source-file "$(_dict_conf)" 2>/dev/null
  print -r -- 'dict: reloaded'
}

# Defined here rather than autoloaded so that `dict cd` runs in the calling shell.
dict() {
  emulate -L zsh
  local cmd=${1:-ls}
  (( $# )) && shift
  case $cmd in
    new|adopt|ls|sw|up|rm|note|rename|cd|prune|kill|where) dict-$cmd "$@" ;;
    reload)                  dict-reload ;;
    help|-h|--help|'-?')     dict-help ;;
    *) print -ru2 -- "dict: unknown command: $cmd"; dict-help; return 1 ;;
  esac
}
