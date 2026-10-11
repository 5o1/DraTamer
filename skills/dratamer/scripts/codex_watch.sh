#!/usr/bin/env bash
# Usage: [WATCH_PID=<codex pid>] [WATCH_HOST=host:port] [WATCH_COOLDOWN=30] codex_watch.sh <codex-log> [idle-seconds, default 900]
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
#   CODEX_NET_RETRY / CODEX_NET_FAIL: Codex API reconnect attempt / attempts exhausted
#   CODEX_ERROR: other Codex CLI errors, transport fallback
#   REMOTE_SSH_FAIL: ssh connect/auth failure seen in command output
#   NET_DOWN / NET_UP: Codex backend reachability changed (probe every 60 s)
#   HOST_DOWN / HOST_UP: WATCH_HOST TCP reachability changed (probe every 60 s; only if set)
log="$1"
idle="${2:-900}"
cooldown="${WATCH_COOLDOWN:-30}"
probe_url="${WATCH_PROBE_URL:-https://chatgpt.com/}"
state="$(mktemp -d)"
stamp="$state/stamp"; touch "$stamp"
echo 0 > "$state/last"; echo 0 > "$state/count"; : > "$state/lastmsg"

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

tail -n 0 -F "$log" 2>/dev/null | awk -v stamp="$stamp" -v cfile="$state/compacted" '
  function emit(s) { print s; fflush(); system("touch " stamp) }
  function msg(s) { if (compacted) { s = "CODEX_MSG [after context compaction]: " s; compacted = 0; system("rm -f " cfile) } else s = "CODEX_MSG: " s; emit(s) }
  function alert(s) { print "ALERT " s; fflush() }
  /^ERROR: Reconnecting\.\.\. 5\/5/ { alert("CODEX_NET_FAIL: " substr($0, 1, 200)); next }
  /^ERROR: Reconnecting/ { alert("CODEX_NET_RETRY: " substr($0, 1, 200)); next }
  /failed to refresh available models/ { next }  # known harmless (see SKILL.md)
  /^ERROR: / || /Falling back from WebSockets/ || /^[0-9TZ:.-]+ +ERROR codex/ { alert("CODEX_ERROR: " substr($0, 1, 200)); next }
  $0 == "context compacted" { compacted = 1; system("touch " cfile); next }
  /^ssh: connect to host/ || /Permission denied \(publickey/ || /^kex_exchange_identification/ { alert("REMOTE_SSH_FAIL: " substr($0, 1, 200)); next }
  $0 == "codex" { grab = 3; buf = ""; next }
  grab > 0 && $0 != "" { buf = buf (buf == "" ? "" : " / ") substr($0, 1, 220); grab--;
    if (grab == 0 || $0 ~ /^(exec|apply patch|hook:)/) { msg(buf); grab = 0 } next }
  grab > 0 && $0 == "" && buf != "" { msg(buf); grab = 0 }
' | while IFS= read -r line; do
  case "$line" in ALERT\ *) alert "${line#ALERT }" ;; *) echo "$line" ;; esac
done &
reader=$!
codex_alive() { if [[ -n "${WATCH_PID:-}" ]]; then kill -0 "$WATCH_PID" 2>/dev/null; else pgrep -f "^codex exec" >/dev/null; fi; }
net_up() { curl -s -o /dev/null --max-time 10 "$probe_url"; }
host_up() { timeout 5 bash -c "</dev/tcp/${WATCH_HOST%:*}/${WATCH_HOST##*:}" 2>/dev/null; }
net_state=up; host_state=up; tick=0
# Give a just-launched Codex a moment to appear in the process table.
for _ in 1 2 3 4 5 6; do codex_alive && break; sleep 5; done
while codex_alive; do
  sleep 10
  tick=$((tick + 1))
  if (( tick % 6 == 0 )); then
    if net_up; then new=up; else new=down; fi
    if [[ $new != "$net_state" ]]; then
      [[ $new == down ]] && alert "NET_DOWN: $probe_url unreachable" || alert "NET_UP: $probe_url reachable again"
      net_state=$new
    fi
    if [[ -n "${WATCH_HOST:-}" ]]; then
      if host_up; then new=up; else new=down; fi
      if [[ $new != "$host_state" ]]; then
        [[ $new == down ]] && alert "HOST_DOWN: $WATCH_HOST unreachable" || alert "HOST_UP: $WATCH_HOST reachable again"
        host_state=$new
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
