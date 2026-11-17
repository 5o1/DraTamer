---
name: dratamer
description: Hand execution tasks to OpenAI Codex CLI running in the background and lead them. Claude owns the outcome: it designs the work, verifies results itself before reporting or shipping, and treats Codex's reports as claims. It splits the work into decoupled parts with disjoint write sets, and runs independent parts as parallel Codex sessions; Codex does the execution and, when delegated, the research. Claude watches Codex's log with an event-driven monitor (each agent message, failure-specific alerts with a cooldown, a silent tolerance period for network trouble, an idle check, process exit) and steps in by stopping Codex and resuming it with a written ruling. Use when the user asks to have Codex do the work, to "control/supervise codex", or to run a task through Codex in the background.
---

# Supervised Codex execution

Left unattended, Codex tends to:
- simplify the task (hardcoding values, skipping checks, swapping in weaker methods);
- drift off scope (extra tooling, starting later phases, editing protected files).

Supervising it turn by turn, on the other hand, costs many back-and-forth rounds. This workflow keeps Codex on track with few rounds.

## Roles

- **You (Claude) are the lead and own the outcome.** The user holds you accountable for what Codex produces, not Codex. Codex's messages and reports are **claims**; they become facts only after you check them against the artifact itself. Your job:
  - design: method choices, gates, root-cause analysis, and every user-facing default (see "Defaults are decisions" below);
  - write the task, research briefs and rulings;
  - **verify before you report or ship** (section 5): look at what the user will see, run what the user will run, and recompute a sample of the key numbers yourself;
  - keep the requirement ledger: the user's words, their acceptance criteria, and your own evidence for each.
- **Codex:** implementation, runs, renders, reports, and also literature and tool research. Research is delegated because it is cheaper in Codex than in your long-context turns. Give research briefs neutral questions, primary-source rules and a single report file.
- **Before dispatching:** settle every design decision you can. Confirm with the user the ones that are theirs to make. Write the conclusions into the task, so Codex has nothing to invent.

### Lead, don't relay

These failure modes come from real sessions; avoid each one:

| Failure | What it looks like | Do instead |
|---|---|---|
| **Relaying** | Each `CODEX_MSG` is paraphrased to the user as progress, and the final report is retold as the result | Stay silent on routine progress. Speak to the user when there is a decision for them, a problem, or a result **you checked**. |
| **"Done" on Codex's word** | Telling the user a feature works, or deploying it, because Codex said its tests passed | Open the UI, the images or the files yourself, the way the user will see them, before saying "done" or deploying. |
| **Hidden defaults** | Codex picked a default (panes off, a far camera, a layout) that silently defeats the request | Treat defaults as decisions. Make Codex list every default and choice it made, and check each against the user's words. |
| **Ruling conflicts** | Your own ruling ("show native pixels, don't shrink") breaks another requirement ("fit on one screen") | Before sending a ruling, re-read the requirement ledger and check that it conflicts with nothing in it. |
| **Paraphrase drift** | The user's words get restated as a stronger or different claim, attributed to the user, and built into tasks | Quote the user in the ledger and in tasks; mark your interpretation as yours. |
| **Reasoning instead of looking** | A plausible chain of reasoning ("the URDFs are mirrored, so...") replaces a direct observation, and the fix lands in the wrong layer | When the user reports a symptom, reproduce or observe it first (render it, sample it, screenshot it), then delegate the fix. |
| **Unverified pass** | A check that cannot fail, or a pass recorded from an approximation | Ask how the check could fail. Confirm it fails on the old or broken input (for example, run the new test against the previous code). |

**Requirement ledger.** Keep `$S/requirements.md`: one row per user request, with the user's verbatim words, the acceptance criteria you derived, the owning task, and the evidence **you** collected (screenshot path, recomputed number, command output). Add rows when the user adds or corrects a request. A row without your own evidence is not done, whatever Codex reports.

## Language with Codex

Use **American English** as the standard language for everything exchanged with Codex:
- task files, rulings, research briefs, fork questions and resume messages;
- Codex's own messages and reports: ask for American English in every task file.

