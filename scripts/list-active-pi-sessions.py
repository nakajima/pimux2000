#!/usr/bin/env python3
import json
import os
from pathlib import Path

REGISTRY_DIR = Path.home() / ".pi" / "agent" / "runtime" / "instances"


def process_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


items = []
for path in sorted(REGISTRY_DIR.glob("*.json")):
    try:
        data = json.loads(path.read_text())
        pid = int(data.get("pid"))
        if not process_alive(pid):
            continue
        items.append(data)
    except Exception:
        continue

items.sort(key=lambda item: (item.get("cwd") or "", item.get("pid") or 0))
print(json.dumps(items, indent=2))
