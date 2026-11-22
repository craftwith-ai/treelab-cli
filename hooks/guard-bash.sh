#!/bin/bash
# Hook guard-bash — identique pour Claude Code et Codex ; délègue à « lab hook guard-bash ».
# Un hook cassé ne doit jamais bloquer le travail : toute erreur interne → sortie 0 silencieuse.
"$(cd "$(dirname "$0")/.." && pwd -P)/bin/lab" hook guard-bash 2>/dev/null || true
exit 0
