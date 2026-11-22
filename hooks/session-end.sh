#!/bin/bash
# Hook session-end — identique pour Claude Code et Codex ; délègue à « lab hook session-end ».
# Un hook cassé ne doit jamais bloquer le travail : toute erreur interne → sortie 0 silencieuse.
"$(cd "$(dirname "$0")/.." && pwd -P)/bin/lab" hook session-end 2>/dev/null || true
exit 0
