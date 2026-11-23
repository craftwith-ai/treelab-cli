#!/bin/bash
# Hook notify — Claude Code seul (lot 03 d'autonomie-tours) : question, autorisation, invite en attente, prompt envoyé, fin de tour ;
# le chemin court de lib/guard_fast.sh, sinon « lab hook notify ». Lot 10 : les mots de l'utilisateur (prompt, clic) peuvent rendre une
# consigne à la session — seule une ligne JSON hookSpecificOutput passe sur stdout, rien d'autre. Un hook cassé ne doit jamais bloquer
# le travail : toute erreur interne → sortie 0 silencieuse.
trap 'exit 0' EXIT
exec 2>/dev/null
case "$0" in */*) d="${0%/*}/.." ;; *) d=.. ;; esac
h="$PWD"; CDPATH=''
cd "$d" && cd -P . && LAB_ROOT="$PWD" || exit 0
cd "$h" || true
. "$LAB_ROOT/lib/guard_fast.sh" && notify_main
exit 0
