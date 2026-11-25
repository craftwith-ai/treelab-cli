#!/bin/bash
# Hook session-start — identique pour Claude Code et Codex : le démarrage de session (lib/hooks.sh) dans ce processus, avec ses seules
# bibliothèques ; « lab hook session-start » fait la même chose.
# Un hook cassé ne doit jamais bloquer le travail : toute erreur interne → sortie 0 silencieuse.
trap 'exit 0' EXIT
exec 2>/dev/null
case "$0" in */*) d="${0%/*}/.." ;; *) d=.. ;; esac
h="$PWD"; CDPATH=''
cd "$d" && cd -P . && LAB_ROOT="$PWD" || exit 0
cd "$h" || true
. "$LAB_ROOT/lib/guard_fast.sh" && session_main "$$"   # ses ancêtres, depuis lui-même (lot 01 de fix-nuit-2026-11-24)
exit 0
