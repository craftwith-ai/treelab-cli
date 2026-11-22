#!/bin/bash
# Hook session-start — identique pour Claude Code et Codex ; délègue à « lab hook session-start ».
# Un hook cassé ne doit jamais bloquer le travail : toute erreur interne → sortie 0 silencieuse.
"$(cd "$(dirname "$0")/.." && pwd -P)/bin/lab" hook session-start 2>/dev/null || true
exit 0
