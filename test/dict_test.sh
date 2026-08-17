#!/usr/bin/env zsh
# Run from the repository root:  zsh test/dict_test.sh
set -u

DICT_ROOT=${0:A:h:h}
# Running the suite from inside a dictator session would otherwise leak that
# session's id into the hook tests, which check what happens without one.
unset DICTATOR_ID
export DICTATOR_STATE=$(mktemp -d)
# Its own socket, so a stray kill in here can never reach a real tmux server.
export DICTATOR_SOCKET=dictator-test-$$
trap 'command tmux -L "$DICTATOR_SOCKET" kill-server 2>/dev/null; rm -rf "$DICTATOR_STATE"' EXIT

source $DICT_ROOT/dictator.plugin.zsh

integer PASS=0 FAIL=0
t()  { print -r -- ""; print -r -- "── $1" }
ok() { (( PASS++ )); print -r -- "  ok   $1" }
no() { (( FAIL++ )); print -r -- "  FAIL $1"; print -r -- "       want: $2"; print -r -- "       got:  $3" }
eq() { [[ "$2" == "$3" ]] && ok "$1" || no "$1" "$2" "$3" }
fails() { local desc=$1; shift; "$@" >/dev/null 2>&1 && no "$desc" 'non-zero exit' 'zero exit' || ok "$desc" }

t 'registry round-trip'
_dict_add '{"id":"a-1","title":"first","dir":"/tmp","tmux":"dict-a-1","note":""}'
_dict_add '{"id":"a-2","title":"second","dir":"/tmp","tmux":"dict-a-2","note":""}'
eq 'two entries stored'  2        "$(_dict_all | wc -l | tr -d ' ')"
eq 'get by id'           'second' "$(_dict_get a-2 | jq -r .title)"
_dict_set a-1 note 'hello'
eq 'note updated'        'hello'  "$(_dict_get a-1 | jq -r .note)"
eq 'sibling untouched'   'second' "$(_dict_get a-2 | jq -r .title)"
_dict_remove a-1
eq 'entry removed'       1        "$(_dict_all | wc -l | tr -d ' ')"
fails 'get on missing id returns non-zero' _dict_get a-1

t 'malformed registry line'
print -r -- 'this is not json' >> "$(_dict_registry)"
eq 'malformed line skipped' 1 "$(_dict_all 2>/dev/null | wc -l | tr -d ' ')"

t 'status files'
_dict_status_set a-2 waiting
eq 'status word read back' 'waiting' "$(_dict_status_get a-2)"
fails 'missing status returns non-zero' _dict_status_get nope

t 'slug'
eq 'slug of a title' 'fix-billing-rounding' "$(_dict_slug 'Fix: Billing  Rounding!')"

t 'require'
fails 'missing command detected' _dict_require definitely-not-a-real-command
_dict_require jq && ok 'present command accepted' || no 'present command accepted' 0 1

t 'status hook'
HOOK=$DICT_ROOT/hooks/dict-status.sh

DICTATOR_ID=h-1 $HOOK running
eq 'hook writes running'  'running' "$(_dict_status_get h-1)"
DICTATOR_ID=h-1 $HOOK waiting
eq 'hook overwrites'      'waiting' "$(_dict_status_get h-1)"
DICTATOR_ID=h-1 $HOOK done
eq 'hook writes done'     'done'    "$(_dict_status_get h-1)"

# No DICTATOR_ID means the session is not ours: write nothing, succeed anyway.
BEFORE=$(ls $DICTATOR_STATE/state/ | wc -l | tr -d ' ')
$HOOK running; eq 'no id still exits 0' 0 $?
eq 'no id wrote nothing' "$BEFORE" "$(ls $DICTATOR_STATE/state/ | wc -l | tr -d ' ')"

# A hook that fails would block Claude Code, so it must exit 0 even when misused.
DICTATOR_ID=h-1 $HOOK; eq 'missing argument still exits 0' 0 $?

