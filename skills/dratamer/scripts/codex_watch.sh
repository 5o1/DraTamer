#!/usr/bin/env bash
# Usage: [WATCH_PID=<codex pid>] [WATCH_COOLDOWN=30] [WATCH_OUTAGE=300] codex_watch.sh <codex-log> [idle-seconds, default 900]
# WATCH_PID tracks one Codex process; without it any running `codex exec` counts as alive.
# Run under the Monitor tool. Each stdout line is one event.
# Normal events (never throttled):
#   CODEX_MSG: <first lines of each Codex agent message>
#   CODEX_MSG [after context compaction]: the first message after Codex compacted its context
#     (not a separate event; if Codex exits first, a CODEX_COMPACTED line precedes CODEX_EXITED)
#   CODEX_IDLE: <no event for idle-seconds; log age; last shell command>
#   CODEX_EXITED  (when no `codex exec` process remains; the watch then ends)
# Failure-specific alerts (fire at once, but at most one per WATCH_COOLDOWN seconds;
# alerts inside the cooldown are counted and summarised as ALERT_SUPPRESSED once it ends):
#   CODEX_ERROR: Codex CLI errors that are not network errors
#   REMOTE_SSH_FAIL: ssh connect/auth failure seen in command output
#   NET_PROBLEM: network trouble has lasted WATCH_OUTAGE seconds (default 300) without recovery
#   NET_RECOVERED: the network is back after a period that raised NET_PROBLEM
# Network trouble (API reconnects, websocket/TLS/transport errors, Codex backend
# unreachable) opens a silent tolerance period. While it is open the backend is probed
# every 10 s; as soon as a probe succeeds the period closes and nothing is reported. Only a
# period still open after WATCH_OUTAGE seconds raises one NET_PROBLEM alert, followed by
# NET_RECOVERED when the backend is reachable again. A new interruption after a recovery
# opens a new period; there is never more than one.
log="$1"
idle="${2:-900}"
cooldown="${WATCH_COOLDOWN:-30}"
outage_limit="${WATCH_OUTAGE:-300}"
probe_url="${WATCH_PROBE_URL:-https://chatgpt.com/}"
state="$(mktemp -d)"
stamp="$state/stamp"; touch "$stamp"
echo 0 > "$state/last"; echo 0 > "$state/count"; : > "$state/lastmsg"; : > "$state/net_start"; : > "$state/net_log"

# Emit an alert unless one was emitted less than $cooldown seconds ago; otherwise count it.
alert() {
  (
    flock 9
    now=$(date +%s); last=$(cat "$state/last"); n=$(cat "$state/count")
    if (( now - last >= cooldown )); then
      (( n > 0 )) && echo "ALERT_SUPPRESSED: $n alert(s) within ${cooldown}s cooldown, last: $(cat "$state/lastmsg")"
      echo "$1"
      echo "$now" > "$state/last"; echo 0 > "$state/count"
    else
      echo $((n + 1)) > "$state/count"; echo "$1" > "$state/lastmsg"
    fi
    touch "$stamp"
  ) 9>"$state/lock"
}
# Report alerts that were held back once the cooldown has passed with no new alert.
flush_suppressed() {  # pass "force" to flush regardless of the cooldown (used at exit)
  (
    flock 9
    now=$(date +%s); last=$(cat "$state/last"); n=$(cat "$state/count")
    if (( n > 0 )) && { [[ ${1:-} == force ]] || (( now - last >= cooldown )); }; then
      echo "ALERT_SUPPRESSED: $n alert(s) within ${cooldown}s cooldown, last: $(cat "$state/lastmsg")"
      echo "$now" > "$state/last"; echo 0 > "$state/count"; touch "$stamp"
    fi
  ) 9>"$state/lock"
}

# One tolerance period at a time: $state/net_start holds its start time, $state/net_log its symptoms.
net_symptom() {  # $1 = retry|error|fail|backend_down
  ( flock 9
    [[ -s "$state/net_start" ]] || date +%s > "$state/net_start"
    echo "$1" >> "$state/net_log" ) 9>"$state/lock"
}
net_close() { ( flock 9; : > "$state/net_start"; : > "$state/net_log" ) 9>"$state/lock"; }

