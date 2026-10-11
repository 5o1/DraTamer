---
name: dratamer
description: Hand an execution task to OpenAI Codex CLI running in the background and supervise it. Claude designs the work and writes the task; Codex does the execution and, when delegated, the research. Claude watches Codex's log with an event-driven monitor (each agent message, failure-specific alerts with a 30 s cooldown, a 15-minute idle check, process exit) and steps in by stopping Codex and resuming it with a written ruling. Use when the user asks to have Codex do the work, to "control/supervise codex", or to run a task through Codex in the background.
---

# Supervised Codex execution

The user does not trust Codex unattended. Left alone, it tends to:
- simplify the task (hardcoding values, skipping checks, swapping in weaker methods);
- drift off scope (extra tooling, starting later phases, editing protected files).

The user also wants **few back-and-forth rounds**. This workflow serves both goals.

## Roles

- **You (Claude):**
  - design: method choices, gates, root-cause analysis;
  - write the task, research briefs and rulings;
  - review the results: read conclusions and open questions, spot-check key numbers and about three key citations against primary sources.
- **Codex:** implementation, runs, renders, reports, and also literature and tool research. Research is delegated because it is cheaper in Codex than in your long-context turns. Give research briefs neutral questions, primary-source rules and a single report file.
- **Before dispatching:** settle every design decision you can. Confirm with the user the ones that are theirs to make. Write the conclusions into the task, so Codex has nothing to invent.

## 1. Write the task file

Put it in the session scratchpad, e.g. `$S/codex_<topic>_task.md`, and write it in the user's language. Include:

- **Context and facts already verified.** Mark them "reviewer-verified; reproduce in report". Codex must recheck them; it has caught reviewer errors before.
- **The method, stated precisely,** with simple, robust definitions. Don't ask Codex to invent segmentations or heuristics.
- **Two kinds of gates:**
  - **Critical gate:** failure makes downstream results meaningless, so stop and report.
  - **Non-critical gate:** record it as failed, with the value, and continue. List all failures at the top of the report.
  - Thresholds and definitions may not change. No tuning just to pass.
  - Exempt natural edge effects (tapered tips, boundary samples) from per-element gates.
- **Bug-fix budget:** Codex may fix bugs in its own implementation, up to 3 per step. Log each one with the evidence, the fix and the result. If it can't tell whether something is a bug or a real gate failure, it treats it as a gate failure and stops.
- **Limit diagnostics on failure.** When a critical gate fails, render at most 3 relevant diagnostic images, then stop. Produce the full figure set only on success, because full renders after a failure waste a lot of time.
- **Constraints:** output directory, protected paths, no git commit, no hardware IO, network rules. Keep large files on the remote node if the project says so.
- **Deliverables:** a report with an "unauthorized choices I made" section, plus a reproducible script.
- **End with paths.** The last message must list absolute paths of all images and key files, because the user reads results in a terminal CLI.

## 2. Launch

Pick the model with the user. Check project memory for their current choice, e.g. `-m gpt-6.1-sol -c model_reasoning_effort="high"`. Never edit `~/.codex/config.toml`; other projects use it. Run with `run_in_background: true`:

```bash
# Fresh session (use a new one when old context would pollute the task)
cd <repo> && codex exec -m <MODEL> -c model_reasoning_effort=\"<EFFORT>\" \
  -s workspace-write -c sandbox_workspace_write.network_access=true \
  -o $S/codex_<topic>_last.md - < $S/codex_<topic>_task.md > $S/codex_<topic>.log 2>&1; echo "codex exit=$?"

# Resume the same session (session id is printed near the top of the log)
cd <repo> && codex exec resume <SESSION_ID> -m <MODEL> -c model_reasoning_effort=\"<EFFORT>\" \
  -c sandbox_mode=\"workspace-write\" -c sandbox_workspace_write.network_access=true \
  -o $S/codex_<topic>_last.md - < $S/<ruling>.md >> $S/codex_<topic>.log 2>&1; echo "codex exit=$?"
```

Codex CLI flag quirks:
- `resume` rejects `-s` and `--color`, so pass the sandbox through `-c sandbox_mode=...` instead.
- `--approve-for-me` can't be combined with `-s`, and auto-mode may block it. Don't use it.
- When resuming, append to the existing log with `>>`.

After launch, confirm the header shows the right `model:`, `reasoning effort:` and `session id:`. "failed to refresh available models" warnings are harmless.

## 3. Supervise with the event-driven monitor (not fixed-interval polling)

Start the Monitor tool with `timeout_ms: 1800000` and re-arm it when it expires:

```bash
WATCH_HOST=<gpu-host>:<ssh-port> bash ~/.claude/skills/dratamer/scripts/codex_watch.sh $S/codex_<topic>.log 900
```

