#!/bin/bash
set -u
export PATH="/opt/homebrew/bin:$PATH"

DIR="$HOME/Projects/ping-n-gnhf"
JOBFILE="$DIR/next-job"
PIDFILE="$DIR/gnhf.pid"
LOG="$DIR/pinger.log"
GNHF_LOG="$DIR/gnhf.log"
DEFAULT_FLAGS=(--worktree --max-iterations 20 --max-tokens 5000000)

ts(){ date "+%Y-%m-%d %H:%M:%S"; }

usage() {
  cat >&2 <<'EOF'
usage:
  pinger.sh queue [--at HH:MM] <repo-path> [objective] [extra gnhf flags...]
      queue gnhf job; first ping at/after HH:MM runs it (no --at = next ping)
  pinger.sh run
      ping claude, run queued job if due (launchd calls this on schedule)
  pinger.sh status
      show gnhf state and queued job
  pinger.sh stop
      gracefully stop a running gnhf (SIGINT, waits up to 60s)
  pinger.sh last
      show what the last gnhf run changed (commits since base)
EOF
  exit 1
}

gnhf_running() {
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

next_ping() {
  slot=$(( ($(date +%-H) / 5 + 1) * 5 ))
  if [ "$slot" -ge 24 ]; then
    echo "tomorrow 00:00"
  else
    printf 'today %02d:00' "$slot"
  fi
}

cmd="${1:-}"
case "$cmd" in
  queue)
    shift
    notbefore=0
    if [ "${1:-}" = "--at" ]; then
      [ $# -ge 2 ] || usage
      at="$2"; shift 2
      notbefore=$(date -j -f "%Y-%m-%d %H:%M" "$(date +%Y-%m-%d) $at" +%s 2>/dev/null) \
        || { echo "bad time: $at (want HH:MM)" >&2; exit 1; }
      [ "$notbefore" -le "$(date +%s)" ] && notbefore=$((notbefore + 86400))
    fi
    [ $# -ge 1 ] || usage
    repo="$1"
    [ -d "$repo" ] || { echo "not a directory: $repo" >&2; exit 1; }
    objective="${2:-reduce complexity of the codebase}"
    shift $(( $# >= 2 ? 2 : 1 ))
    {
      echo "$notbefore"
      echo "$repo"
      echo "$objective"
      for f in "$@"; do echo "$f"; done
    } > "$JOBFILE"
    if [ "$notbefore" -gt 0 ]; then
      echo "queued: $repo -> \"$objective\" (first ping at/after $(date -r "$notbefore" "+%Y-%m-%d %H:%M"))"
    else
      echo "queued for next ping: $repo -> \"$objective\""
    fi
    ;;

  run)
    cd "$DIR" || exit 1
    if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 1000 ]; then
      tail -500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
    echo "[$(ts)] ping claude" >> "$LOG"
    if ! claude -p "ping" >> "$LOG" 2>&1; then
      echo "[$(ts)] claude ping FAILED (auth/subscription?), gnhf blocked, job kept" >> "$LOG"
      osascript -e 'display notification "claude ping failed - check subscription/login" with title "gnhf-pinger"' 2>/dev/null
      exit 0
    fi

    if [ ! -f "$JOBFILE" ]; then
      echo "[$(ts)] no job queued, ping only" >> "$LOG"
      exit 0
    fi

    { read -r notbefore; read -r repo; read -r objective; } < "$JOBFILE"
    flags=()
    while IFS= read -r f; do flags+=("$f"); done < <(tail -n +4 "$JOBFILE")

    if [ "$notbefore" -gt "$(date +%s)" ]; then
      echo "[$(ts)] job not due until $(date -r "$notbefore" "+%Y-%m-%d %H:%M"), stays queued" >> "$LOG"
      exit 0
    fi
    if gnhf_running; then
      echo "[$(ts)] gnhf still running (pid $(cat "$PIDFILE")), job stays queued" >> "$LOG"
      exit 0
    fi
    if ! command -v tmux >/dev/null; then
      echo "[$(ts)] tmux not installed, job stays queued" >> "$LOG"
      exit 1
    fi
    rm -f "$JOBFILE"

    echo "[$(ts)] starting gnhf in $repo: $objective" >> "$LOG"
    cd "$repo" || { echo "[$(ts)] bad repo path: $repo" >> "$LOG"; exit 1; }
    base=$(git rev-parse HEAD 2>/dev/null) \
      || { echo "[$(ts)] not a git repo: $repo" >> "$LOG"; exit 1; }
    { echo "$repo"; echo "$base"; echo "$objective"; } > "$DIR/last-run"
    echo "[$(ts)] base commit: $base" >> "$LOG"

    : > "$GNHF_LOG"
    gnhf_cmd=$(printf '%q ' gnhf "${DEFAULT_FLAGS[@]}" ${flags[@]+"${flags[@]}"} "$objective")
    tmux kill-session -t gnhf 2>/dev/null
    tmux new-session -d -s gnhf -c "$repo" "$gnhf_cmd; $DIR/pinger.sh notify $base"
    tmux set-option -w -t gnhf remain-on-exit on
    tmux pipe-pane -t gnhf -o "cat >> $GNHF_LOG"
    tmux display-message -p -t gnhf '#{pane_pid}' > "$PIDFILE"
    echo "[$(ts)] started gnhf pid $(cat "$PIDFILE") in tmux session 'gnhf'" >> "$LOG"
    ;;

  # chained onto the gnhf command inside tmux, runs in the target repo
  notify)
    n=$(git rev-list --count "$2..HEAD" 2>/dev/null || echo "?")
    msg="$n commit(s) in $(basename "$PWD")"
    [ -f FLAWS.md ] && msg="$msg, FLAWS.md present"
    echo "[$(ts)] gnhf finished: $msg" >> "$LOG"
    osascript -e "display notification \"$msg\" with title \"gnhf finished\"" 2>/dev/null
    ;;

  status)
    if gnhf_running; then
      echo "gnhf: running (pid $(cat "$PIDFILE"))"
    else
      echo "gnhf: not running"
    fi
    if [ -f "$JOBFILE" ]; then
      notbefore=$(head -1 "$JOBFILE")
      if [ "$notbefore" -gt 0 ]; then
        echo "queued job (due $(date -r "$notbefore" "+%Y-%m-%d %H:%M")):"
      else
        echo "queued job (next ping):"
      fi
      tail -n +2 "$JOBFILE" | sed 's/^/  /'
    else
      echo "queued job: none"
    fi
    echo "next ping: $(next_ping)"
    ;;

  last)
    [ -f "$DIR/last-run" ] || { echo "no run recorded yet"; exit 0; }
    { read -r repo; read -r base; read -r objective; } < "$DIR/last-run"
    printf 'repo:      %s\nobjective: %s\nbase:      %s\n\n' "$repo" "$objective" "$base"
    if [ -n "$(git -C "$repo" log --oneline "$base..HEAD" 2>/dev/null)" ]; then
      echo "commits made:"
      git -C "$repo" log --oneline "$base..HEAD"
    else
      echo "no commits on current branch (worktree run); newest branches:"
      git -C "$repo" branch --sort=-committerdate --format='  %(refname:short)  (%(committerdate:relative))' | head -5
      echo
      echo "inspect one: git -C $repo log --oneline $base..<branch>"
    fi
    ;;

  stop)
    if ! gnhf_running; then
      echo "gnhf not running"
      exit 0
    fi
    pid=$(cat "$PIDFILE")
    kill -INT "$pid"
    echo "sent interrupt to gnhf (pid $pid), waiting for graceful exit..."
    for _ in $(seq 12); do
      kill -0 "$pid" 2>/dev/null || { echo "gnhf stopped"; rm -f "$PIDFILE"; exit 0; }
      sleep 5
    done
    echo "still running after 60s; force kill: kill -9 $pid"
    ;;

  *)
    usage
    ;;
esac
