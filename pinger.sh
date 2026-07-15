#!/bin/bash
set -u
export PATH="/opt/homebrew/bin:$PATH"

DIR="$HOME/Projects/ping-n-gnhf"
JOBFILE="$DIR/next-job"
PIDFILE="$DIR/gnhf.pid"
LOG="$DIR/pinger.log"
GNHF_LOG="$DIR/gnhf.log"
DEFAULT_FLAGS=(--current-branch --max-iterations 20 --max-tokens 5000000)

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
  pinger.sh clear
      remove queued job
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

    notbefore=$(head -1 "$JOBFILE")
    if [ "$notbefore" -gt "$(date +%s)" ]; then
      echo "[$(ts)] job not due until $(date -r "$notbefore" "+%Y-%m-%d %H:%M"), stays queued" >> "$LOG"
      exit 0
    fi
    if gnhf_running; then
      echo "[$(ts)] gnhf still running (pid $(cat "$PIDFILE")), job stays queued" >> "$LOG"
      exit 0
    fi

    repo=""; objective=""; flags=()
    i=0
    while IFS= read -r line; do
      case $i in
        0) ;;
        1) repo="$line" ;;
        2) objective="$line" ;;
        *) flags+=("$line") ;;
      esac
      i=$((i+1))
    done < "$JOBFILE"
    rm -f "$JOBFILE"

    echo "[$(ts)] starting gnhf in $repo: $objective" >> "$LOG"
    cd "$repo" || { echo "[$(ts)] bad repo path: $repo" >> "$LOG"; exit 1; }
    base=$(git rev-parse HEAD 2>/dev/null || echo none)
    { echo "$repo"; echo "$base"; echo "$objective"; } > "$DIR/last-run"
    echo "[$(ts)] base commit: $base" >> "$LOG"
    gnhf_cmd=$(printf '%q ' gnhf "${DEFAULT_FLAGS[@]}" ${flags[@]+"${flags[@]}"} "$objective")
    if tmux kill-session -t gnhf 2>/dev/null; [ -n "$(command -v tmux)" ] && tmux new-session -d -s gnhf -c "$repo" "$gnhf_cmd" 2>/dev/null; then
      tmux set-option -w -t gnhf remain-on-exit on 2>/dev/null
      tmux pipe-pane -t gnhf -o "cat >> $GNHF_LOG" 2>/dev/null
      tmux display-message -p -t gnhf '#{pane_pid}' > "$PIDFILE"
      echo "[$(ts)] started gnhf pid $(cat "$PIDFILE") in tmux session 'gnhf'" >> "$LOG"
    else
      nohup gnhf "${DEFAULT_FLAGS[@]}" ${flags[@]+"${flags[@]}"} "$objective" >> "$GNHF_LOG" 2>&1 &
      echo $! > "$PIDFILE"
      echo "[$(ts)] started gnhf pid $(cat "$PIDFILE") headless (no tmux)" >> "$LOG"
    fi
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
    ;;

  clear)
    rm -f "$JOBFILE"
    echo "queue cleared"
    ;;

  last)
    [ -f "$DIR/last-run" ] || { echo "no run recorded yet"; exit 0; }
    repo=$(sed -n 1p "$DIR/last-run")
    base=$(sed -n 2p "$DIR/last-run")
    objective=$(sed -n 3p "$DIR/last-run")
    echo "repo:      $repo"
    echo "objective: $objective"
    echo "base:      $base"
    echo
    if [ "$base" = "none" ]; then
      echo "(base unknown, showing last 10 commits)"
      git -C "$repo" log --oneline -10
    else
      echo "commits made:"
      git -C "$repo" log --oneline "$base..HEAD"
      echo
      echo "files changed:"
      git -C "$repo" diff --stat "$base..HEAD" | tail -5
    fi
    [ -f "$repo/FLAWS.md" ] && { echo; echo "FLAWS.md exists: $repo/FLAWS.md"; }
    ;;

  stop)
    if ! gnhf_running; then
      echo "gnhf not running"
      exit 0
    fi
    pid=$(cat "$PIDFILE")
    kill -INT "$pid"
    echo "sent interrupt to gnhf (pid $pid), waiting for graceful exit..."
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
      kill -0 "$pid" 2>/dev/null || { echo "gnhf stopped"; rm -f "$PIDFILE"; exit 0; }
      sleep 5
    done
    echo "still running after 60s; force kill: kill -9 $pid"
    ;;

  *)
    usage
    ;;
esac