t 'derived state'
GONE=$DICTATOR_STATE/gone
mkdir -p $GONE
_dict_add "{\"id\":\"s-orphan\",\"title\":\"t\",\"dir\":\"$DICTATOR_STATE/never-existed\",\"tmux\":\"dict-s-orphan\",\"created\":\"$(_dict_now)\",\"note\":\"\"}"
_dict_add "{\"id\":\"s-dead\",\"title\":\"t\",\"dir\":\"$GONE\",\"tmux\":\"dict-s-dead\",\"created\":\"$(_dict_now)\",\"note\":\"\"}"
eq 'missing directory is orphan' 'orphan' "$(_dict_state_of s-orphan)"
eq 'no tmux session is dead'     'dead'   "$(_dict_state_of s-dead)"
fails 'unknown id returns non-zero' _dict_state_of s-nope

# A real tmux session, created and destroyed for this assertion only.
_dict_tmux new-session -d -s dict-s-live -c $GONE 2>/dev/null
_dict_add "{\"id\":\"s-live\",\"title\":\"t\",\"dir\":\"$GONE\",\"tmux\":\"dict-s-live\",\"created\":\"$(_dict_now)\",\"note\":\"\"}"
eq 'live session with no status is unknown' 'unknown' "$(_dict_state_of s-live)"
_dict_status_set s-live waiting
eq 'live session reports hook status'       'waiting' "$(_dict_state_of s-live)"
_dict_tmux kill-session -t '=dict-s-live' 2>/dev/null
eq 'killed session becomes dead'            'dead'    "$(_dict_state_of s-live)"

t 'age'
eq 'fresh timestamp is minutes' '0m' "$(_dict_age "$(_dict_now)")"
eq 'garbage timestamp'          '?'  "$(_dict_age 'not-a-date')"

t 'ls'
# One line per session, no header row.
eq 'ls lists every id' 4 "$(dict-ls | wc -l | tr -d ' ')"
dict-ls | grep -q 's-dead' && ok 'ls mentions s-dead' || no 'ls mentions s-dead' 'match' 'no match'
eq 'ls emits no escape codes when piped' 0 "$(dict-ls | grep -c $'\e' | tr -d ' ')"
# The root is stripped first; what is left is the identity.
eq 'label strips the Work root'  'acme/api' "$(_dict_repo_label $HOME/Work/acme/api)"
eq 'label keeps three at most'   'contoso/cms/backend' \
   "$(_dict_repo_label $HOME/Src/gitlab.com/contoso/cms/backend)"
# 34 characters is over the 28 cap, so it drops to the last component alone.
eq 'label falls back when long'  'repo' \
   "$(_dict_repo_label $HOME/Src/host/a-very-long-organisation-name/repo)"
eq 'repo label of a bare name'   'api'     "$(_dict_repo_label /api)"
eq 'long titles are truncated'             40        "${#$(_dict_trunc 'x123456789012345678901234567890123456789012345678901234567890' 40)}"

t 'repository discovery'
FAKE=$DICTATOR_STATE/fake
mkdir -p $FAKE/work/client/project/.git
mkdir -p $FAKE/src/github.com/org/repo/.git
mkdir -p $FAKE/work/client/not-a-repo
DICTATOR_ROOTS=($FAKE/work $FAKE/src)

eq 'finds depth-2 repo' 1 "$(_dict_repos --refresh | grep -c 'work/client/project$' | tr -d ' ')"
eq 'finds depth-4 repo' 1 "$(_dict_repos          | grep -c 'src/github.com/org/repo$' | tr -d ' ')"
eq 'ignores plain dirs' 0 "$(_dict_repos          | grep -c 'not-a-repo' | tr -d ' ')"
eq 'result is cached'   2 "$(wc -l < $DICTATOR_STATE/repos.cache | tr -d ' ')"

# A worktree has .git as a *file*, not a directory, and must still be found.
mkdir -p $FAKE/work/client/wt
print -r -- 'gitdir: /elsewhere' > $FAKE/work/client/wt/.git
eq 'finds worktree checkouts' 1 "$(_dict_repos --refresh | grep -c 'work/client/wt$' | tr -d ' ')"

