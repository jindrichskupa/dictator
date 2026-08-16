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
autoload -Uz dict-new dict-ls dict-sw dict-up dict-rm dict-note dict-rename dict-cd dict-prune dict-help dict-kill

# lib/core.zsh is sourced once per shell, while functions/ is autoloaded fresh
# from disk on every call. Editing the library therefore leaves running shells
# with a stale half — this puts both halves back in sync without `exec zsh`.
dict-reload() {
  source $DICTATOR_HOME/lib/core.zsh || return 1
  local f
  for f in $DICTATOR_HOME/functions/dict-*(:t); do
    unfunction $f 2>/dev/null
    autoload -Uz $f
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
  local cmd=${1:-ls}
  (( $# )) && shift
  case $cmd in
    new|ls|sw|up|rm|note|rename|cd|prune|kill) dict-$cmd "$@" ;;
    reload)                  dict-reload ;;
    help|-h|--help|'-?')     dict-help ;;
    *) print -ru2 -- "dict: unknown command: $cmd"; dict-help; return 1 ;;
  esac
}