When a task quotes the user, keep the user's words verbatim in their original language, and add an American English rendering marked as yours. The requirement ledger follows the same rule.

This applies only to the Claude–Codex channel. Talk to the user in the user's language, and translate Codex's findings when you report them.

## Decouple the work, then run Codex sessions in parallel

Before writing any task, split the work by **write set**: the files, modules, output directories and runtime resources each part will change.

- **Disjoint write sets** → one Codex session per part, launched in parallel. Each gets its own task file, log, session id and monitor. Don't queue them behind each other, and don't fold them into one session.
- **Overlapping write sets** (for example, two features on the same page or pipeline) → one session, or run them one after another.

Prefer splitting whenever it is possible; parallel sessions finish sooner, and a narrow task keeps Codex on track. To make work splittable, design for it when you write the tasks:

- Put new logic in new modules with a narrow interface, so each task owns new files instead of editing shared ones.
- When a shared file must change (a registry, a config schema, a web page, a backend), give it to **exactly one** session. Every other task lists it under "do not touch" and reads it only.
- Fix the interfaces up front: function signatures, JSON schemas, file names and output paths. Write them into every task that produces or consumes them, so no session has to wait for another to decide them.
- Give each session its own report directory and run directory.

**New requests while Codex runs.** First compare the request's write set with the running session's:
- It overlaps (the request changes code that session is editing) → stop and resume that session with a ruling (section 4), and merge everything pending into one ruling.
- It does not overlap → launch a new parallel session. Don't interrupt a session for work it doesn't own.

**One branch and one worktree per parallel session (default).** Parallel sessions never share a working tree; one session overwriting another's files is a real failure seen in practice.

1. **Before launching:** create the session's own branch and worktree, `git worktree add ../<repo>-wt/<topic> -b task/<topic> main`, and launch Codex with `cd` into it.
   - If the project isn't a git repo yet, `git init` it first and commit a baseline on main.
   - Track code and text only. Keep large generated or input directories out of git (`.gitignore`), and symlink them into each worktree from the main tree. Write those ignore patterns without a trailing slash (`/build`, not `/build/`): a symlink is not a directory to git, so `/build/` leaves it untracked and `git worktree remove` refuses to delete the worktree.
2. **During the session:** Codex edits and commits only on its own branch, inside its worktree.
   - Commit messages carry the session's attribution lines.
   - No `git stash`, `checkout`, `reset`, `clean` or tree-wide formatters in any worktree.
3. **When it finishes:**
   - Review it (section 5) inside its worktree.
   - Merge the branch into main with `git merge --no-ff`, then delete the worktree directory (`git worktree remove`) and the branch.
   - An abandoned session's worktree and branch are removed too. Don't leave stale worktrees behind.
   - A small helper script (`new` / `merge` / `drop`) keeps this uniform.
4. **What worktrees don't isolate:**
   - Symlinked artifact directories, remote run directories and services are still shared.
   - Sessions that write the same shared artifact (for example a timeline file, a final render, or a remote code sync) must run one after another, or get distinct output paths in their tasks. See shared runtime resources below.
5. **Tests and checks:** each session runs targeted tests in its own worktree. The reviewer runs the full suite on main after merging. Repo-wide checks that flag another session's files are reported, not fixed.

Only a single session working alone may use the main tree directly.

**Shared runtime resources** (a robot station, GPUs, ports, a running service, a remote run directory): assign each one to a single session, or give each session distinct devices (`CUDA_VISIBLE_DEVICES`), ports and run directories. Say in each task which resources it may use.

**Bookkeeping.** Keep a short table in `$S/sessions.md` with topic, session id, PID, log, write set and status, and update it on every launch and exit. Run exactly one monitor per log, each with its own `WATCH_PID`.

**Limits.** Every monitor event wakes you for a full turn, so the practical ceiling is about 2–4 parallel sessions. Codex sub-agents (below) split one task with shared context. Parallel sessions are for independent tasks.

**Review and merge per session.** Review each session when it exits, on its own, in its worktree.
- Check that its branch changes only its write set: `git diff main...task/<topic> --stat`.
- Merge into main, then remove the worktree and the branch.
- If two branches touched the same file, read the merge diff before resolving the conflict.