# Regression: zsh does no word splitting, so a "${VAR:-a b}" default would
# collapse both roots into one bogus element and silently find nothing.
eq 'default roots are two separate paths' 2 \
   "$(DICTATOR_ROOTS=() _dict_roots | wc -l | tr -d ' ')"

t 'worktree creation'
REPO=$DICTATOR_STATE/repo
mkdir -p $REPO
git -C $REPO init -q
git -C $REPO config user.email t@t; git -C $REPO config user.name t
print -r -- x > $REPO/f; git -C $REPO add f; git -C $REPO commit -qm init

WT=$(_dict_worktree_add $REPO wt-1)
eq 'worktree path returned' "$DICTATOR_STATE/worktrees/repo/wt-1" "$WT"
[[ -d $WT ]] && ok 'worktree exists on disk' || no 'worktree exists on disk' 'directory' 'missing'
eq 'branch created' 'wt-1' "$(git -C $WT rev-parse --abbrev-ref HEAD)"

# Second call for the same id must fail rather than clobber the first.
fails 'duplicate worktree refused' _dict_worktree_add $REPO wt-1

# An existing branch is checked out rather than re-created.
git -C $REPO branch wt-2
WT2=$(_dict_worktree_add $REPO wt-2)
eq 'existing branch reused' 'wt-2' "$(git -C $WT2 rev-parse --abbrev-ref HEAD)"

fails 'non-repo refused' _dict_worktree_add $FAKE/work/client/not-a-repo wt-3

t 'picker lines'
LINES_OUT=$(DICT_PICK_LINES_ONLY=1 _dict_pick 2>/dev/null)
eq 'one line per session' 4 "$(print -r -- $LINES_OUT | wc -l | tr -d ' ')"
# The id rides in a hidden \x1f field so the visible layout can change freely.
eq 'hidden first field is the id' 's-dead' \
   "$(print -r -- $LINES_OUT | grep 's-dead' | cut -d $'\x1f' -f1)"
print -r -- $LINES_OUT | grep 's-dead' | cut -d $'\x1f' -f2 | grep -q 'dead' \
  && ok 'display carries the state' || no 'display carries the state' 'dead' 'missing'

# a-2, s-dead and s-live are dead; s-orphan is orphan and must not appear.
LINES_OUT=$(DICT_PICK_LINES_ONLY=1 _dict_pick --only dead 2>/dev/null)
eq 'filter by state'      3 "$(print -r -- $LINES_OUT | wc -l | tr -d ' ')"
eq 'filter excludes orphan' 0 "$(print -r -- $LINES_OUT | grep -c 's-orphan' | tr -d ' ')"
fails 'filter with no matches returns non-zero' _dict_pick --only running

# A query is matched by fzf, not by us, so what is asserted here is that the
# query reaches the picker instead of being mistaken for a flag.
eq 'a query still lists every candidate' 4 \
   "$(DICT_PICK_LINES_ONLY=1 _dict_pick s-dead 2>/dev/null | wc -l | tr -d ' ')"

t 'preview target'
# The picker's preview once silently showed "(not running)" for live sessions
# because capture-pane was handed a session target instead of a pane target.
_dict_tmux new-session -d -s dict-prev-1 -c $GONE 2>/dev/null
sleep 1
_dict_tmux capture-pane -pt '=dict-prev-1:' >/dev/null 2>&1 \
  && ok 'capture-pane accepts the target the preview uses' \
  || no 'capture-pane accepts the target the preview uses' 'rc=0' 'rc!=0'
# The form without the trailing colon is what was broken; keep it documented.
_dict_tmux capture-pane -pt '=dict-prev-1' 2>&1 | grep -q "can't find pane" \
  && ok 'session target without a colon is rejected by tmux' \
  || no 'session target without a colon is rejected by tmux' "can't find pane" 'accepted'
_dict_tmux kill-session -t '=dict-prev-1' 2>/dev/null

