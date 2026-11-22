#!/bin/bash
# memcap — CLAUDE_CODE_SHELL_PREFIX de l'agent d'une VM Cloud (lot 02 de cloud-agent-mort), recopié en ~/.lab-fin/memcap par
# cloud_vm_script. Claude Code lui passe chaque commande (hooks compris) en un seul argument : elle devient la victime prioritaire
# du tueur OOM et tourne sous un plafond cgroup (systemd-run --user --scope -p MemoryMax=), pour qu'une commande emballée meure
# avant l'agent. Jamais un blocage : sans plafond, la commande part quand même, annoncée une fois.
#   memcap --setup [meminfo] : au lancement du terminal VM — linger, plafond MemTotal − 4 Go (moitié sous 8 Go) ou
#                              LAB_CLOUD_MEM_MAX, sondé une fois ; une ligne au terminal
#   memcap <commande>        : la commande de l'agent (plusieurs arguments : exécutés tels quels, sans shell)
dir="$HOME/.lab-fin"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"   # bus du gestionnaire systemd de l'utilisateur
unavailable() { mkdir -p "$dir" 2>/dev/null; printf 'lab: memory cap unavailable (%s): commands run uncapped\n' "$1" >&2; : >"$dir/memcap.warned"; }
# say <ligne> : ligne du réglage repliée au mot à la largeur du terminal, 40 à 80 colonnes (onboard_cols, absent de la VM) ;
# sans terminal ni COLUMNS, entière
say() {
  local c="${COLUMNS:-}"
  case "$c" in ''|*[!0-9]*) c="$({ stty size </dev/tty; } 2>/dev/null | awk '{print $2}')" ;; esac
  case "$c" in ''|*[!0-9]*) printf '%s\n' "$1"; return ;; esac
  if [ "${#c}" -gt 3 ] || [ "$c" -gt 80 ]; then c=80; fi
  [ "$c" -ge 40 ] || c=40
  printf '%s\n' "$1" | fold -s -w "$c" | sed 's/ *$//'
}

if [ "${1:-}" = --setup ]; then
  mkdir -p "$dir"; rm -f "$dir/memcap.max" "$dir/memcap.warned"
  if command -v loginctl >/dev/null 2>&1; then   # sans session de connexion, seul le linger démarre le gestionnaire de l'utilisateur
    sudo -n loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$XDG_RUNTIME_DIR/bus" ] && break; sleep 1; done
  fi
  max="${LAB_CLOUD_MEM_MAX:-}"
  if [ -n "$max" ] && ! [[ "$max" =~ ^[1-9][0-9]*[KMGT]?$ ]]; then   # systemd refuserait la valeur : plus aucun plafond (revue)
    say "lab: LAB_CLOUD_MEM_MAX ignored ($max): a size such as 24G is expected"; max=''
  fi
  if [ -z "$max" ]; then
    mb="$(awk '/^MemTotal:/ {print int($2 / 1024)}' "${2:-/proc/meminfo}" 2>/dev/null)"
    case "$mb" in ''|*[!0-9]*) say "$(unavailable "MemTotal unreadable" 2>&1)"; exit 0 ;; esac
    reserve=4096; [ "$mb" -ge 8192 ] || reserve=$((mb / 2))
    max="$((mb - reserve))M"
  fi
  if ! command -v systemd-run >/dev/null 2>&1; then say "$(unavailable "no systemd-run" 2>&1)"
  elif ! systemd-run --user --scope -q -p MemoryMax="$max" -- true >/dev/null 2>&1; then say "$(unavailable "systemd-run --user refused" 2>&1)"
  else printf '%s\n' "$max" >"$dir/memcap.max"; say "lab: commands capped at $max of memory: a runaway one dies, not the agent"
  fi
  exit 0
fi

{ echo 1000 >/proc/self/oom_score_adj; } 2>/dev/null || true   # hérité par la commande : sans root, on ne peut que monter
[ "$#" -ne 1 ] || set -- /bin/bash -c "$1"
max="$(cat "$dir/memcap.max" 2>/dev/null)"
if [ -n "$max" ] && [ -S "$XDG_RUNTIME_DIR/bus" ] && command -v systemd-run >/dev/null 2>&1; then
  exec systemd-run --user --scope -q -p MemoryMax="$max" -- "$@"
fi
# gestionnaire utilisateur tombé depuis le réglage : systemd-run échouerait sans lancer la commande, jamais un blocage (revue)
if [ -n "$max" ]; then [ -e "$dir/memcap.warned" ] || unavailable "user bus gone"
else [ -e "$dir/memcap.warned" ] || unavailable "not set up on this machine"; fi
exec "$@"
