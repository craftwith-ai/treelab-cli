#!/bin/bash
# Hook guard-bash — les règles de Bash seules, sans le verrou de session ; même chemin que hooks/guard-tool.sh.
# Un hook cassé ne doit jamais bloquer le travail : toute erreur interne → sortie 0 silencieuse.
trap 'exit 0' EXIT
exec 2>/dev/null
case "$0" in */*) d="${0%/*}/.." ;; *) d=.. ;; esac
h="$PWD"; CDPATH=''
cd "$d" && cd -P . && LAB_ROOT="$PWD" || exit 0
cd "$h" || true
. "$LAB_ROOT/lib/guard_fast.sh" && guard_main guard-bash
exit 0