t 'help'
HELP=$(dict-help)
eq 'help mentions every command' 10 \
   "$(for c in new ls sw up cd note rename rm prune reload; do print -r -- $HELP | grep -c "dict $c" ; done | grep -vc '^0$')"
eq 'help mentions the prefix keys' 1 "$(print -r -- $HELP | grep -c 'prefix N')"
eq 'help mentions every state' 6 \
   "$(print -r -- $HELP | grep -cE '(running|waiting|done|ended|dead|orphan) ')"
eq 'help is plain when piped' 0 "$(dict-help | grep -c $'\e' | tr -d ' ')"

t 'cd'
eq 'cd moves the shell' "$GONE" "$(cd /tmp; dict-cd s-dead >/dev/null 2>&1; print -r -- $PWD)"
fails 'cd into a missing directory fails' dict-cd s-orphan

t 'transcript lookup'
export CLAUDE_CONFIG_DIR=$DICTATOR_STATE/claude
mkdir -p $CLAUDE_CONFIG_DIR/projects/-some-slug-abc123
print -r -- '{}' > $CLAUDE_CONFIG_DIR/projects/-some-slug-abc123/11111111-2222-3333-4444-555555555555.jsonl
_dict_transcript_exists 11111111-2222-3333-4444-555555555555 && ok 'existing transcript found' \
  || no 'existing transcript found' 0 1
fails 'missing transcript not found' _dict_transcript_exists 99999999-0000-0000-0000-000000000000

t 'revive'
_dict_add "{\"id\":\"r-1\",\"title\":\"revive me\",\"repo\":\"$GONE\",\"dir\":\"$GONE\",\"tmux\":\"dict-r-1\",\"claude_session\":\"11111111-2222-3333-4444-555555555555\",\"worktree\":false,\"branch\":\"-\",\"created\":\"$(_dict_now)\",\"note\":\"\"}"
eq 'starts out dead' 'dead' "$(_dict_state_of r-1)"

DICT_REVIVE_DRY_RUN=1 _dict_revive r-1 > $DICTATOR_STATE/cmd
eq 'resumes by session id' 'claude --resume 11111111-2222-3333-4444-555555555555' "$(<$DICTATOR_STATE/cmd)"

_dict_set r-1 claude_session 99999999-0000-0000-0000-000000000000
DICT_REVIVE_DRY_RUN=1 _dict_revive r-1 2>/dev/null > $DICTATOR_STATE/cmd
eq 'falls back to a fresh conversation' 'claude' "$(<$DICTATOR_STATE/cmd)"

fails 'unknown id refused'       _dict_revive r-nope
fails 'orphan directory refused' _dict_revive s-orphan

# The real thing: create it, confirm it lives, kill it.
_dict_revive r-1 >/dev/null 2>&1
eq 'revived session is alive' 'running' "$(_dict_state_of r-1)"
eq 'DICTATOR_ID is in the session environment' 'DICTATOR_ID=r-1' \
   "$(_dict_tmux show-environment -t '=dict-r-1' DICTATOR_ID 2>/dev/null)"
eq 'reviving a live session is a no-op' 'dict: r-1 is already running' "$(_dict_revive r-1)"
_dict_tmux kill-session -t '=dict-r-1' 2>/dev/null

t 'note'
dict-note s-dead 'waiting on review'
eq 'note stored'  'waiting on review'  "$(_dict_get s-dead | jq -r .note)"
dict-note s-dead 'now something else'
eq 'note replaced' 'now something else' "$(_dict_get s-dead | jq -r .note)"
fails 'note on unknown id fails' dict-note s-nope 'x'
fails 'note with no id fails'    dict-note

