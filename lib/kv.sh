# shellcheck shell=bash
# kv.sh — lecture d'un fichier KEY=value par le shell seul, sans processus (lot 01 de charge-processeur) : sed, head et les sous-shells
# autour en coûtaient 4 à 6 par valeur, des milliers par garde. Autonome : chargé par lib/project.sh, lib/lock.sh, lib/tower.sh et
# lib/words.sh, que des scripts et des tests chargent seuls.

# kv_value <fichier> <clé> : KV_VALUE = la valeur de la première ligne « clé=… » ; la clé est littérale. rc 1, KV_VALUE vide, si le
# fichier ne se lit pas ou si la clé manque
kv_value() {
  local line
  KV_VALUE=''
  [ -f "$1" ] && [ -r "$1" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) KV_VALUE="${line#"$2="}"; return 0 ;; esac
  done <"$1"
  return 1
}
# kv_print <fichier> <clé> → la valeur ; rien si la clé manque (rc 0), rc 1 si le fichier ne se lit pas
kv_print() {
  if kv_value "$1" "$2"; then printf '%s\n' "$KV_VALUE"; else [ -f "$1" ] && [ -r "$1" ]; fi
}
