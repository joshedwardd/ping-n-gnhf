# ping-n-gnhf

A small setup that does two things on this Mac:

1. **Pings Claude every 5 hours** (at 00:00, 05:00, 10:00, 15:00, 20:00) so your
   Claude Code 5-hour usage window opens at predictable times.
2. **Optionally runs [gnhf](https://github.com/kunchenguid/gnhf)** (an overnight
   AI coding agent) on a repo of your choice, at the ping time you pick.

No Claude API key involved. The ping is just the normal `claude` CLI in one-shot
mode (`claude -p "ping"`), using your existing Claude Code subscription login.

## The pieces

| Piece | Where | What it does |
|---|---|---|
| `pinger.sh` | this folder | the brain: pings Claude, starts gnhf when a job is queued |
| `com.josh.gnhf-pinger.plist` | `~/Library/LaunchAgents/` | the alarm clock: tells macOS when to run `pinger.sh` |
| `gnhf` | installed via npm (from GitHub) | the worker: loops Claude Code on a repo while you sleep |

The scheduler is **launchd**, macOS's built-in replacement for cron. Same idea as
a cronjob, with one big win: if the Mac is asleep at ping time, launchd runs the
missed ping when it wakes up (cron would just skip it). Nothing stays running
between pings; macOS wakes the script, it works for a few seconds, it exits.

## Turn it on (one time)

```sh
launchctl load -w ~/Library/LaunchAgents/com.josh.gnhf-pinger.plist
```

This also fires the first ping immediately. Check it worked:

```sh
launchctl list | grep gnhf-pinger   # should show the job
tail pinger.log                     # should show a fresh ping line
```

Turn it off:

```sh
launchctl unload -w ~/Library/LaunchAgents/com.josh.gnhf-pinger.plist
```

## Day-to-day use

Do nothing: pings happen on their own, no gnhf runs.

Want gnhf to work on a repo overnight? Queue a job during the day:

```sh
# run at the next ping, whenever that is
./pinger.sh queue ~/Projects/poster "add unit tests for the parser"

# run at the midnight ping specifically
./pinger.sh queue --at 00:00 ~/Projects/poster "refactor the upload module"

# extra gnhf flags go after the objective
./pinger.sh queue --at 00:00 ~/Projects/poster "fix flaky tests" --max-iterations 10 --worktree
```

First argument = repo path. Second = the prompt/objective. Anything after = extra
gnhf flags. Every job also gets these defaults:
`--current-branch --max-iterations 20 --max-tokens 5000000`

Check or cancel:

```sh
./pinger.sh status   # is gnhf running? is a job queued? when is it due?
./pinger.sh clear    # cancel the queued job
tail -f pinger.log   # what each ping decided
tail -f gnhf.log     # gnhf's live output while it works
```

There is one job slot. Queueing again overwrites the previous job.

## What each ping actually does

1. Send "ping" to Claude via the CLI. This opens/refreshes your 5h usage window.
2. If the ping **fails** (subscription ended, logged out, no internet): stop here.
   gnhf is never started, the queued job is kept for later, and you get a macOS
   notification saying the ping failed. Failed pings cost nothing. Once your
   login/subscription works again, the next ping picks the job up automatically.
3. No job queued? Done, ping only.
4. Job queued but its `--at` time hasn't arrived? Keep waiting.
5. gnhf still running from last time? Keep the job queued, try next ping.
6. Otherwise: start gnhf in the target repo with your prompt, remember its pid,
   clear the job slot.

## If your subscription ends

Nothing breaks and nothing gets charged. Pings fail fast and locally, gnhf is
blocked, your queued job freezes in place, and you get a notification at each
ping (5x/day) as a reminder. Fix the login or resubscribe and everything resumes
by itself. If you want silence instead, unload the agent (command above).

## Files this folder collects over time

| File | What |
|---|---|
| `next-job` | the queued job (deleted when it runs) |
| `gnhf.pid` | process id of a running gnhf |
| `pinger.log` | one entry per ping with what it decided |
| `gnhf.log` | everything gnhf printed |
| `launchd.log` | raw launchd output, usually empty |

## Good habits

- Check `claude -p "ping"` works in your terminal once before turning this on.
- Review gnhf's commits each morning before pushing anything.
- Use the `--worktree` flag on jobs if you don't want gnhf touching your
  working copy directly.
