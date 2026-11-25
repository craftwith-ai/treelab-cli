# shellcheck shell=bash
# snapshot.sh — la marque de l'instantané des couloirs (lot 03 d'app-treelab). lab tient pour Treelab.app, sous
# $LAB_STATE/app-snapshot, ce que lab app lanes répondrait, couloir par couloir (lib/app.sh l'écrit) ; l'app le lit sans lancer lab.
# Ici, seulement ce que fait chaque point d'écriture (attente, verrou de session, file de fusion, accord, mots, état d'un veilleur) :
# noter son couloir dans pending, puis lancer l'écrivain détaché (lab app snapshot --pending), sauf si un écrivain vivant tient déjà le
# verrou — il relit pending avant de le rendre. Sans lecteur vivant (marque reader posée par l'app, pid vérifié par kill -0) : rien
# noté, aucun processus. Chargé avant chaque prompt et chaque fin de tour d'un agent (lib/guard_fast.sh) : aucun processus hors du
# lancement de l'écrivain, sortie 0 quoi qu'il arrive, jamais d'attente.

# snap_dir_set : SNAP_DIR, même règle que lib/project.sh (LAB_STATE, sinon LAB_STATE_DIR, sinon $LAB_HOME/state), sans la charger
snap_dir_set() {
  local st="${LAB_STATE:-${LAB_STATE_DIR:-}}" home="${LAB_HOME:-}"
  if [ -z "$st" ]; then
    if [ -z "$home" ]; then if [ -f "${LAB_ROOT:-}/.release" ]; then home="$HOME/.lab"; else home="${LAB_ROOT:-$HOME/.lab}"; fi; fi
    st="$home/state"
  fi
  SNAP_DIR="$st/app-snapshot"
}
# snap_pid_alive <pid> : kill -0, ou refusé faute de droit (bac à sable d'un agent) — le processus existe
snap_pid_alive() {
  case "${1:-}" in ''|*[!0-9]*|0*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null && return 0
  case "$(kill -0 "$1" 2>&1)" in *ermitted*) return 0 ;; esac
  return 1
}
# snap_reader : rc 0 si un lecteur vivant a posé sa marque (un fichier absent : aucun processus). Un lecteur reconnu mort l'est une
# fois : .dead.<pid> le retient, sans sous-processus aux points d'écriture suivants (app tuée, marque restée ; revue du lot 03) ;
# lab app snapshot --reader l'efface en reposant une marque (pid recyclé)
snap_reader() {
  local pid=''
  snap_dir_set
  { IFS= read -r pid <"$SNAP_DIR/reader"; } 2>/dev/null || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ ! -e "$SNAP_DIR/.dead.$pid" ] || return 1
  snap_pid_alive "$pid" && return 0
  { : >"$SNAP_DIR/.dead.$pid"; } 2>/dev/null || true
  return 1
}
# snap_mark <dossier du couloir> · snap_mark_lane <projet> <couloir de .lab/meta> : le couloir à réécrire
snap_mark() { snap_reader || return 0; snap_note "W"$'\t'"$1"; }
snap_mark_lane() { snap_reader || return 0; snap_note "L"$'\t'"$1"$'\t'"$2"; }
snap_note() {
  { printf '%s\n' "$1" >>"$SNAP_DIR/pending"; } 2>/dev/null || return 0
  snap_spawn
}
# snap_spawn : l'écrivain, détaché, descripteurs fermés (le crochet n'attend rien), insensible à la fermeture de l'onglet ;
# LAB_SNAP_SYNC=1 (tests) le déroule sur place
snap_spawn() {
  local pid=''
  { IFS= read -r pid <"$SNAP_DIR/lock"; } 2>/dev/null || true
  ! snap_pid_alive "$pid" || return 0
  [ -n "${LAB_ROOT:-}" ] && [ -x "$LAB_ROOT/bin/lab" ] || return 0
  if [ "${LAB_SNAP_SYNC:-0}" = 1 ]; then "$LAB_ROOT/bin/lab" app snapshot --pending </dev/null >/dev/null 2>&1 || true; return 0; fi
  ( trap '' HUP INT; exec "$LAB_ROOT/bin/lab" app snapshot --pending ) </dev/null >/dev/null 2>&1 3>&- &
  return 0
}
