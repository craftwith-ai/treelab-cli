# shellcheck shell=bash
# migrations.sh — migrations déclarées (lot 02 de sans-perte). Clé du projet : migrations=<dossier> [<dossier>…], chemins depuis la
# racine du dépôt ; le numéro d'une migration = les chiffres en tête de son nom (0012_x.sql → 12). Collision : un fichier AJOUTÉ par la
# branche dont le numéro existe déjà, dans le même dossier, sous un autre nom (sur la base fraîche, ou ajouté par un autre couloir).
# Une migration modifiée, ou renommée sans changer de numéro (l'ancien nom supprimé par la branche), passe. Sans clé : aucun contrôle.

migrations_dirs() { # → un dossier déclaré par ligne, sans « / » final
  local d; local -a t=()
  read -r -a t <<<"${P_MIGRATIONS:-}"
  for d in "${t[@]+"${t[@]}"}"; do d="${d%/}"; [ -z "$d" ] || printf '%s\n' "$d"; done
}
# migrations_changes <wt> <ref> [<sha>] → lignes « A\tchemin » (ajoutés) et « D\tchemin » (supprimés) depuis la base commune de <sha>
# et <ref>, limitées aux dossiers déclarés. Sans <sha> : HEAD plus l'arbre de travail (modifs indexées ou non, fichiers non suivis) —
# le démarrage de session voit une migration pas encore commitée. Renommages vus comme suppression + ajout. rc 2 : base illisible.
migrations_changes() {
  local wt="$1" ref="$2" sha="${3:-}" mb; local -a dirs=()
  while IFS= read -r mb; do dirs+=("$mb"); done < <(migrations_dirs)
  [ "${#dirs[@]}" -gt 0 ] || return 0
  mb="$(git -C "$wt" merge-base "${sha:-HEAD}" "$ref" 2>/dev/null)" || return 2
  if [ -n "$sha" ]; then
    git -C "$wt" -c core.quotePath=false diff --no-renames --name-status --diff-filter=AD "$mb" "$sha" -- "${dirs[@]}" 2>/dev/null || return 2
  else
    git -C "$wt" -c core.quotePath=false diff --no-renames --name-status --diff-filter=AD "$mb" -- "${dirs[@]}" 2>/dev/null || return 2
    git -C "$wt" -c core.quotePath=false ls-files --others --exclude-standard -- "${dirs[@]}" 2>/dev/null | sed 's/^/A	/'
  fi
}
# migrations_base_files <wt> <ref> → les fichiers des dossiers déclarés sur <ref>, en lignes « B\tchemin »
migrations_base_files() {
  local -a dirs=(); local d
  while IFS= read -r d; do dirs+=("$d"); done < <(migrations_dirs)
  [ "${#dirs[@]}" -gt 0 ] || return 0
  git -C "$1" -c core.quotePath=false ls-tree -r --name-only "$2" -- "${dirs[@]}" 2>/dev/null | sed 's/^/B	/'
}
# migrations_match : lignes « A|D|B\tchemin[\tétiquette] » sur stdin → « ajouté\ten place[ (étiquette)]\tnom proposé » par collision.
# Le nom proposé prend le prochain numéro libre du dossier (au-delà de tous les numéros connus, base et branche), même largeur.
migrations_match() {
  awk -F'\t' '
    function num(p,  n) { n = p; sub(/.*\//, "", n); if (match(n, /^[0-9]+/)) return substr(n, 1, RLENGTH); return "" }
    function dir(p) { if (p ~ /\//) { sub(/\/[^\/]*$/, "", p); return p } return "." }
    { k = num($2); if (k == "") next; d = dir($2); v = k + 0; if (v > max[d]) max[d] = v }
    $1 == "D" { del[$2] = 1; next }
    $1 == "A" { na++; ap[na] = $2; next }
    $1 == "B" { nb[d SUBSEP v]++; bp[d SUBSEP v, nb[d SUBSEP v]] = $2 (($3 != "") ? " (" $3 ")" : ""); braw[d SUBSEP v, nb[d SUBSEP v]] = $2 }
    END {
      for (i = 1; i <= na; i++) {
        a = ap[i]; k = num(a); d = dir(a); key = d SUBSEP (k + 0)
        for (j = 1; j <= nb[key]; j++) {
          b = braw[key, j]; if (b == a || (b in del)) continue
          n = a; sub(/.*\//, "", n); rest = substr(n, length(k) + 1)
          max[d]++; prop = sprintf("%0" length(k) "d", max[d]) rest
          printf "%s\t%s\t%s\n", a, bp[key, j], prop; break
        }
      }
    }'
}
# migrations_collide <wt> <ref> [<sha>] : collisions des migrations ajoutées par <sha> (sans <sha> : arbre de travail) avec <ref>.
# Pose MIGRATION_COLLISIONS (lignes de migrations_match) ; rc 0 aucune ou aucune clé, 1 collision, 2 non vérifiable.
migrations_collide() {
  local changes rc=0; MIGRATION_COLLISIONS=""
  [ -n "$(migrations_dirs)" ] || return 0
  changes="$(migrations_changes "$@")" || rc=$?
  [ "$rc" = 0 ] || return 2
  [ -n "$changes" ] || return 0
  MIGRATION_COLLISIONS="$( { printf '%s\n' "$changes"; migrations_base_files "$1" "$2"; } | migrations_match)"
  [ -z "$MIGRATION_COLLISIONS" ] || return 1
}
# migrations_report <réf> : les collisions sur stderr, une par ligne, avec le remède
migrations_report() {
  local a b p
  printf 'lab: REFUSED — migration(s) with a number already taken on %s:\n' "$1" >&2
  while IFS=$'\t' read -r a b p; do printf '  - %s: number already taken by %s — rename to %s\n' "$a" "${b##*/}" "$p" >&2; done <<<"$MIGRATION_COLLISIONS"
  printf 'Rename (git mv), commit and push; no automatic renumbering.\n' >&2
}
# migrations_brief → « a.sql ↔ b.sql : renommer en c.sql » pour la première collision, « (+N) » s'il y en a d'autres
migrations_brief() {
  local a b p n; n="$(printf '%s\n' "$MIGRATION_COLLISIONS" | sed '/^$/d' | wc -l | tr -d ' ')"
  IFS=$'\t' read -r a b p <<<"$MIGRATION_COLLISIONS"
  printf '%s ↔ %s: rename to %s' "${a##*/}" "${b##*/}" "$p"
  [ "$n" -le 1 ] || printf ' (+%s)' "$((n - 1))"
  printf '\n'
}
# migrations_hook_line <worktree> : alerte du démarrage de session — collision avec <remote>/<pr-target> (référence locale, sans réseau)
# ou avec les migrations ajoutées dans les autres worktrees du projet. Une ligne courte, rien sinon ; n'échoue jamais.
migrations_hook_line() {
  local wt="$1" ref changes other lane
  [ -n "$(migrations_dirs)" ] || return 0
  ref="${P_REMOTE:-origin}/$(pr_base)"
  changes="$(migrations_changes "$wt" "$ref" 2>/dev/null)" || return 0
  printf '%s\n' "$changes" | grep -q '^A' || return 0
  MIGRATION_COLLISIONS="$( {
    printf '%s\n' "$changes"; migrations_base_files "$wt" "$ref"
    while IFS= read -r other; do
      if [ -z "$other" ] || [ ! -d "$other" ] || same_path "$other" "$wt" || same_path "$other" "${P_ROOT:-/nonexistent}"; then continue; fi
      lane="$(basename "$other")"
      migrations_changes "$other" "$ref" 2>/dev/null | awk -F'\t' -v l="$lane" '$1 == "A" { print "B\t" $2 "\t" l }'
    done < <(git -C "$wt" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
  } | migrations_match)"
  [ -n "$MIGRATION_COLLISIONS" ] || return 0
  printf 'MIGRATIONS=collision %s.\n' "$(migrations_brief)"
}
