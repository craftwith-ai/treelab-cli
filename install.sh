#!/usr/bin/env bash
# Entrée historique : toutes les garanties passent désormais par la CLI publique.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec "$root/bin/lab" setup --dev "$@"
