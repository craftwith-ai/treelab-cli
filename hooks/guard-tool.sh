#!/bin/bash
# Hook PreToolUse commun — Bash, Write, Edit et apply_patch ; délègue à « lab hook guard-tool ».
# Un hook cassé ne doit jamais bloquer le travail : toute erreur interne → sortie 0 silencieuse.
"$(cd "$(dirname "$0")/.." && pwd -P)/bin/lab" hook guard-tool 2>/dev/null || true
exit 0
