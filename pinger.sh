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
    nohup gnhf "${DEFAULT_FLAGS[@]}" ${flags[@]+"${flags[@]}"} "$objective" >> "$GNHF_LOG" 2>&1 &
    echo $! > "$PIDFILE"
    echo "[$(ts)] started gnhf pid $(cat "$PIDFILE")" >> "$LOG"
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

  *)
    usage
    ;;
esac