## 1. Write the task file

Put it in the session scratchpad, e.g. `$S/codex_<topic>_task.md`, and write it in American English (see "Language with Codex"). Include:

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
- **Write set and "do not touch" list.** Name the files and directories this task owns, the files other running sessions own (read-only here), and the runtime resources it may use. When other sessions run in parallel, name this session's branch and worktree path, tell it to commit only there, and list the shared artifacts it must not write.
- **Deliverables:** a report with an "unauthorized choices I made" section listing **every default and user-facing choice** (what it is, alternatives, why), plus a reproducible script. Also ask for **verification handles**: the commands, URLs or files you will use to check the result yourself (for example a screenshot command for a UI, or the raw data behind each key number).
- **End with paths.** The last message must list absolute paths of all images and key files, so they can be opened directly.

## 2. Launch

Agree on the model and reasoning effort with the user, and pass them on the command line. Never edit `~/.codex/config.toml`; other projects use it. Run with `run_in_background: true`:

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
WATCH_PID=<codex pid> bash ~/.claude/skills/dratamer/scripts/codex_watch.sh $S/codex_<topic>.log 900
```

Events:
- `CODEX_MSG: ...`: the first lines of each Codex agent message.
- `CODEX_MSG [after context compaction]: ...`: Codex compacted its context (the log line `context compacted`) before this message. The compaction is not a separate event: it rides on the next message, unthrottled. If Codex exits before writing another message, a `CODEX_COMPACTED` line precedes `CODEX_EXITED`. Codex usually restates its plan right after compacting, so that message is not a turn-end summary. It is also when Codex is most likely to drop constraints or drift off the main line. Read its next few messages closely against the brief and any pending ruling, and check `git status` for out-of-scope edits. If anything was lost, stop it and resume with a short ruling that restates the missing constraints.
- `CODEX_IDLE: ...`: no event for the idle interval (the second argument; 900 s works well because long report writes and simulations are often silent for over 10 minutes). It includes the log age and the last shell command, which tells you whether Codex is still computing, stuck or drifting.
- `CODEX_EXITED`: Codex is done.
- Failure-specific alerts, one hook per known failure, so real failures do not wait for the idle check:
  - `CODEX_ERROR`: Codex CLI errors other than network errors.
  - `REMOTE_SSH_FAIL`: an ssh connect or key-auth failure in command output.
  - `NET_PROBLEM` / `NET_RECOVERED`: network trouble that outlasted the tolerance period / its end.
  - Alerts share a cooldown (`WATCH_COOLDOWN`, default 30 s): at most one alert wakes you per cooldown. Alerts inside it are counted and reported once as `ALERT_SUPPRESSED: N ..., last: ...`, and any left at exit are reported before `CODEX_EXITED`. `CODEX_MSG` (including the compaction marker), `CODEX_IDLE` and `CODEX_EXITED` are never throttled.
- **Network tolerance period.** Brief network trouble needs no action, because Codex reconnects on its own. API reconnects, websocket/TLS/transport errors and an unreachable Codex backend open a silent tolerance period, during which the backend is probed every 10 s.
  - As soon as a probe succeeds, the period closes and nothing is reported.
  - A period still open after `WATCH_OUTAGE` seconds (default 300) raises one `NET_PROBLEM`. When the backend is reachable again, `NET_RECOVERED` follows.
  - A new interruption after a recovery opens a new period. Only one period is open at a time.
- Add a new pattern to the script when a new failure signature shows up, rather than shortening the idle interval.

Other sessions may run their own Codex on the same machine. Always pass `WATCH_PID` (the PID of the `codex exec` you launched; get it with `$!` or `pgrep -f "codex exec resume <SESSION_ID>"`); without it the watcher treats any `codex exec` as alive. Run only one monitor per log. Stop the old one with TaskStop before starting a new one, or you get duplicate events. To read the full new log content since your last check, run `python3 ~/.claude/skills/dratamer/scripts/codex_digest.py $S/codex_<topic>.log`. It tracks a byte offset, prints agent messages in full and truncates commands.

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

Events are for **steering**, not narration. On a routine `CODEX_MSG`, check it against the brief and the ledger and say nothing to the user, unless it needs their decision, reveals a problem, or carries a result you have verified. When you do pass something on, state what you checked ("I checked X: ..."). For anything you have not checked yet, don't attach a passive label such as "not yet verified": later turns, and new contexts that inherit this one, tend to ignore it. Write the check as your own next action, in the first person, naming the artifact and what to look for: "Next turn I should open `<path>` and check that ...". Don't send push notifications for routine progress.

Use the waiting time: while Codex works, prepare the acceptance checks you will run on exit, such as screenshot commands, the numbers to recompute and the old inputs that must fail.

## 4. Intervene

0. **Check whether it belongs to this session.** If the change is new work outside this session's write set, launch a parallel session instead (see "Decouple the work") and leave this one running.
1. **Stop Codex:** `kill <pid>` for the run you launched, or `pkill -f "^codex exec resume <SESSION_ID>"`. Never use a bare `pkill -f "^codex exec"`: other sessions may run their own Codex. The `^` anchor matters; an unanchored pattern also matches your own shell and kills it (exit 144).
2. **Write a ruling** to `$S/<topic>_fix_N.md`:
   - Name the root cause. If it was your own task design, say so; that is usually the case.
   - Give the corrected method or gate, and restate what is unchanged.
   - Tell Codex to record the ruling in its report.
   - Merge everything pending into one ruling, so one resume covers it all.
3. **Resume** in the background with the `resume` command above, then re-arm the monitor.
   - Resume only after the monitor reports `CODEX_EXITED` for the run you stopped or that ended its turn. If you resume while it still runs, two processes write to the same session.
   - Don't wait for the exit with a foreground loop such as `until ! pgrep ...; do sleep 3; done`. It blocks your session, adds nothing the watcher doesn't already report, and the user has to background it by hand. Wait for the `CODEX_EXITED` event instead, then run the resume command.
4. **Tell the user** what you changed and why.

**When Codex asks a question** (a `CODEX_MSG` ending with options and no further progress), welcome it. Two-way discussion between agents is the intended workflow, so don't forbid questions in task files. `codex exec` cannot read stdin mid-run, though, so the asking process just waits. Answer promptly: stop it, write the answer with your reasoning, then resume the same session. If the decision belongs to the user, ask the user first.

### Side questions and discussion (btw)

Codex's interactive `/btw` (side conversation) forks the thread so a question doesn't pollute the main line. The non-interactive equivalent is `codex exec fork`, verified with Codex 0.163:

```bash
# Ask a forked copy of the session; the main thread is untouched. Like resume, fork rejects -s.
codex exec fork <SESSION_ID> -m <MODEL> -c model_reasoning_effort=\"low\" \
  -c sandbox_mode=\"read-only\" --ephemeral -o $S/btw_<topic>.md \
  "This is a side question. Do not modify any files. <question>"
