# shellcheck shell=bash
# tests_guard.sh — un lot n'affaiblit pas ses tests en silence : on compte, dans le diff
# du lot limité aux fichiers de test, les lignes d'assertion retirées et ajoutées et les skips ajoutés. Motifs ERE (awk), une ligne
# compte une fois ; chacun se remplace par tests_files=, tests_assert= ou tests_skip= dans la config du projet.
TESTS_FILES_RE='(^|/)(tests?|spec|__tests__)/|\.bats$|_test\.[^/]+$|\.(test|spec)\.[^/]+$|(^|/)test_[^/]*\.py$'
TESTS_ASSERT_RE='^[[:space:]]*\[\[?[[:space:]]|(^|[^[:alnum:]_])(contains|lacks|not)[[:space:]]|assert|expect\(|t\.(Error|Fatal)|require\.'
TESTS_SKIP_RE='^[[:space:]]*skip([[:space:]]|$)|\.skip\(|(^|[^[:alnum:]_.])x(it|describe|test)\(|pytest\.mark\.skip|pytest\.skip\(|unittest\.skip|t\.Skip|@Disabled|@Ignore'
# tests_lot_base <root> → départ du lot : start= de .lab/meta, remplacé par merge-base HEAD <remote>/<base> quand celui-ci le
# contient (la base a été fusionnée dans le couloir depuis : ses tests ne sont pas ceux du lot). Lot empilé : start= reste.
tests_lot_base() {
  local root="$1" start base remote mb=''
  start="$(wt_meta "$root" start)"; base="$(wt_meta "$root" base)"; remote="$(remote_name "$root")"
  git -C "$root" rev-parse --verify --quiet "${start:-x}^{commit}" >/dev/null || start=''
  [ -z "$base" ] || [ -z "$remote" ] || mb="$(git -C "$root" merge-base HEAD "$remote/$base" 2>/dev/null || true)"
  if [ -n "$start" ] && { [ -z "$mb" ] || ! git -C "$root" merge-base --is-ancestor "$start" "$mb" 2>/dev/null; }; then mb="$start"; fi
  printf '%s\n' "$mb"
}
# tests_weakened <root> <base> [fichiers] [assertions] [skips] → TESTS_ASSERT_ADDED=, TESTS_ASSERT_REMOVED=, TESTS_SKIP_ADDED=
# Un seul diff -M de tout l'arbre, filtré par fichier dans awk : limité par chemins, git ne verrait plus un renommage.
# Skips en solde, comme les assertions : un skip réindenté ou déplacé n'est pas un skip ajouté.
tests_weakened() {
  local files_re="${3:-$TESTS_FILES_RE}" assert_re="${4:-$TESTS_ASSERT_RE}" skip_re="${5:-$TESTS_SKIP_RE}"
  git -C "$1" diff -U0 -M --no-color --no-ext-diff "$2"..HEAD | TG_F="$files_re" TG_A="$assert_re" TG_S="$skip_re" LC_ALL=C awk '
    BEGIN { f = ENVIRON["TG_F"]; a = ENVIRON["TG_A"]; s = ENVIRON["TG_S"] }   # jamais awk -v : il mange les barres obliques inverses
    /^diff --git / { p = $0; sub(/^diff --git a\/.* b\//, "", p); test = (p ~ f); hunk = 0; next }
    /^@@/ { hunk = test; next }
    !hunk { next }
    /^\+/ { l = substr($0, 2); if (l ~ a) add++; if (l ~ s) skip++; next }
    /^-/ { l = substr($0, 2); if (l ~ a) del++; if (l ~ s) unskip++ }
    END { skip -= unskip; if (skip < 0) skip = 0
      printf "TESTS_ASSERT_ADDED=%d\nTESTS_ASSERT_REMOVED=%d\nTESTS_SKIP_ADDED=%d\n", add, del, skip }'
}
# tests_reason <fiche> → motif de « Tests retirés : <motif> » en début de ligne (puce et gras tolérés), vide sinon
tests_reason() {
  [ -f "${1:-}" ] || return 0
  lang_norm <"$1" | sed -n 's/^[[:space:]]*[-*+]*[[:space:]]*\**Tests retirés\**[[:space:]]*:\**[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' | head -1
}
