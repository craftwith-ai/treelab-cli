#!/bin/bash
# Hook PreToolUse commun — Bash, Write, Edit et apply_patch : le chemin court de lib/guard_fast.sh, puis, au moindre doute, le chemin
# complet (lib/hooks.sh) dans ce même processus ; « lab hook guard-tool » fait la même chose.
# Un hook cassé ne doit jamais bloquer le travail : toute erreur interne → sortie 0 silencieuse.
trap 'exit 0' EXIT
exec 2>/dev/null
case "$0" in */*) d="${0%/*}/.." ;; *) d=.. ;; esac
h="$PWD"; CDPATH=''
cd "$d" && cd -P . && LAB_ROOT="$PWD" || exit 0
cd "$h" || true
. "$LAB_ROOT/lib/guard_fast.sh" && guard_main guard-tool
exit 0
