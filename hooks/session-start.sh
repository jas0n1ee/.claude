#!/bin/bash
# Swarm session-start hook — soft error mode: Claude must always start
exec python3 ~/.claude/swarm/swarm.py session-start 2>/dev/null || true