```

- **Asking while Codex works.** Fork whenever you need Codex's reasoning: why it chose X, what it tried and dropped, what it is unsure of. This works while the main run continues. The fork sees only the context saved so far, so the answer may lag the live run.
- **Discussion.** Before a ruling, you can fork to talk a design question through: give your proposal and ask for objections and missing facts. Several forks can go back and forth. Put the agreed conclusion into the ruling file; forks are discarded.
- **Taking over a session.** Instead of reading the whole log, fork and ask for a handoff with four parts:
  - current state;
  - decisions made and why;
  - open issues;
  - claims Codex itself has not verified.
  Then spot-check the key facts against primary artifacts before acting on them.
- **Verifying what Codex says.** Its answers explain things but are not evidence. Check numbers, file changes and test results against logs and files. Codex drifts, especially after compaction, and its self-report inherits the drift.
- **Use read-only and `--ephemeral`.** A side question must never edit files or launch runs. Pass `--ephemeral` so the fork isn't saved as a session; drop it only when you want to keep a fork, for example a handoff you will resume.
- **Watching a fork.** Get the PID with `pgrep -f "^codex exec fork <SID>"`. An unanchored pattern also matches your own wrapper shells, which exit quickly and make the watcher report `CODEX_EXITED` too early. Forking a session whose last tool call was still open logs many `Orphan custom tool call output` errors; they are harmless.
- **Remote files for read-only forks.** Before forking, mount the remote run directory read-only on the local machine, so that Codex can read it with plain `cat`/`grep`/`ls` in a read-only sandbox:

  ```bash
  sshfs -o ro,reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,attr_timeout=5,entry_timeout=5,BatchMode=yes \
    <host>:<remote_dir> /tmp/<host>-ro
  ```

  Tested: reads work, and writes fail with "Read-only file system". Limitations:
  - Remote `/proc` reads come back empty over SFTP.
  - `nvidia-smi` cannot be reached this way.

  For process and GPU state, use a status file that the experiment writes, or check it yourself over ssh. A dropped network can hang reads on the mount, so wrap them in `timeout`. Unmount with `fusermount -u`.
- **`codex queue --thread <SID> --message <TEXT>` does not steer a running `codex exec`.** Tested: the running turn never saw the message. The message is delivered on the next `resume`. Use it to leave a note for the next turn. To change course mid-run, still stop the run and resume it with a ruling.

**When Codex stops on a gate:**
- First decide whether the cause is the task definition, which is your fault, or a real finding.
- If you can fix the task definition within the scope the user already approved, write the ruling and resume, then report afterwards.
- If the fix changes something the user decided, ask the user first.

## Sub-agents

Codex can spawn sub-agents, which speeds up work that splits into independent parts, such as separate comparison runs or repeated measurements. When a task has such parts, allow sub-agents, and say in the brief:
- which parts may run in parallel;
- which output paths each sub-agent owns. Leave edits to shared code to the main agent.

Keep the task to the main agent when every step edits the same code. For separate tasks rather than parts of one task, use parallel sessions instead (see "Decouple the work").

The watcher follows the main agent. Its messages and its final report carry the sub-agents' results, and idle alerts while it waits on sub-agents are expected. Each sub-agent writes its own session file under `~/.codex/sessions/`, which you can read when you need detail.

## 5. Acceptance review on exit (you, not Codex)

Codex's report tells you where to look; it is not the evidence. Before you tell the user a task is done, commit it or deploy it:

1. **Read** `$S/codex_<topic>_last.md`, the report, and its list of choices and defaults. Check every default against the ledger.
2. **Inspect the artifact as the user will meet it.** Match the check to the kind of artifact:

   | Artifact | Your own check |
   |---|---|
   | UI or web page | Load it in a real browser at the user's viewport sizes, screenshot it and look: everything requested visible, nothing overflowing, defaults right. Interact with the new controls. |
   | Images, renders, drawings | Open the key images yourself. Check orientation, frame of reference, labels, and that the figure shows what the claim says. |
   | CAD or geometry | Render in the frame the user works in (for example world or table-up), measure the key dimensions, and look for features nobody asked for. |
   | Numbers and metrics | Recompute one or two key numbers independently from raw outputs, and confirm the denominator and units. |
   | Code and tests | Read the diff of the risky parts. Run the tests yourself. Confirm a new test fails on the old code. |
   | Deployment or live service | Check the deployed state directly: version or hash, service status, and the live page or output, not just "restart succeeded". |
   | Research | Open two or three key citations at the source and confirm the quoted numbers. |

3. **Check scope:** `git status` shows no protected or out-of-scope files changed, and no large or private files landed in the repo.
4. **Update the ledger** with your evidence. For anything you could not check yet, write the check as your own first-person next action ("Next turn I should open `<path>` and check ..."), with the reason it is still open. Not a passive "unverified" label.
5. **Report** to the user in their language. Give what you verified, with absolute paths to the evidence, then the checks still open, each phrased as your own next action ("Next turn I should ...", or in the user's language, e.g. "接下来我该…").

If your check fails, don't relay the failure as Codex's news. Own it: say what you found, then resume Codex with a ruling, or fix it yourself.

## Cost notes

- Each wake-up is a full turn carrying your whole context. Prefer event-driven monitoring over fixed-interval cron polling.
- Suggest `/compact` between rounds when the context is long.
- Codex compute itself is cheap compared with your turns.
