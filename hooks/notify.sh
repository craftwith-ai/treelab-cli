#!/bin/bash
# Hook notify — Claude Code seul (lot 03 d'autonomie-tours) : question, autorisation, invite en attente, prompt envoyé ; délègue à
# « lab hook notify ». Lot 10 : les mots de l'utilisateur (prompt, clic) peuvent rendre une consigne à la session — seule une ligne
# JSON hookSpecificOutput passe sur stdout, rien d'autre. Un hook cassé ne doit jamais bloquer le travail : toute erreur interne →
# sortie 0 silencieuse.
out="$("$(cd "$(dirname "$0")/.." && pwd -P)/bin/lab" hook notify 2>/dev/null)" || true
printf '%s\n' "$out" | grep -m1 '^{"hookSpecificOutput":' || true
exit 0
