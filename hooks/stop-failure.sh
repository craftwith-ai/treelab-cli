#!/bin/bash
# Hook stop-failure — Claude Code seul, limite d’usage (lot 02 de cmux-pro) ; délègue à « lab hook stop-failure ».
# Un hook cassé ne doit jamais bloquer le travail : toute erreur interne → sortie 0 silencieuse.
"$(cd "$(dirname "$0")/.." && pwd -P)/bin/lab" hook stop-failure 2>/dev/null || true
exit 0