Events:
- `CODEX_MSG: ...`: the first lines of each Codex agent message.
- `CODEX_MSG [after context compaction]: ...`: Codex compacted its context (the log line `context compacted`) before this message. The compaction is not a separate event: it rides on the next message, unthrottled. If Codex exits before writing another message, a `CODEX_COMPACTED` line precedes `CODEX_EXITED`. Codex usually restates its plan right after compacting, so that message is not a turn-end summary. It is also when Codex is most likely to drop constraints or drift off the main line. Read its next few messages closely against the brief and any pending ruling, and check `git status` for out-of-scope edits. If anything was lost, stop it and resume with a short ruling that restates the missing constraints.
- `CODEX_IDLE: ...`: no event for 15 minutes (the owner's chosen interval; long report writes and simulations are often silent for over 10 minutes). It includes the log age and the last shell command, which tells you whether Codex is still computing, stuck or drifting.
- `CODEX_EXITED`: Codex is done.
- Failure-specific alerts, one hook per known failure, so real failures do not wait for the idle check:
  - `CODEX_NET_RETRY` / `CODEX_NET_FAIL`: Codex API reconnecting / attempts exhausted.
  - `CODEX_ERROR`: other Codex CLI errors, including the WebSocket-to-HTTPS fallback.
  - `REMOTE_SSH_FAIL`: an ssh connect or key-auth failure in command output.
  - `NET_DOWN` / `NET_UP`: the Codex backend became unreachable / reachable (probe every 60 s).
  - `HOST_DOWN` / `HOST_UP`: `WATCH_HOST` (TCP host:port) became unreachable / reachable; omit `WATCH_HOST` for local-only tasks.
  - Alerts share a cooldown (`WATCH_COOLDOWN`, default 30 s, set by the owner): at most one alert wakes you per cooldown. Alerts inside it are counted and reported once as `ALERT_SUPPRESSED: N ..., last: ...`, and any left at exit are reported before `CODEX_EXITED`. `CODEX_MSG` (including the compaction marker), `CODEX_IDLE` and `CODEX_EXITED` are never throttled.
- Add a new pattern to the script when a new failure signature shows up, rather than shortening the idle interval.

The watcher treats any running `codex exec` process as alive, so supervise one Codex run at a time. Run only one monitor per log. Stop the old one with TaskStop before starting a new one, or you get duplicate events. To read the full new log content since your last check, run `python3 ~/.claude/skills/dratamer/scripts/codex_digest.py $S/codex_<topic>.log`. It tracks a byte offset, prints agent messages in full and truncates commands.

On each event, check for these failure patterns:
- **Lazy:**
  - hardcoded values or assumptions in place of measurements;
  - approximate methods in place of the specified ones;
  - skipped or swapped checks;
  - lowered thresholds or tuning to pass;
  - a sample count below spec;
  - claiming "done" without data.
- **Drift:**
  - starting a later phase;
  - touching protected files;
  - unrelated tooling;
  - stuck on network or nodes for more than 15 minutes;
  - the same error repeating;
  - more than 3 fixes in one step;
  - stopping on a non-critical gate, or not stopping on a critical one.

Routine progress gets one short line to the user. Don't send a push notification for it.

## 4. Intervene

1. **Stop Codex:** `pkill -f "^codex exec"`. The `^` anchor matters. An unanchored pattern also matches your own shell and kills it (exit 144).
2. **Write a ruling** to `$S/<topic>_fix_N.md`:
   - Name the root cause. If it was your own task design, say so; that is usually the case.
   - Give the corrected method or gate, and restate what is unchanged.
   - Tell Codex to record the ruling in its report.
   - Merge everything pending into one ruling, so one resume covers it all.
3. **Resume** in the background with the `resume` command above, then re-arm the monitor.
4. **Tell the user** what you changed and why.

**When Codex asks a question** (a `CODEX_MSG` ending with options and no further progress), welcome it. Two-way discussion between agents is the intended workflow, so don't forbid questions in task files. `codex exec` cannot read stdin mid-run, though, so the asking process just waits. Answer promptly: stop it, write the answer with your reasoning, then resume the same session. If the decision belongs to the user, ask the user first.

**When Codex stops on a gate:**
- First decide whether the cause is the task definition, which is your fault, or a real finding.
- If you can fix the task definition within the scope the user already approved, write the ruling and resume, then report afterwards.
- If the fix changes something the user decided, ask the user first.

## Review-only tasks (Stop That Shit plugin)

The user's Codex has the Stop That Shit Guard. In `review` mode it blocks every file write (`MODE_FORBIDS_MUTATION`) and every shell command it cannot prove read-only (`MUTABILITY_UNPROVEN`), including the report file and test runs. The user approved whitelisting the report file:

- Put this directive on the **first line** of a review task file, outside quotes and code blocks:

  ```text
  $stop-that-shit lock change files=build/experiments/<topic>_review/REVIEW.md -- Review only; write the report to this one file.
  ```

  Use the exact relative path. Separate several paths with `|`. Don't use globs.
- Still say in the task body that source, tests and docs must not be modified. The lock enforces this.
- Under a narrow `files=` lock, shell commands that can't be proven read-only still need approval, which `codex exec` cannot grant. Expect test runs to be blocked. Run the regression yourself and give Codex the results, marked "reviewer-verified".
- If the report still can't be written, take the findings from `$S/codex_<topic>_last.md`.

For execution tasks under the same Guard, set the fields the task needs on the directive line. The Guard defaults to `deps=ask` and blocks any `pip install` with `DEPENDENCY_NOT_AUTHORIZED`:

```text
$stop-that-shit change agents=0 deps=allow -- <task>
```

Use `deps=allow` only when the task actually installs packages, and state in the body which environments it may install into.

## 5. Review on exit

- Read `$S/codex_<topic>_last.md` and the report.
- Spot-check the key numbers and images yourself. Look for false passes, for example a numerical failure silently recorded as 0.
- Check `git status` to confirm no protected files changed.
- Report to the user in their language, with the absolute paths of the images and files.

## Cost notes

- Each wake-up is a full turn carrying your whole context. Prefer event-driven monitoring over fixed-interval cron polling.
- Suggest `/compact` between rounds when the context is long.
- Codex compute itself is cheap compared with your turns.
