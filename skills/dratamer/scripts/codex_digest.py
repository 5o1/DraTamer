#!/usr/bin/env python3
"""Print Codex log content added since the previous call: agent messages in full, commands truncated."""
import sys
from pathlib import Path

log = Path(sys.argv[1])
state = log.with_suffix(log.suffix + ".offset")
start = int(state.read_text()) if state.exists() else 0
data = log.read_bytes()
state.write_text(str(len(data)))
lines = data[start:].decode("utf-8", "replace").splitlines()
out, mode = [], None
for line in lines:
    if line in ("codex", "exec", "user"):
        mode = line
        out.append(f"--- {line}")
        continue
    if line.startswith(("hook:", "tokens used")) or line.startswith("diff --git"):
        mode = "skip" if line.startswith("diff --git") else mode
        continue
    if mode == "codex" or mode == "user":
        out.append(line)
    elif mode == "exec":
        if line.startswith(" succeeded") or line.startswith(" exited") or line.startswith(" failed"):
            out.append(line[:160])
            mode = "execout"
        else:
            out.append(line[:300])
    elif mode == "execout" and ("Error" in line or "Traceback" in line):
        out.append("   ! " + line[:200])
print(f"[bytes {start}->{len(data)}]")
print("\n".join(out[-400:]))
