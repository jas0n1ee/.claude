#!/bin/bash
# Swarm stop hook — soft error mode: never block Claude exit
exec python3 ~/.claude/swarm/swarm.py stop-hook 2>/dev/null || true