tail -n 0 -F "$log" 2>/dev/null | awk -v stamp="$stamp" -v cfile="$state/compacted" '
  function emit(s) { print s; fflush(); system("touch " stamp) }
  function msg(s) { if (compacted) { s = "CODEX_MSG [after context compaction]: " s; compacted = 0; system("rm -f " cfile) } else s = "CODEX_MSG: " s; emit(s) }
  function alert(s) { print "ALERT " s; fflush() }
  /^ERROR: Reconnecting\.\.\. 5\/5/ { print "NET fail"; fflush(); next }
  /^ERROR: Reconnecting/ { print "NET retry"; fflush(); next }
  /failed to refresh available models/ { next }  # known harmless (see SKILL.md)
  (/^ERROR: / || /^[0-9TZ:.-]+ +ERROR codex/ || /Falling back from WebSockets/) && /websocket|WebSocket|tls|TLS|timed out|stream disconnected|[Cc]onnection|error sending request|Falling back/ { print "NET error"; fflush(); next }
  /Orphan custom tool call output|Custom tool call output is missing/ { next }  # harmless after forking/resuming a session with an open tool call
  /^ERROR: / || /^[0-9TZ:.-]+ +ERROR codex/ { alert("CODEX_ERROR: " substr($0, 1, 200)); next }
  $0 == "context compacted" { compacted = 1; system("touch " cfile); next }
  /^ssh: connect to host/ || /Permission denied \(publickey/ || /^kex_exchange_identification/ { alert("REMOTE_SSH_FAIL: " substr($0, 1, 200)); next }
  $0 == "codex" { grab = 3; buf = ""; next }
  grab > 0 && $0 != "" { buf = buf (buf == "" ? "" : " / ") substr($0, 1, 220); grab--;
    if (grab == 0 || $0 ~ /^(exec|apply patch|hook:)/) { msg(buf); grab = 0 } next }
  grab > 0 && $0 == "" && buf != "" { msg(buf); grab = 0 }
' | while IFS= read -r line; do
  case "$line" in
    ALERT\ *) alert "${line#ALERT }" ;;
    NET\ *) net_symptom "${line#NET }" ;;
    *) echo "$line" ;;
  esac
done &
reader=$!
codex_alive() { if [[ -n "${WATCH_PID:-}" ]]; then kill -0 "$WATCH_PID" 2>/dev/null; else pgrep -f "^codex exec" >/dev/null; fi; }
net_up() { curl -s -o /dev/null --max-time 10 "$probe_url"; }
tick=0
# Give a just-launched Codex a moment to appear in the process table.
for _ in 1 2 3 4 5 6; do codex_alive && break; sleep 5; done
while codex_alive; do
  sleep 10
  tick=$((tick + 1))
  # Probe the backend every 60 s normally, every 10 s while a tolerance period is open.
  if (( tick % 6 == 0 )) || [[ -s "$state/net_start" ]]; then
    ok=1
    net_up || { ok=0; net_symptom backend_down; }
    if [[ -s "$state/net_start" ]]; then
      start=$(cat "$state/net_start")
      if (( ok )); then
        # Recovered: close quietly, unless this period already alerted.
        [[ -e "$state/net_alerted" ]] && alert "NET_RECOVERED: network back after $(( $(date +%s) - start ))s"
        rm -f "$state/net_alerted"; net_close
      elif [[ ! -e "$state/net_alerted" ]] && (( $(date +%s) - start >= outage_limit )); then
        summary=$(sort "$state/net_log" | uniq -c | awk '{printf "%s%s x%s", (NR>1?", ":""), $2, $1}')
        alert "NET_PROBLEM: network trouble for $(( $(date +%s) - start ))s without recovery (${summary})"
        touch "$state/net_alerted"                  # same interruption: no repeat until recovery
      fi
    fi
  fi
  flush_suppressed
  now=$(date +%s)
  if (( now - $(stat -c %Y "$stamp") >= idle )); then
    age=$(( now - $(stat -c %Y "$log") ))
    cmd=$(grep -E '^/bin/bash -lc' "$log" | tail -1 | cut -c1-200)
    echo "CODEX_IDLE: no agent message for ${idle}s; log last written ${age}s ago; last command: ${cmd}"
    touch "$stamp"
  fi
done
sleep 2
flush_suppressed force
[[ -e "$state/compacted" ]] && echo "CODEX_COMPACTED: Codex compacted its context and exited before writing another message"
echo "CODEX_EXITED"
kill "$reader" 2>/dev/null
pkill -P $$ 2>/dev/null
rm -rf "$state"
exit 0