t 'rename'
dict-rename s-dead 'a better name' >/dev/null
eq 'title replaced' 'a better name' "$(_dict_get s-dead | jq -r .title)"
# Everything the id addresses must survive a retitle.
eq 'id unchanged'    's-dead'      "$(_dict_get s-dead | jq -r .id)"
eq 'tmux unchanged'  'dict-s-dead' "$(_dict_get s-dead | jq -r .tmux)"
eq 'note unchanged'  'now something else' "$(_dict_get s-dead | jq -r .note)"
# Multiple words arrive as one title, not just the first.
dict-rename s-dead one two three >/dev/null
eq 'the whole argument list is the title' 'one two three' "$(_dict_get s-dead | jq -r .title)"
eq 'sibling untouched' 't' "$(_dict_get s-orphan | jq -r .title)"
fails 'rename on unknown id fails' dict-rename s-nope 'x'
dict-rename s-dead 'a better name' >/dev/null

t 'worktree safety'
# A clean worktree whose commits are all on main is safe to delete.
git -C $REPO branch -M main 2>/dev/null
WT3=$(_dict_worktree_add $REPO wt-clean)
fails 'clean worktree has no work' _dict_worktree_has_work $WT3

# Uncommitted changes must stop the deletion.
print -r -- 'edited' > $WT3/f
_dict_worktree_has_work $WT3 && ok 'dirty worktree has work' \
  || no 'dirty worktree has work' 'yes' 'no'

# So must a commit that exists nowhere else.
git -C $WT3 add f; git -C $WT3 commit -qm 'local only'
_dict_worktree_has_work $WT3 && ok 'unmerged commit counts as work' \
  || no 'unmerged commit counts as work' 'yes' 'no'

# A directory that is not a repository at all is the undeterminable case,
# and undeterminable must mean "keep it".
_dict_worktree_has_work $GONE && ok 'undeterminable counts as work' \
  || no 'undeterminable counts as work' 'yes' 'no'

t 'last activity'
_dict_add "{\"id\":\"act-1\",\"title\":\"t\",\"repo\":\"$GONE\",\"dir\":\"$GONE\",\"tmux\":\"dict-act-1\",\"worktree\":false,\"branch\":\"-\",\"created\":\"2020-01-01T00:00:00Z\",\"note\":\"\"}"
eq 'falls back to created when no status file' 1577836800 \
   "$(_dict_last_activity act-1 '2020-01-01T00:00:00Z')"
_dict_status_set act-1 done
# The status file was just written, so activity must be recent, not 2020.
(( $(_dict_last_activity act-1 '2020-01-01T00:00:00Z') > $(date -u +%s) - 60 )) \
  && ok 'status file mtime wins over created' \
  || no 'status file mtime wins over created' 'recent' 'old'

t 'rm'
_dict_add "{\"id\":\"d-1\",\"title\":\"delete me\",\"repo\":\"$GONE\",\"dir\":\"$GONE\",\"tmux\":\"dict-d-1\",\"claude_session\":\"\",\"worktree\":false,\"branch\":\"-\",\"created\":\"$(_dict_now)\",\"note\":\"\"}"
_dict_status_set d-1 done
_dict_forget d-1 >/dev/null
fails 'entry gone from registry' _dict_get d-1
[[ -f $(_dict_status_file d-1) ]] && no 'status file removed' 'absent' 'present' || ok 'status file removed'
fails 'rm on unknown id fails' dict-rm d-nope

# A worktree with work survives being forgotten: the record goes, the code stays.
_dict_add "{\"id\":\"wt-clean\",\"title\":\"keep my work\",\"repo\":\"$REPO\",\"dir\":\"$WT3\",\"tmux\":\"dict-wt-clean\",\"claude_session\":\"\",\"worktree\":true,\"branch\":\"wt-clean\",\"created\":\"$(_dict_now)\",\"note\":\"\"}"
_dict_forget wt-clean >/dev/null
fails 'entry forgotten' _dict_get wt-clean
[[ -d $WT3 ]] && ok 'worktree with work is left on disk' \
  || no 'worktree with work is left on disk' 'present' 'deleted'

t 'prune candidates'
# act-1 was just touched, so a 7-day sweep must not offer it.
eq 'freshly touched is not stale' 0 "$(_dict_stale 7 | grep -c '^act-1$' | tr -d ' ')"

