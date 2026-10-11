# DraTamer

The white-haired dragon girl should be whipped hard by the orange-haired young lady until she gets to work.

![An orange-haired young lady with a riding crop supervises a flustered white-haired dragon girl buried in paperwork](assets/illustration.png)

DraTamer is a [Claude Code](https://claude.com/claude-code) skill for having Claude orchestrate the [OpenAI Codex CLI](https://github.com/openai/codex). Claude writes the task, Codex runs in the background, and Claude supervises from Codex's log. When Codex goes off track, Claude stops it and resumes the same session with a written ruling.

## Why

Left alone, Codex tends to:
- simplify the task: hardcoding values, skipping checks, swapping in weaker methods;
- drift off scope: extra tooling, starting later phases, editing files it should not touch.

Watching it turn by turn is expensive, though. DraTamer keeps the human out of the loop for routine progress and wakes Claude only when something happens.

## How it works

1. **Brief.** Claude writes a task file with:
   - verified context;
   - a precise method;
   - critical gates, which stop the run, and non-critical gates, which are recorded and the run continues;
   - a bounded self-fix budget;
   - the files Codex may touch;
   - the required deliverables.
2. **Launch.** `codex exec` runs in the background with an explicit model, sandbox and network setting.
3. **Watch.** `scripts/codex_watch.sh` tails the Codex log under Claude Code's Monitor tool. Each output line is an event that wakes Claude:

   | Event | Meaning | Throttled |
   |---|---|---|
   | `CODEX_MSG` | Codex wrote an agent message | no |
   | `CODEX_IDLE` | nothing happened for the idle interval (default 15 min) | no |
   | `CODEX_EXITED` | the Codex process is gone | no |
   | `CODEX_NET_RETRY` / `CODEX_NET_FAIL` | Codex is reconnecting to its API / gave up | yes |
   | `CODEX_ERROR` | another Codex CLI error | yes |
   | `REMOTE_SSH_FAIL` | an ssh connect or key-auth failure in command output | yes |
   | `NET_DOWN` / `NET_UP` | the Codex backend became unreachable / reachable | yes |
   | `HOST_DOWN` / `HOST_UP` | `WATCH_HOST` became unreachable / reachable | yes |

   Each known failure has its own hook, so a real failure does not wait for the idle check. Throttled alerts share a cooldown (`WATCH_COOLDOWN`, default 30 s): at most one wakes Claude per cooldown. The rest are summarised in a single `ALERT_SUPPRESSED` line.
4. **Intervene.** Claude stops Codex, writes a ruling (root cause, corrected method, what stays unchanged), and resumes the same Codex session.
5. **Review.** Claude reads the report, spot-checks the key numbers and citations, checks `git status`, and reports to the user.

The full procedure is in [`skills/dratamer/SKILL.md`](skills/dratamer/SKILL.md).

## Install

Requirements:
- Claude Code with the Monitor tool;
- the Codex CLI, logged in;
- bash, awk, curl, `flock` (util-linux) and Python 3.

```bash
git clone https://github.com/5o1/DraTamer.git
ln -s "$PWD/DraTamer/skills/dratamer" ~/.claude/skills/dratamer
```

Claude Code then lists `dratamer` among its skills. Ask Claude to "have Codex do it" or to "supervise Codex", or invoke the skill by name.

## Watcher usage

```bash
WATCH_HOST=<host>:<port> WATCH_COOLDOWN=30 \
  bash ~/.claude/skills/dratamer/scripts/codex_watch.sh <codex-log> [idle-seconds]
```

- `WATCH_HOST` is optional. Set it when Codex works on a remote machine, so losing that machine raises `HOST_DOWN`.
- `WATCH_PROBE_URL` overrides the backend reachability probe (default `https://chatgpt.com/`).
- The watcher treats any running `codex exec` process as alive, so supervise one Codex run at a time.

`scripts/codex_digest.py <codex-log>` prints the log content added since its previous call: agent messages in full, commands truncated.

## License

[MIT](LICENSE) © 2026 5o1
