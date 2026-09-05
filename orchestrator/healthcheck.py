#!/usr/bin/env python3
"""Fail when the orchestrator heartbeat is missing, stale, or degraded."""

import json
import os
import sys
import time
from pathlib import Path

path = Path(os.environ.get("HEARTBEAT_PATH", "/logs/health.json"))
maximum_age = int(os.environ.get("HEALTH_MAX_AGE_SECONDS", "1800"))

try:
    heartbeat = json.loads(path.read_text(encoding="utf-8"))
    age = time.time() - int(heartbeat["epoch"])
    healthy = heartbeat.get("status") in {"starting", "ok"} and 0 <= age <= maximum_age
except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError):
    healthy = False

sys.exit(0 if healthy else 1)