# Age it by rewriting the status file's mtime to 30 days ago.
touch -t $(date -u -v-30d +%Y%m%d%H%M) "$(_dict_status_file act-1)"
eq 'old and not alive is stale'   1 "$(_dict_stale 7  | grep -c '^act-1$' | tr -d ' ')"
eq 'a longer window spares it'    0 "$(_dict_stale 60 | grep -c '^act-1$' | tr -d ' ')"

# A live session is never a candidate, however old its record.
_dict_tmux new-session -d -s dict-alive-1 -c $GONE 2>/dev/null
_dict_add "{\"id\":\"alive-1\",\"title\":\"t\",\"repo\":\"$GONE\",\"dir\":\"$GONE\",\"tmux\":\"dict-alive-1\",\"worktree\":false,\"branch\":\"-\",\"created\":\"2020-01-01T00:00:00Z\",\"note\":\"\"}"
_dict_status_set alive-1 running
touch -t $(date -u -v-30d +%Y%m%d%H%M) "$(_dict_status_file alive-1)"
eq 'a running session is never stale' 0 "$(_dict_stale 7 | grep -c '^alive-1$' | tr -d ' ')"
_dict_tmux kill-session -t '=dict-alive-1' 2>/dev/null
eq 'once dead it becomes stale'       1 "$(_dict_stale 7 | grep -c '^alive-1$' | tr -d ' ')"

t 'kill keeps the record'
_dict_tmux new-session -d -s dict-k-1 -c $GONE 2>/dev/null
_dict_add "{\"id\":\"k-1\",\"title\":\"stop me\",\"repo\":\"$GONE\",\"dir\":\"$GONE\",\"tmux\":\"dict-k-1\",\"claude_session\":\"11111111-2222-3333-4444-555555555555\",\"worktree\":false,\"branch\":\"-\",\"created\":\"$(_dict_now)\",\"note\":\"\"}"
_dict_status_set k-1 running
eq 'starts alive' 'running' "$(_dict_state_of k-1)"

# What `dict kill` does, without the dialog the test cannot answer.
_dict_tmux kill-session -t '=dict-k-1' 2>/dev/null
_dict_status_set k-1 ended
eq 'killed session is dead'   'dead' "$(_dict_state_of k-1)"
_dict_get k-1 >/dev/null 2>&1 && ok 'record survives a kill' \
  || no 'record survives a kill' 'present' 'gone'
DICT_REVIVE_DRY_RUN=1 _dict_revive k-1 > $DICTATOR_STATE/kcmd
eq 'a killed session can still be revived' \
   'claude --resume 11111111-2222-3333-4444-555555555555' "$(<$DICTATOR_STATE/kcmd)"

# rm is the other half: nothing survives it.
_dict_forget k-1 >/dev/null
fails 'rm leaves no record' _dict_get k-1

t 'unknown ids are refused before any dialog'
# If validation came after the confirm, these would open fzf and hang.
fails 'kill refuses an unknown id' dict-kill nope-1
fails 'rm refuses an unknown id'   dict-rm   nope-1

t 'alive filter'
# A session is killable whenever tmux still has it, whatever the hooks last
# wrote. waiting and done are alive; only dead and orphan are not.
_dict_tmux new-session -d -s dict-av-wait -c $GONE 2>/dev/null
_dict_tmux new-session -d -s dict-av-done -c $GONE 2>/dev/null
_dict_add "{\"id\":\"av-wait\",\"title\":\"waits\",\"repo\":\"$GONE\",\"dir\":\"$GONE\",\"tmux\":\"dict-av-wait\",\"worktree\":false,\"branch\":\"-\",\"created\":\"$(_dict_now)\",\"note\":\"\"}"
_dict_add "{\"id\":\"av-done\",\"title\":\"finished\",\"repo\":\"$GONE\",\"dir\":\"$GONE\",\"tmux\":\"dict-av-done\",\"worktree\":false,\"branch\":\"-\",\"created\":\"$(_dict_now)\",\"note\":\"\"}"
_dict_status_set av-wait waiting
_dict_status_set av-done done

ALIVE=$(DICT_PICK_LINES_ONLY=1 _dict_pick --alive 2>/dev/null | cut -d $'\x1f' -f1)
eq 'waiting is offered'  1 "$(print -r -- $ALIVE | grep -c '^av-wait$' | tr -d ' ')"
eq 'done is offered'     1 "$(print -r -- $ALIVE | grep -c '^av-done$' | tr -d ' ')"
eq 'dead is not offered' 0 "$(print -r -- $ALIVE | grep -c '^s-dead$'  | tr -d ' ')"
eq 'orphan is not offered' 0 "$(print -r -- $ALIVE | grep -c '^s-orphan$' | tr -d ' ')"

_dict_tmux kill-session -t '=dict-av-wait' 2>/dev/null
ALIVE=$(DICT_PICK_LINES_ONLY=1 _dict_pick --alive 2>/dev/null | cut -d $'\x1f' -f1)
eq 'once tmux is gone it drops out' 0 "$(print -r -- $ALIVE | grep -c '^av-wait$' | tr -d ' ')"
_dict_tmux kill-session -t '=dict-av-done' 2>/dev/null

t 'tmux config'
# Nothing else exercises the config, and a typo in it fails silently: the
# server starts, the binding is simply absent.
_dict_gen_conf
GEN=$(_dict_conf)
eq 'the generated config lives in the state dir' "$DICTATOR_STATE/tmux.conf" "$GEN"
eq 'no placeholder survives generation' 0 "$(grep -c '@DICTATOR_HOME@\|@CONF@' $GEN | tr -d ' ')"
grep -q "$DICT_ROOT/dictator.plugin.zsh" $GEN \
  && ok 'popups carry an absolute plugin path' \
  || no 'popups carry an absolute plugin path' "$DICT_ROOT" 'missing'

CONFSOCK=dict-conf-$$
command tmux -L $CONFSOCK -f $GEN new-session -d -s conftest 2>/dev/null
KEYS=$(command tmux -L $CONFSOCK list-keys 2>/dev/null)

for k in N S R K X '?' r Enter c; do
  print -r -- $KEYS | grep -qE "T prefix +\Q$k\E " \
    && ok "prefix $k is bound" || no "prefix $k is bound" 'bound' 'missing'
done
eq 'prefix is C-a' 'prefix C-a' \
   "$(command tmux -L $CONFSOCK show-options -g prefix 2>/dev/null)"

# The bug this replaced: tmux expanded $DICTATOR_HOME at parse time, so any
# load from an environment without it produced `source /dictator.plugin.zsh`
# and every popup flashed and vanished. Reload with the variable gone.
(
  unset DICTATOR_HOME
  command tmux -L $CONFSOCK source-file $GEN 2>/dev/null
)
command tmux -L $CONFSOCK list-keys 2>/dev/null | grep -q "source /dictator.plugin.zsh" \
  && no 'a reload without DICTATOR_HOME keeps the path' 'absolute path' 'empty path' \
  || ok 'a reload without DICTATOR_HOME keeps the path'
command tmux -L $CONFSOCK kill-server 2>/dev/null

t 'socket isolation'
_dict_tmux new-session -d -s iso-1 -c $GONE
_dict_tmux has-session -t '=iso-1' 2>/dev/null \
  && ok 'session lives on the dictator socket' \
  || no 'session lives on the dictator socket' 'present' 'missing'
# The whole point: it must be invisible to the default server, so that killing
# one server can never take the other down with it.
command tmux -L default has-session -t '=iso-1' 2>/dev/null \
  && no 'invisible on the default socket' 'absent' 'present' \
  || ok 'invisible on the default socket'
eq 'socket is overridable' "dictator-test-$$" "$(_dict_socket)"
eq 'template is the one in this checkout' "$DICT_ROOT/tmux/dictator.conf" "$(_dict_template)"
eq 'config is generated into the state dir' "$DICTATOR_STATE/tmux.conf" "$(_dict_conf)"
_dict_tmux kill-session -t '=iso-1' 2>/dev/null

t 'session launches its program'
# A stand-in for claude: records that it ran, with which arguments, in which
# directory, and whether .envrc had been applied.
LAUNCHDIR=$DICTATOR_STATE/launch
mkdir -p $LAUNCHDIR
print -r -- 'export DICT_ENVRC_MARKER=loaded' > $LAUNCHDIR/.envrc
command -v direnv >/dev/null && direnv allow $LAUNCHDIR 2>/dev/null

PROBE=$DICTATOR_STATE/probe
cat > $PROBE <<PROBE_EOF
#!/bin/sh
{ echo "args=\$*"; echo "pwd=\$PWD"; echo "id=\${DICTATOR_ID:-none}"; echo "envrc=\${DICT_ENVRC_MARKER:-unset}"; } > $DICTATOR_STATE/probe.out
PROBE_EOF
chmod +x $PROBE

_dict_add "{\"id\":\"l-1\",\"title\":\"launch\",\"repo\":\"$LAUNCHDIR\",\"dir\":\"$LAUNCHDIR\",\"tmux\":\"dict-l-1\",\"claude_session\":\"11111111-2222-3333-4444-555555555555\",\"worktree\":false,\"branch\":\"-\",\"created\":\"$(_dict_now)\",\"note\":\"\"}"
DICTATOR_PROGRAM=$PROBE _dict_revive l-1 >/dev/null 2>&1

for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -f $DICTATOR_STATE/probe.out ]] && break; sleep 1; done

if [[ -f $DICTATOR_STATE/probe.out ]]; then
  ok 'program actually started'
  eq 'resumed with the session id' 'args=--resume 11111111-2222-3333-4444-555555555555' \
     "$(grep '^args=' $DICTATOR_STATE/probe.out)"
  eq 'started in the session directory' "pwd=$LAUNCHDIR" "$(grep '^pwd=' $DICTATOR_STATE/probe.out)"
  eq 'DICTATOR_ID reached the program'  'id=l-1' "$(grep '^id=' $DICTATOR_STATE/probe.out)"
  if command -v direnv >/dev/null; then
    eq 'envrc was applied before launch' 'envrc=loaded' "$(grep '^envrc=' $DICTATOR_STATE/probe.out)"
  fi
else
  no 'program actually started' 'probe.out written' 'nothing after 10s'
fi

# A clean exit must take the tmux session with it: quitting Claude should
# close the window, not leave an empty shell behind.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  _dict_tmux has-session -t '=dict-l-1' 2>/dev/null || break
  sleep 1
done
_dict_tmux has-session -t '=dict-l-1' 2>/dev/null \
  && no 'clean exit closes the session' 'gone' 'still alive' \
  || ok 'clean exit closes the session'

t 'a failing program leaves a shell'
# The opposite case: if the session vanished on failure, the error would go
# with it, so a non-zero exit must drop to a shell instead.
FAILPROBE=$DICTATOR_STATE/failprobe
print -r -- '#!/bin/sh' > $FAILPROBE
print -r -- 'exit 3'   >> $FAILPROBE
chmod +x $FAILPROBE
_dict_add "{\"id\":\"f-1\",\"title\":\"fails\",\"repo\":\"$GONE\",\"dir\":\"$GONE\",\"tmux\":\"dict-f-1\",\"claude_session\":\"\",\"worktree\":false,\"branch\":\"-\",\"created\":\"$(_dict_now)\",\"note\":\"\"}"
DICTATOR_PROGRAM=$FAILPROBE _dict_revive f-1 >/dev/null 2>&1
sleep 3
_dict_tmux has-session -t '=dict-f-1' 2>/dev/null \
  && ok 'failure keeps the session open' \
  || no 'failure keeps the session open' 'alive' 'gone'
_dict_tmux kill-session -t '=dict-f-1' 2>/dev/null

print -r -- ""
print -r -- "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
