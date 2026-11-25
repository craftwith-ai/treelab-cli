# shellcheck shell=bash
# shellcheck disable=SC2034 # PR_DRAFT et READS_VIEW sont lus par lib/sync.sh et lib/watch.sh
# merge.sh — PR et détection fiable de « branche mergée » (squash, merge-commit, rebase).
# mémo de lab sweep : posé par sweep_memo_open et sweep_gh_prefetch seuls, jamais hérité de l'environnement (revue du lot 01 de sweep-rapide)
LAB_SWEEP_MEMO=""; SWEEP_REFS=""; SWEEP_REFS_ROOT=""; SWEEP_GH_ASKED=""; SWEEP_GH_MERGED=""; SWEEP_GH_ALL_ASKED=""; SWEEP_GH_ALL_MERGED=""
SWEEP_TIPS=""
has_gh() { [ "${LAB_NO_GH:-0}" != 1 ] && command -v gh >/dev/null 2>&1; }
gh_repo_args() { local s; s="$(repo_slug "$1" "${2:-origin}")" && printf -- '-R\n%s\n' "$s"; }
# pr_info_strict <root> <branche> → number<TAB>state<TAB>base<TAB>url (vide si aucune PR) ; rc 1 si gh est absent ou en échec :
# un retrait (lab close --abandon) ne prend jamais une panne pour une absence de PR (revue du lot 02).
pr_info_strict() {
  has_gh || return 1
  if reads_pr "$2"; then   # réponse de la demande groupée du projet (lab status, lab list)
    [ -z "$PR_NUM" ] || printf '%s\t%s\t%s\t%s\n' "$PR_NUM" "$PR_STATE" "$PR_TARGET" "$PR_URL"
    return 0
  fi
  local -a rargs=(); local s
  s="$(repo_slug "$1" "${P_REMOTE:-origin}" 2>/dev/null)" && rargs=(-R "$s")
  # une branche dont la PR a été fermée puis recréée en porte plusieurs : l'ouverte d'abord, puis la fusionnée, puis la fermée,
  # la plus récente de chaque état (gh les rend de la plus récente à la plus ancienne ; sort_by est stable) — lot 14
  with_timeout 20 gh pr list "${rargs[@]+"${rargs[@]}"}" --head "$2" --state all --limit 20 \
    --json number,state,baseRefName,url \
    --jq 'sort_by(if .state == "OPEN" then 0 elif .state == "MERGED" then 1 else 2 end) | .[0] // empty | [.number, .state, .baseRefName, .url] | @tsv' 2>/dev/null
}
# pr_info <root> <branche> : idem, mais vide (rc 0) sans gh ou sur échec — pour les lectures qui ne retirent rien
pr_info() { pr_info_strict "$@" || true; }
# pr_info_set <root> <branche> : PR_NUM, PR_STATE, PR_TARGET, PR_URL — vides sans PR, sans gh ou sur échec — et PR_DRAFT (true ou false
# quand la demande groupée l'a lu, vide sinon) ; sans processus dans une lecture groupée
pr_info_set() {
  local rec
  PR_NUM='' PR_STATE='' PR_TARGET='' PR_URL='' PR_DRAFT=''
  has_gh || return 0
  if reads_pr "$2"; then return 0; fi
  rec="$(pr_info "$1" "$2")"; [ -n "$rec" ] || return 0
  IFS=$'\t' read -r PR_NUM PR_STATE PR_TARGET PR_URL <<<"$rec" || true
}

# ---------- demande groupée d'une lecture (lot 02 de charge-processeur) ----------
# lab status et lab list demandaient GitHub une fois par couloir, jusqu'à 20 s chacune en panne : une seule requête par projet rend la
# PR de chaque branche et l'état des PR que suit un veilleur en échec. READS_GH : vide, aucune demande groupée (chaque lecture demande
# seule, comme toute autre commande) ; asked, réponses lues ; mute, GitHub n'a pas répondu (aucune autre demande). Jamais hérité.
READS_GH='' READS_GH_I=0
RG_B=() RG_PR=() RG_W=() RG_WV=()
# reads_pr <branche> : rc 0 si la demande groupée a répondu pour elle — PR_NUM, PR_STATE, PR_TARGET, PR_URL, PR_DRAFT (vides sans PR, ou
# si GitHub n'a pas répondu) ; rc 1 sans demande groupée
reads_pr() {
  local i="$READS_GH_I" k=0 n
  case "$READS_GH" in mute) PR_NUM='' PR_STATE='' PR_TARGET='' PR_URL='' PR_DRAFT=''; return 0 ;; asked) ;; *) return 1 ;; esac
  n="${#RG_B[@]}"
  while [ "$k" -lt "$n" ]; do
    if [ "${RG_B[$i]}" = "$1" ]; then
      READS_GH_I="$i"; PR_NUM='' PR_STATE='' PR_TARGET='' PR_URL='' PR_DRAFT=''
      IFS=$'\t' read -r PR_NUM PR_STATE PR_TARGET PR_URL PR_DRAFT <<<"${RG_PR[$i]}" || true
      return 0
    fi
    k=$((k + 1)); i=$((i + 1)); [ "$i" -lt "$n" ] || i=0
  done
  return 1
}
# reads_pr_view <n° de PR> : rc 0 si la demande groupée a répondu — READS_VIEW, « état<TAB>révision de tête », vide si elle est muette
reads_pr_view() {
  local i=0
  READS_VIEW=''
  case "$READS_GH" in mute) return 0 ;; asked) ;; *) return 1 ;; esac
  while [ "$i" -lt "${#RG_W[@]}" ]; do
    if [ "${RG_W[$i]}" = "$1" ]; then READS_VIEW="${RG_WV[$i]}"; return 0; fi
    i=$((i + 1))
  done
  return 1
}
# shellcheck disable=SC2016 # requête GraphQL et filtre jq, rien à développer
READS_GH_JQ='.data.repository // {} | to_entries[] | .key as $k
  | if ($k | startswith("b")) then ((.value.nodes // [])
      | sort_by(if .state == "OPEN" then 0 elif .state == "MERGED" then 1 else 2 end) | .[0] // empty
      | [$k, .number, .state, .baseRefName, .url, .isDraft] | @tsv)
    else (.value // empty | [$k, .state, .headRefOid] | @tsv) end'
# reads_gh_load <1 sans aucune branche|0> <branches> <n° de PR> (un par ligne) : la demande. Sans gh, sans dépôt GitHub propriétaire/nom ou sans rien à demander :
# READS_GH reste vide. Muette : une ligne sur stderr. Réponse partielle (une PR inconnue) : gh rend le JSON brut, filtré ici
reads_gh_load() {
  local s b q='' body='' out rc=0 i=0 rest key val; local -a args=()
  READS_GH='' READS_GH_I=0 RG_B=() RG_PR=() RG_W=() RG_WV=()
  has_gh || return 0
  s="$(repo_slug "$P_ROOT" "${P_REMOTE:-origin}" 2>/dev/null)" || return 0
  case "$s" in */*/*|/*|*/) return 0 ;; ?*/?*) ;; *) return 0 ;; esac
  if [ "$1" = 0 ]; then while IFS= read -r b; do
    RG_B[i]="$b"; RG_PR[i]=''
    # branche vide (HEAD détachée) : toutes les PR du dépôt, comme « gh pr list --head "" »
    if [ -n "$b" ]; then q="$q, \$h$i: String!"; args+=(-f "h$i=$b"); b="headRefName: \$h$i, "; fi
    body="$body b$i: pullRequests(${b}first: 20, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { number state baseRefName url isDraft } }"
    i=$((i + 1))
  done <<<"$2"; fi
  i=0
  while IFS= read -r b; do
    case "$b" in ''|*[!0-9]*) continue ;; esac
    RG_W[i]="$b"; RG_WV[i]=''
    q="$q, \$p$i: Int!"; args+=(-F "p$i=$b"); body="$body w$i: pullRequest(number: \$p$i) { state headRefOid }"; i=$((i + 1))
  done <<<"$3"
  [ -n "$body" ] || return 0
  out="$(with_timeout 20 gh api graphql -f query="query(\$o: String!, \$n: String!$q) { repository(owner: \$o, name: \$n) {$body } }" \
    -f "o=${s%%/*}" -f "n=${s#*/}" "${args[@]+"${args[@]}"}" --jq "$READS_GH_JQ" 2>/dev/null)" || rc=$?
  # réponse partielle (une PR de veilleur inconnue) : gh rend 1 et le corps brut ; il compte dès que le dépôt y est un objet
  if [ "$rc" != 0 ] && [ -n "$out" ]; then
    out="$(jq -r 'if (.data.repository | type) == "object" then . else error("no repository") end | '"$READS_GH_JQ" <<<"$out" 2>/dev/null)" && rc=0
  fi
  if [ "$rc" != 0 ]; then
    READS_GH=mute; warn_wrap "GitHub did not answer: pull requests left out of this reading (PR= empty)."
    return 0
  fi
  READS_GH=asked; rest="$out"
  while [ -n "$rest" ]; do
    val="${rest%%$'\n'*}"; case "$rest" in *$'\n'*) rest="${rest#*$'\n'}" ;; *) rest='' ;; esac
    key="${val%%$'\t'*}"; val="${val#*$'\t'}"
    case "$key" in b*) RG_PR[${key#b}]="$val" ;; w*) RG_WV[${key#w}]="$val" ;; esac
  done
}
reads_gh_end() { READS_GH='' RG_B=() RG_PR=() RG_W=() RG_WV=(); }   # les réponses ne survivent jamais à la lecture
pr_merged_via_gh() {
  has_gh || return 1
  local -a rargs=(); local s n
  # réponse groupée du sweep : branche demandée → réponse lue ; branche non demandée ou gh en échec → appel par branche
  if [ -n "${SWEEP_GH_ASKED:-}" ]; then
    case "$SWEEP_GH_MERGED" in *$'\n'"$2"$'\n'*) return 0 ;; esac
    case "$SWEEP_GH_ASKED" in *$'\n'"$2"$'\n'*) return 1 ;; esac
  fi
  s="$(repo_slug "$1" "${P_REMOTE:-origin}" 2>/dev/null)" && rargs=(-R "$s")
  n="$(with_timeout 20 gh pr list "${rargs[@]+"${rargs[@]}"}" --head "$2" --state merged --limit 1 --json number --jq '.[0].number' 2>/dev/null || true)"
  [ -n "$n" ] && [ "$n" != null ]
}
# pr_merged_head <root> <branche> → « numéro<TAB>révision de tête » de la dernière PR fusionnée de la branche ; vide sans gh ou sans
# PR fusionnée (lot 03 de mise-en-ligne : refus d'une seconde PR depuis une branche déjà squashée)
pr_merged_head() {
  has_gh || return 0
  local -a rargs=(); local s
  s="$(repo_slug "$1" "${P_REMOTE:-origin}" 2>/dev/null)" && rargs=(-R "$s")
  with_timeout 20 gh pr list "${rargs[@]+"${rargs[@]}"}" --head "$2" --state merged --limit 1 --json number,headRefOid \
    --jq '.[0] // empty | [.number, .headRefOid] | @tsv' 2>/dev/null || true
}
# branch_start <root> <branche> [start-commit] : commit de départ (meta ou reflog) ; vide si inconnu.
branch_start() {
  if [ -n "${3:-}" ]; then printf '%s\n' "$3"; return; fi
  git -C "$1" reflog show --format=%H "$2" 2>/dev/null | tail -1
}
# branch_has_work <root> <branche> [start] : au moins un commit depuis le départ (sinon rien à merger).
branch_has_work() {
  local start; start="$(branch_start "$1" "$2" "${3:-}")"; [ -n "$start" ] || return 1
  [ "$(git -C "$1" rev-list --count "$start..$2" 2>/dev/null || echo 0)" -gt 0 ]
}
# branch_in_base <root> <branche> <base> [staging] [remote] → 0 si la branche est déjà contenue dans base ou staging
# (distante si elle existe, sinon locale) ; écrit la cible dans BRANCH_IN.
# branch_base_tip <root> <branche> → la révision à chercher dans la base pour un couloir sans travail : le parent de la pointe quand
# celle-ci est le seul commit du gabarit CI posé par lab new (lot 04 de ci-sobre : sujet « chore(ci): lean CI template from lab »,
# seul fichier .github/workflows/ci.yml), sinon la branche elle-même
branch_base_tip() {
  case "$(git -C "$1" log -1 --format=%s "$2" 2>/dev/null)" in
    'chore(ci): lean CI template from lab (lot-'*')')
      if git -C "$1" rev-parse -q --verify "$2^1^{commit}" >/dev/null 2>&1 \
        && [ "$(git -C "$1" diff-tree --no-commit-id --name-only -r "$2" 2>/dev/null)" = .github/workflows/ci.yml ]; then
        printf '%s^1\n' "$2"; return
      fi ;;
  esac
  printf '%s\n' "$2"
}
branch_in_base() {
  local root="$1" br="$2" remote="${5:-${P_REMOTE:-origin}}" t
  BRANCH_IN=""
  for t in "$3" "${4:-}"; do
    [ -n "$t" ] || continue
    if has_remote_branch "$root" "$t" "$remote"; then
      branch_is_ancestor "$root" "$br" "$remote/$t" && { BRANCH_IN="$t"; return 0; }
    elif has_local_branch "$root" "$t"; then
      branch_is_ancestor "$root" "$br" "$t" && { BRANCH_IN="$t"; return 0; }
    fi
  done
  return 1
}
# branch_is_ancestor <root> <branche> <cible> : merge-base --is-ancestor ; sous lab sweep, la pointe de la branche (références
# mémorisées) cherchée dans les commits de la cible, listés une fois par cible et par projet (rev-list). Un nom ambigu (étiquette ou
# référence homonyme) garde l'appel git, qui le résout à sa façon.
branch_is_ancestor() {
  local root="$1" br="$2" ref="$3" l tip
  if [ -n "${LAB_SWEEP_MEMO:-}" ] && sweep_has_ref "$root" "refs/heads/$br" && ! sweep_has_ref "$root" "refs/tags/$br" \
    && ! sweep_has_ref "$root" "refs/$br" && ! sweep_has_ref "$root" "refs/remotes/$br"; then
    tip="${SWEEP_TIPS#*$'\n'"refs/heads/$br "}"; tip="${tip%%$'\n'*}"
    l="$LAB_SWEEP_MEMO/in-${ref//\//_}"
    [ -f "$l" ] || git -C "$root" rev-list "$ref" >"$l" 2>/dev/null || rm -f "$l"
    if [ -f "$l" ] && [ "${#tip}" -ge 40 ]; then grep -Fxq -- "$tip" "$l"; return; fi
  fi
  git -C "$root" merge-base --is-ancestor "$br" "$ref" 2>/dev/null
}
# branch_squashed <root> <branche> <base> [staging] [remote] → 0 si un commit de la base (distante si elle existe) porte exactement
# le diff cumulé de la branche depuis leur ancêtre commun : fusion squash reconnue sans gh (lot 14). Écrit la cible dans BRANCH_IN.
branch_squashed() {
  local root="$1" br="$2" remote="${5:-${P_REMOTE:-origin}}" t ref mb want ids
  BRANCH_IN=""
  for t in "$3" "${4:-}"; do
    [ -n "$t" ] || continue
    if has_remote_branch "$root" "$t" "$remote"; then ref="$remote/$t"; elif has_local_branch "$root" "$t"; then ref="$t"; else continue; fi
    mb="$(git -C "$root" merge-base "$br" "$ref" 2>/dev/null)" || continue
    want="$(git -C "$root" diff "$mb" "$br" | git patch-id --stable | cut -d' ' -f1)"
    [ -n "$want" ] || continue
    if [ -n "${LAB_SWEEP_MEMO:-}" ] && [ "$root" = "$SWEEP_REFS_ROOT" ]; then
      if ids="$(sweep_patch_ids "$root" "$mb" "$ref")" && grep -Fxq -- "$want" <<<"$ids"; then BRANCH_IN="$t"; return 0; fi
      continue
    fi
    if ids="$(git -C "$root" log -p --no-merges --max-count="${LAB_SQUASH_SCAN:-200}" "$mb..$ref" 2>/dev/null | git patch-id --stable | cut -d' ' -f1)" &&
      grep -Fxq -- "$want" <<<"$ids"; then
      BRANCH_IN="$t"; return 0
    fi
  done
  return 1
}
# Mémo de lab sweep (lot 01 de sweep-rapide), le temps d'un projet. LAB_SWEEP_MEMO : dossier mktemp -d, patch-ids « sha empreinte »
# des commits déjà lus (« sha - » sans empreinte), calculés une fois pour tous les couloirs. SWEEP_REFS : les références du dépôt,
# lues une fois (has_remote_branch, has_local_branch). SWEEP_GH_ASKED et SWEEP_GH_MERGED : branches demandées pour ce projet par
# sweep_gh_prefetch et celles qui ont une PR fusionnée ; vides si gh est absent ou en échec (appel par branche).
# Sans mémo, chemin d'origine ; LAB_SWEEP_FAST=0 le force (comparaison de sortie des tests).
sweep_memo_open() { # <root>
  local root="$1" m
  LAB_SWEEP_MEMO=""; SWEEP_REFS=""; SWEEP_REFS_ROOT=""; SWEEP_GH_ASKED=""; SWEEP_GH_MERGED=""; SWEEP_TIPS=""
  [ "${LAB_SWEEP_FAST:-1}" = 1 ] || return 0
  m="$(mktemp -d "${TMPDIR:-/tmp}/lab-sweep.XXXXXX")" || return 0
  LAB_SWEEP_MEMO="$m"; : >"$m/patch-ids"
  SWEEP_REFS="$(git -C "$root" for-each-ref --format='%(refname)' 2>/dev/null)" && SWEEP_REFS=$'\n'"$SWEEP_REFS"$'\n' && SWEEP_REFS_ROOT="$root" \
    || SWEEP_REFS=""
  SWEEP_TIPS=$'\n'"$(git -C "$root" for-each-ref --format='%(refname) %(objectname)' refs/heads 2>/dev/null)"$'\n'
  has_gh && [ -n "$SWEEP_GH_ALL_ASKED" ] || return 0   # réponse de la requête de tous les projets (sweep_gh_prefetch)
  SWEEP_GH_ASKED="$(printf '%s\n' "$SWEEP_GH_ALL_ASKED" | R="$root" awk -F '\t' '$1 == ENVIRON["R"] { print $2 }')"
  [ -n "$SWEEP_GH_ASKED" ] || return 0
  SWEEP_GH_ASKED=$'\n'"$SWEEP_GH_ASKED"$'\n'
  SWEEP_GH_MERGED=$'\n'"$(printf '%s\n' "$SWEEP_GH_ALL_MERGED" | R="$root" awk -F '\t' '$1 == ENVIRON["R"] { print $2 }')"$'\n'
}
# sweep_gh_prefetch <projet…> : une seule requête gh pour les couloirs de tous les projets, branches lues dans les fichiers HEAD des
# worktrees (sans git : une branche manquée retombe sur l'appel par branche). Pose SWEEP_GH_ALL_ASKED
# et SWEEP_GH_ALL_MERGED, lignes « racine<TAB>branche » ; vides si gh échoue.
sweep_gh_prefetch() {
  local p root remote wt g h s q="" body="" rb rq r=0 i=0 i0 map="" out; local -a args=() ra=()
  SWEEP_GH_ALL_ASKED=""; SWEEP_GH_ALL_MERGED=""
  [ "${LAB_SWEEP_FAST:-1}" = 1 ] && has_gh || return 0
  for p in "$@"; do
    root="$( (load_project "$p" && printf '%s\t%s\n' "$P_ROOT" "$P_REMOTE") 2>/dev/null)" || continue
    remote="${root#*$'\t'}"; root="${root%%$'\t'*}"
    s="$(repo_slug "$root" "$remote" 2>/dev/null)" && [ "${s#*/}" != "$s" ] || continue
    rb=""; rq=""; ra=(); i0="$i"
    for wt in "$root"/.worktrees/*/; do
      wt="${wt%/}"; [ -f "$wt/.git" ] || continue
      g="$(sed -n 's/^gitdir: //p' "$wt/.git" 2>/dev/null)"; case "$g" in /*) ;; ?*) g="$wt/$g" ;; *) continue ;; esac
      h=""; read -r h <"$g/HEAD" 2>/dev/null || true
      case "$h" in "ref: refs/heads/"?*) h="${h#ref: refs/heads/}" ;; *) continue ;; esac
      rq="$rq, \$h$i: String!"; ra+=(-f "h$i=$h"); map="$map$root"$'\t'"$h"$'\n'
      rb="$rb b$i: pullRequests(headRefName: \$h$i, states: MERGED, first: 1) { nodes { headRefName } }"; i=$((i + 1))
    done
    [ "$i" -gt "$i0" ] || continue   # dépôt sans couloir : rien à demander (un bloc vide serait refusé)
    body="$body r$r: repository(owner: \$o$r, name: \$n$r) {$rb }"; q="$q, \$o$r: String!, \$n$r: String!$rq"
    args+=(-f "o$r=${s%%/*}" -f "n$r=${s#*/}" "${ra[@]}"); r=$((r + 1))
  done
  [ "$i" -gt 0 ] || return 0
  out="$(with_timeout 60 gh api graphql -f query="query(${q#, }) {$body }" "${args[@]}" \
    --jq '.data[] | to_entries[] | select(.value.nodes | length > 0) | .key | ltrimstr("b")' 2>/dev/null)" || return 0
  SWEEP_GH_ALL_ASKED="$map"
  SWEEP_GH_ALL_MERGED="$(printf '%s' "$map" | KS="$out" awk 'BEGIN { n = split(ENVIRON["KS"], k, "\n"); for (j = 1; j <= n; j++) if (k[j] != "") w[k[j] + 1] = 1 } NR in w')"
}
sweep_has_ref() { # <root> <ref> : rc 0 présente, 1 absente, 2 pas de mémo pour ce dépôt
  [ -n "${SWEEP_REFS:-}" ] && [ "$1" = "$SWEEP_REFS_ROOT" ] || return 2
  case "$SWEEP_REFS" in *$'\n'"$2"$'\n'*) return 0 ;; esac
  return 1
}
sweep_memo_close() {
  SWEEP_REFS=""; SWEEP_REFS_ROOT=""; SWEEP_GH_ASKED=""; SWEEP_GH_MERGED=""; SWEEP_TIPS=""
  [ -n "${LAB_SWEEP_MEMO:-}" ] || return 0
  rm -f "$LAB_SWEEP_MEMO/patch-ids" "$LAB_SWEEP_MEMO"/in-* "$LAB_SWEEP_MEMO"/scan-*; rmdir "$LAB_SWEEP_MEMO" 2>/dev/null || true; LAB_SWEEP_MEMO=""
}
# sweep_patch_ids <root> <ancêtre> <cible> : empreintes des mêmes commits que « git log -p --no-merges --max-count=… <ancêtre>..<cible> » ;
# au premier passage sur une cible, ses derniers commits sont hachés avec les absents du mémo, en un seul git log -p : les couloirs
# partis de commits différents y trouvent les leurs (un git log -p par cible, sauf ancêtre au-delà de cette fenêtre)
sweep_patch_ids() {
  local memo="$LAB_SWEEP_MEMO/patch-ids" n="${LAB_SQUASH_SCAN:-200}" cand top="" miss
  cand="$(git -C "$1" rev-list --no-merges --max-count="$n" "$2..$3" 2>/dev/null)" || return 0
  [ -n "$cand" ] || return 0
  if [ ! -f "$LAB_SWEEP_MEMO/scan-${3//\//_}" ]; then   # un témoin sur disque : appelée dans un tube, la fonction tourne en sous-shell
    top="$(git -C "$1" rev-list --no-merges --max-count="$n" "$3" 2>/dev/null)" || top=""; : >"$LAB_SWEEP_MEMO/scan-${3//\//_}"
  fi
  miss="$(printf '%s\n%s\n' "$cand" "$top" | awk -v m="$memo" 'FILENAME == m { k[$1] = 1; next } NF && !($1 in k) { k[$1] = 1; print }' "$memo" -)"
  if [ -n "$miss" ]; then
    { printf '%s\n' "$miss" | git -C "$1" log -p --no-walk --stdin 2>/dev/null | git patch-id --stable | awk '{ print $2, $1 }'
      printf '%s\n' "$miss" | awk '{ print $1, "-" }'; } >>"$memo"
  fi
  printf '%s\n' "$cand" | awk -v m="$memo" 'FILENAME == m { if ($2 != "-") p[$1] = $2; next } ($1 in p) { print p[$1] }' "$memo" -
}
# merge_regression <wt> <réf> <départ> <nôtre> [commit retiré…] : lignes que la fusion de <nôtre> dans <réf> retirerait alors qu'un
# commit arrivé sur <réf> après le départ du lot (<départ>..<réf>, hors couloir) les avait ajoutées (lot 03 de mise-en-ligne). L'arbre
# comparé est celui de la fusion (git merge-tree : ce que la PR poserait), jamais l'écart brut — un couloir en retard ne retire rien ;
# blame de <réf> sur les seules lignes retirées, un appel par fichier. Un commit retiré déclaré (--retire, SHA complet) est exclu.
# Pose REGRESSION_LIST (« fichier:Lx-y ← sha7 sujet », une par ligne) ; rc 0 aucune, 1 régression, 2 non vérifiable (départ
# inconnu, fusion en conflit ou git < 2.38).
merge_regression() {
  local wt="$1" ref="$2" start="$3" ours="$4" tree foreign r file a b last="" hits=""; shift 4
  local -a L=()
  REGRESSION_LIST=""
  [ -n "$start" ] || return 2
  # l'arbre fusionné de l'essai à blanc qui précède (sync_dry, mêmes révisions), sinon calculé ; un début inconnu fait échouer
  # rev-list comme rev-parse --verify avant (lot 05 de charge-processeur : deux programmes de moins, exec dans les substitutions)
  if [ -n "${SYNC_TREE:-}" ] && [ "${SYNC_TREE_FOR:-}" = "$wt|$ours|$ref" ]; then tree="$SYNC_TREE"
  else tree="$(exec git -C "$wt" merge-tree --write-tree "$ours" "$ref" 2>/dev/null)" || return 2; fi
  SYNC_TREE=""; SYNC_TREE_FOR=""
  tree="${tree%%$'\n'*}"
  foreign="$(exec git -C "$wt" rev-list --no-merges "$start..$ref" 2>/dev/null)" || return 2
  for r in "$@"; do [ -z "$r" ] || foreign="$(printf '%s\n' "$foreign" | grep -vFx -- "$r" || true)"; done
  [ -n "$foreign" ] || return 0
  while IFS=$'\t' read -r file a b; do   # une passe de blame par fichier, sur ses seules plages retirées
    if [ -n "$last" ] && [ "$file" != "$last" ]; then hits="$hits$(blame_foreign "$wt" "$ref" "$last" "$foreign" "${L[@]}")"$'\n'; L=(); fi
    last="$file"; L+=(-L "$a,+$b")
  done < <(git -C "$wt" -c core.quotePath=false diff -U0 -M --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ "$ref" "$tree" 2>/dev/null | awk '
      /^--- a\// { f = substr($0, 7); next }  /^--- / { f = ""; next }
      /^@@ / && f != "" { split($2, h, ","); a = substr(h[1], 2); b = (2 in h) ? h[2] : 1; if (b > 0) printf "%s\t%s\t%s\n", f, a, b }')
  [ -z "$last" ] || hits="$hits$(blame_foreign "$wt" "$ref" "$last" "$foreign" "${L[@]}")"
  REGRESSION_LIST="$(printf '%s\n' "$hits" | sed '/^$/d')"
  [ -z "$REGRESSION_LIST" ] || return 1
}
# blame_foreign <wt> <réf> <fichier> <commits hors couloir> -L … → « fichier:Lx-y ← sha7 sujet » pour chaque suite de lignes
# consécutives venues d'un même commit hors couloir
blame_foreign() {
  local wt="$1" ref="$2" file="$3" foreign="$4" sha first prev line
  shift 4
  first=""; prev=""; sha=""
  while read -r line c; do
    if [ "$c" = "$sha" ] && [ "$line" = "$((prev + 1))" ]; then prev="$line"; continue; fi
    [ -z "$sha" ] || blame_range "$wt" "$file" "$first" "$prev" "$sha"
    sha="$c"; first="$line"; prev="$line"
  done < <(git -C "$wt" blame --porcelain "$@" "$ref" -- "$file" 2>/dev/null | FOREIGN="$foreign" awk '
      BEGIN { n = split(ENVIRON["FOREIGN"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") x[a[i]] = 1 }
      /^[0-9a-f]{40} [0-9]+ [0-9]+/ && ($1 in x) { print $3, $1 }' | sort -k2,2 -k1,1n)
  [ -z "$sha" ] || blame_range "$wt" "$file" "$first" "$prev" "$sha"
}
blame_range() { # <wt> <fichier> <de> <à> <sha>
  local l="L$3"; [ "$3" = "$4" ] || l="$l-$4"
  printf '%s:%s ← %s %s\n' "$2" "$l" "$(git -C "$1" rev-parse --short=7 "$5")" "$(git -C "$1" log -1 --format=%s "$5" 2>/dev/null)"
}
# branch_merged <root> <branche> <base> [staging] [start] → 0 si mergée. Écrit la raison dans MERGED_BY.
branch_merged() {
  local root="$1" br="$2" base="$3" staging="${4:-}" remote="${P_REMOTE:-origin}"
  MERGED_BY=""
  if pr_merged_via_gh "$root" "$br"; then MERGED_BY="pr-merged"; return 0; fi
  # rien à merger depuis un départ connu ET branche déjà contenue dans la base ⇒ mergeable, comme lab next (lot 11).
  # Le containment est exigé : sans lui, un couloir posé sur une branche préexistante (start = son propre tip, donc
  # « 0 commit ») ou un départ devenu inatteignable (rev-list échoue → compté 0) seraient balayés avec leur travail.
  if ! branch_has_work "$root" "$br" "${5:-}"; then
    if [ -n "$(branch_start "$root" "$br" "${5:-}")" ] && branch_in_base "$root" "$(branch_base_tip "$root" "$br")" "$base" "$staging" "$remote"; then
      MERGED_BY="no commit"; return 0
    fi
    MERGED_BY=""; return 1   # départ inconnu, ou branche hors de la base : on ne conclut pas
  fi
  if branch_in_base "$root" "$br" "$base" "$staging" "$remote"; then MERGED_BY="ancestor-of-$BRANCH_IN"; return 0; fi
  # remote supprimée après merge (GitHub) + aucun commit local absent de la base (patch-id)
  if git -C "$root" config "branch.$br.merge" >/dev/null 2>&1 && ! has_remote_branch "$root" "$br" "$remote"; then
    for t in "$base" "$staging"; do
      [ -n "$t" ] || continue
      if has_remote_branch "$root" "$t" "$remote" && [ "$(cherry_count "$root" "$br" "$remote/$t")" = 0 ]; then MERGED_BY="remote-gone+cherry-empty"; return 0; fi
    done
  fi
  # dernier recours, sans gh : un commit de la base porte le diff cumulé de la branche (squash) — lot 14
  if branch_squashed "$root" "$br" "$base" "$staging" "$remote"; then MERGED_BY="squash-in-$BRANCH_IN"; return 0; fi
  export MERGED_BY
  return 1
}
# pr_make_ready <root> <numéro> : filet du lot 13 — une PR restée brouillon passe « prête » avant l'attente des contrôles,
# sinon la CI macOS n'a jamais tourné (job sauté = vert trompeur) et GitHub refuse la fusion. PR_READY=yes|already|unknown.
# Brouillon illisible → avertissement nommé, contrôles lus tels quels ; gh pr ready refusé → arrêt nommé (die).
# L'exécution neuve n'existe pas encore au retour : pr_checks_wait refuse le vert tant qu'un contrôle sauté date du brouillon.
pr_make_ready() {
  local -a rargs=(); local s draft
  PR_READY_RESULT=unknown
  s="$(repo_slug "$1" "${P_REMOTE:-origin}" 2>/dev/null)" && rargs=(-R "$s")
  draft="$(with_timeout 20 gh pr view "${rargs[@]+"${rargs[@]}"}" "$2" --json isDraft --jq .isDraft 2>/dev/null)" || draft=""
  case "$draft" in
    false) PR_READY_RESULT=already; kv PR_READY already; return 0 ;;
    true) ;;
    *) kv PR_READY unknown; warn "PR #$2: draft state unreadable by gh pr view; checks read as they are"; return 0 ;;
  esac
  with_timeout 30 gh pr ready "${rargs[@]+"${rargs[@]}"}" "$2" >/dev/null 2>&1 || {
    kv PR_READY no; die "PR #$2 still a draft: gh pr ready refused; mark it ready, then run again"; }
  PR_READY_RESULT=yes; kv PR_READY yes; printf 'lab: PR #%s marked ready by lab: the full CI starts\n' "$2" >&2
}
# pr_draft_leftovers <slug> <numéro> [<root> <révision>] : contrôles « skipping » ou « cancel » venus d'une exécution créée avant le
# dernier passage « prête » de la PR (événement ready_for_review) — le job coûteux sauté d'un brouillon, que gh pr checks lirait vert
# tant que l'exécution « prête » n'a pas remplacé la sienne, ou l'exécution du brouillon annulée par cancel-in-progress (lot 23).
# Une ligne « genre<TAB>nom<TAB>workflow<TAB>fichier<TAB>bucket » par reste, classé par pr_skip_kinds ; le job sauté par sa propre condition
# (own) n'en est pas un (couloir veilleur-saute). Vide : aucun reste (PR jamais brouillon comprise). rc 1 si gh ne répond pas.
pr_draft_leftovers() { pr_draft_leftovers_set "$@" || return; [ -z "$PR_LEFT" ] || printf '%s\n' "$PR_LEFT"; }
# pr_draft_leftovers_set : la même lecture dans PR_LEFT, sans substitution autour (lot 05 de charge-processeur) — la chronologie lue
# par gh_read, sa dernière date retenue par le shell (sed et tail avant)
pr_draft_leftovers_set() {
  local ready line l name link wf bucket run created pre="" r
  PR_LEFT=''
  gh_read 20 api "repos/$1/issues/$2/timeline" --paginate --jq '.[] | select(.event == "ready_for_review") | .created_at' 2>/dev/null || return 1
  ready=''; while IFS= read -r r; do [ -z "$r" ] || ready="$r"; done <<<"$GH_OUT"
  [ -n "$ready" ] || return 0
  # tous les contrôles, puis awk : un job annulé d'une exécution remplacée (plus récente, même workflow, même événement, PR #125) n'est
  # pas un reste ; ne restent que skipping et cancel
  line="$(with_timeout 30 gh pr checks -R "$1" "$2" --json name,bucket,link,workflow,event --jq '.[] | [.name, .link, .workflow, .bucket, .event] | @tsv' 2>/dev/null)" || return 1
  line="$(printf '%s\n' "$line" | awk -F '\t' '
    { r = $2; sub(/.*\/actions\/runs\//, "", r); sub(/[^0-9].*/, "", r); run[NR] = r + 0; k = $3 SUBSEP $5; if (run[NR] > top[k]) top[k] = run[NR]; l[NR] = $0; b[NR] = $4; key[NR] = k }
    END { for (i = 1; i <= NR; i++) if (b[i] == "skipping" || (b[i] == "cancel" && run[i] >= top[key[i]])) print l[i] }')"
  # cut, pas read : un workflow vide (contrôle externe) ferait glisser les champs, la tabulation étant un blanc pour IFS
  while IFS= read -r l; do
    name="$(printf '%s' "$l" | cut -f1)"; link="$(printf '%s' "$l" | cut -f2)"; wf="$(printf '%s' "$l" | cut -f3)"; bucket="$(printf '%s' "$l" | cut -f4)"
    [ -n "$name" ] || continue
    run="$(printf '%s' "$link" | sed -n 's|.*/actions/runs/\([0-9]*\).*|\1|p')"; [ -n "$run" ] || continue
    created="$(with_timeout 20 gh api "repos/$1/actions/runs/$run" --jq .created_at 2>/dev/null)" || return 1
    [[ "$created" < "$ready" ]] && pre="$pre$name"$'\t'"$wf"$'\t'"$bucket"$'\n'
  done <<<"$line"
  [ -n "$pre" ] || return 0
  PR_LEFT="$(printf '%s' "$pre" | pr_skip_kinds "${3:-}" "${4:-}" | awk -F '\t' '$1 != "own"')"
}
# pr_skip_kinds <root> <révision> : stdin « nom<TAB>workflow<TAB>bucket » des contrôles d'une exécution d'avant le passage « prête » ;
# par contrôle « genre<TAB>nom<TAB>workflow<TAB>fichier<TAB>bucket », genre lu dans les workflows de la révision (git show, sans appel gh) :
#   replaceable : le workflow écoute ready_for_review (types de pull_request ou pull_request_target) — l'exécution « prête » viendra ;
#   own         : workflow sourd, job sauté par sa propre condition, sans garde brouillon — rien à attendre (un needs sauté par sa
#                 garde figure lui-même parmi les contrôles, et rend rouge) ;
#   draft       : workflow sourd, job gardé brouillon (pull_request.draft ou pull_request['draft'] dans son if:, ou dans le job
#                 dont son if: lit la sortie) ou exécution annulée — aucune exécution ne le remplacera ;
#   unread      : révision ou un workflow non lu, pull_request_target (lu sur la cible), contrôle non relié à un seul job (name: à
#                 expression…), if: sur une sortie de job sans garde lue — l'attente est conservée.
# Relier : le workflow par son name: (ou son chemin sans name:), le job par son name: (ou sa clé), « nom (…) » pour une matrice.
pr_skip_kinds() {
  local in out
  in="$(cat)"
  if [ -n "$1" ] && [ -n "$2" ] && git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null && command -v ruby >/dev/null 2>&1; then
    # shellcheck disable=SC2016 # programme ruby littéral
    out="$(printf '%s\n' "$in" | ruby -Ku -ryaml -e '
      root, rev = ARGV
      paths = IO.popen(["git", "-C", root, "ls-tree", "--name-only", rev, "--", ".github/workflows/"], &:read).split("\n").grep(/\.ya?ml\z/)
      wfs = paths.map do |p|
        text = IO.popen(["git", "-C", root, "show", "#{rev}:#{p}"], err: File::NULL, &:read)
        [p, ($?.success? ? (YAML.safe_load(text, aliases: true) rescue nil) : nil)]
      end
      # garde brouillon, en point ou en crochets ; texts : toutes les chaînes d un job (étapes d un job gate comprises)
      GUARD = /pull_request\s*(\.|\[\s*["\x27])\s*draft/
      def texts(o)
        o.is_a?(Hash) ? o.flat_map { |k, v| texts(k) + texts(v) } : o.is_a?(Array) ? o.flat_map { |v| texts(v) } : [o.to_s]
      end
      STDIN.read.split("\n").each do |l|
        name, wf, bucket = l.split("\t", -1)
        next if name.to_s.empty?
        hit = wf.to_s.empty? ? [] : wfs.select { |p, w| w.is_a?(Hash) ? (w["name"] ? w["name"].to_s == wf : p == wf) : false }
        bad = wfs.any? { |p, w| !w.is_a?(Hash) }
        kind, file = "unread", ""
        if hit.size == 1 && !bad
          file, w = hit[0]
          on = w.key?("on") ? w["on"] : w[true]
          on = { on => nil } if on.is_a?(String)
          on = on.to_h { |e| [e, nil] } if on.is_a?(Array)
          on = {} unless on.is_a?(Hash)
          listens = %w[pull_request pull_request_target].any? { |ev| on[ev].is_a?(Hash) && Array(on[ev]["types"]).map(&:to_s).include?("ready_for_review") }
          jobs = w["jobs"].is_a?(Hash) ? w["jobs"] : {}
          names = jobs.map { |id, j| (j.is_a?(Hash) && j["name"] ? j["name"] : id).to_s }
          ids = jobs.keys.zip(names).select { |_, n| !n.include?("${{") && (name == n || name.start_with?("#{n} (")) }.map(&:first)
          # un name: à expression peut produire ce contrôle (même début) : liaison incertaine
          vague = names.any? { |n| n.include?("${{") && name.start_with?(n.split("${{", 2)[0]) }
          job = jobs[ids[0].to_s] if ids.size == 1
          cond = job.is_a?(Hash) ? job["if"].to_s : ""
          # if: sur la sortie d un job (needs.<id>.outputs) : la garde peut être calculée dans ce job
          outs = cond.scan(/needs\.([\w-]+)\.outputs/).flatten.uniq
          kind = if listens then "replaceable"
                 elsif on.key?("pull_request_target") then "unread"   # ses types se lisent sur la cible, pas sur la tête
                 elsif bucket == "cancel" then "draft"
                 elsif !job.is_a?(Hash) || vague then "unread"
                 elsif cond.match?(GUARD) || outs.any? { |o| texts(jobs[o]).any? { |t| t.match?(GUARD) } } then "draft"
                 elsif !outs.empty? || cond.include?("outputs") then "unread"   # condition calculée ailleurs, sans garde lue
                 else "own" end
        end
        puts [kind, name, wf.to_s, file, bucket.to_s].join("\t")
      end' "$1" "$2" 2>/dev/null)" || out=""
    [ -z "$out" ] || { printf '%s\n' "$out"; return 0; }
  fi
  printf '%s\n' "$in" | awk -F '\t' '$1 != "" { printf "unread\t%s\t%s\t\t%s\n", $1, $2, $3 }'
}
# pr_leftovers_read <numéro> <restes> : LEFT_WAIT ← noms des restes à attendre (replaceable, unread) ; rc 0 si un reste ne sera
# jamais remplacé (draft), avertissement qui nomme contrôle, workflow et remède, recopié dans LAB_CHECKS_NOTE (issue du veilleur)
pr_leftovers_read() {
  local deaf
  [ -n "$2" ] || { LEFT_WAIT=''; LEFT_UNREAD=''; return 1; }   # aucun reste : rien à lire, aucun programme (lot 05 de charge-processeur)
  LEFT_WAIT="$(printf '%s\n' "$2" | awk -F '\t' '$1 == "replaceable" || $1 == "unread" { print $2 }')"
  LEFT_UNREAD="$(printf '%s\n' "$2" | awk -F '\t' '$1 == "unread" && $2 !~ /^\(/ { print $2 }' | paste -sd ',' - | sed 's/,/, /g')"
  deaf="$(printf '%s\n' "$2" | awk -F '\t' '$1 == "draft" { printf "%s%s %s, workflow %s (%s)", (n++ ? "; " : ""), $2, ($5 == "cancel" ? "cancelled" : "skipped"), $3, $4 }')"
  [ -n "$deaf" ] || return 1
  deaf="PR #$1: $deaf, before the PR was marked ready; no new run will come (no ready_for_review trigger): add ready_for_review to the pull_request types, or push a commit"
  [ -z "${LAB_CHECKS_NOTE:-}" ] || printf '%s\n' "$deaf" >"$LAB_CHECKS_NOTE" 2>/dev/null || true
  warn "$deaf"
}
# pr_superseded_cancels <slug> <numéro> : liens des jobs annulés d'une exécution remplacée — une exécution plus récente du même
# workflow, pour le même événement, figure parmi les contrôles de la PR (cancel-in-progress de deux exécutions nées ensemble, PR #125
# du couloir anglais). gh pr checks écrit « fail » pour un job annulé : sans ce relevé, l'exécution remplacée se lirait rouge alors
# que la sienne est verte. Une annulation sans exécution plus récente (limite de durée) n'y figure pas. Vide si rien ou gh muet.
pr_superseded_cancels() {
  # shellcheck disable=SC2016 # programme jq littéral
  with_timeout 30 gh pr checks -R "$1" "$2" --json bucket,link,workflow,event --jq '
    [.[] | . + {run: ((.link | (capture("/actions/runs/(?<r>[0-9]+)") // {r: "0"}).r) | tonumber)}] as $c
    | $c[] | select(.bucket == "cancel") | . as $j
    | select(any($c[]; .workflow == $j.workflow and .event == $j.event and .run > $j.run)) | .link' 2>/dev/null || true
}
# pr_checks_drop <liens> : retire du relevé texte de gh pr checks (stdin) les lignes dont le lien (4e colonne) figure dans <liens>
pr_checks_drop() {
  LINKS="$1" awk -F '\t' 'BEGIN { n = split(ENVIRON["LINKS"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") d[a[i]] = 1 } !($4 in d)'
}
# checks_col <relevé> <valeur> [noms exclus, un par ligne] : rc 0 si une ligne du relevé de gh pr checks porte <valeur> en 2e colonne
# (champs séparés par une tabulation, comme awk -F '\t') sous un nom (1re colonne) hors des noms exclus ; checks_all_pass <relevé> :
# rc 0 si chaque ligne porte pass ou skipping — le shell seul, ligne par ligne (lot 05 de charge-processeur : awk et grep avant)
checks_col() {
  local line name rest b x
  while IFS= read -r line; do
    case "$line" in *$'\t'*) name="${line%%$'\t'*}"; rest="${line#*$'\t'}"; b="${rest%%$'\t'*}" ;; *) name="$line"; b='' ;; esac
    [ "$b" = "$2" ] || continue
    if [ -n "${3:-}" ]; then
      while IFS= read -r x; do [ "$x" != "$name" ] || continue 2; done <<<"$3"
    fi
    return 0
  done <<<"$1"
  return 1
}
# checks_all_listed <relevé> : rc 0 si chaque ligne est une ligne de contrôle (nom, tabulation, état) — aucun message de gh mêlé
checks_all_listed() {
  local line
  while IFS= read -r line; do case "$line" in *$'\t'*) ;; *) return 1 ;; esac; done <<<"$1"
}
checks_all_pass() {
  local line rest b
  while IFS= read -r line; do
    case "$line" in *$'\t'*) rest="${line#*$'\t'}"; b="${rest%%$'\t'*}" ;; *) b='' ;; esac
    case "$b" in pass|skipping) ;; *) return 1 ;; esac
  done <<<"$1"
}
# pr_repo_set <root> : PR_REPO, le dépôt GitHub owner/repo du remote de <root> (vide si illisible) — lu une fois par processus et par
# dossier (lot 05 de charge-processeur : un git remote get-url par lecture de PR avant)
pr_repo_set() {
  [ "${PR_REPO_KEY:-}" != "$1|${P_REMOTE:-origin}" ] || return 0
  repo_slug_set "$1" "${P_REMOTE:-origin}" 2>/dev/null || true; PR_REPO="$REPO_SLUG"
  PR_REPO_KEY="$1|${P_REMOTE:-origin}"
}
# pr_workflows_kind<root> <révision> <branche de tête> <branche cible> → pr | none | unreadable : les workflows de la révision de tête
# de la PR et ceux de la cible distante (GitHub exécute pull_request depuis leur fusion, pull_request_target depuis la cible) peuvent-ils
# produire un contrôle sur elle (lot 01 de ci-pr) ? « Un .yml existe » n'est pas « une CI tournera » : schedule, workflow_dispatch,
# push vers main ou vers des tags seuls n'en produisent jamais → aucun. pull_request et
# pull_request_target se comparent à la cible, push à la tête (filtres branches, branches-ignore, négation « ! ») ; merge_group compte ;
# paths et types ignorés (prudence : on attend). Workflow ou motif de branche illisible, révision absente ou ruby introuvable →
# unreadable, signalé : à lire comme pr, l'attente est conservée.
pr_workflows_kind() {
  local root="$1" files="" out r f
  for r in "$2" "refs/remotes/${P_REMOTE:-origin}/$4"; do
    git -C "$root" cat-file -e "$r^{commit}" 2>/dev/null || { warn "revision $r unreadable: workflows not read, counted as pull request CI, wait kept"; echo unreadable; return 0; }
    while IFS= read -r f; do files="$files$r"$'\t'"$f"$'\n'; done < <(git -C "$root" ls-tree --name-only "$r" -- .github/workflows/ 2>/dev/null | grep -E '^\.github/workflows/[^/]+\.ya?ml$' || true)
  done
  [ -n "$files" ] || { echo none; return 0; }
  command -v ruby >/dev/null 2>&1 || { warn "ruby not found: workflows not read, counted as pull request CI, wait kept"; echo unreadable; return 0; }
  # shellcheck disable=SC2016 # programme ruby littéral
  out="$(printf '%s' "$files" | ruby -Ku -ryaml -e '
    root, head, base = ARGV
    # glob de branche GitHub : ** traverse /, * non, ? et + portent sur le caractère précédent ; un motif invalide lève RegexpError,
    # et son fichier devient illisible (une exclusion invalide ne retire jamais tout)
    def covers(pat, ref)
      re = ""; s = pat.to_s; i = 0
      while i < s.length
        c = s[i]
        if c == "*" && s[i + 1] == "*" then re << ".*"; i += 2; next end
        re << case c when "*" then "[^/]*" when "?", "+" then c when "[" then "[" when "]" then "]" when "\\" then (i += 1; Regexp.escape(s[i].to_s)) else Regexp.escape(c) end
        i += 1
      end
      Regexp.new("\\A#{re}\\z").match?(ref)
    end
    def branches(f, ref)
      return true unless f.is_a?(Hash)
      if f.key?("branches")
        Array(f["branches"]).inject(false) { |ok, p| p.to_s.start_with?("!") ? (covers(p.to_s[1..], ref) ? false : ok) : (ok || covers(p, ref)) }
      elsif f.key?("branches-ignore")
        Array(f["branches-ignore"]).none? { |p| covers(p, ref) }
      else
        yield
      end
    end
    STDIN.read.split("\n").each do |line|
      rev, path = line.split("\t", 2)
      text = IO.popen(["git", "-C", root, "show", "#{rev}:#{path}"], &:read)
      w = (YAML.safe_load(text, aliases: true) rescue nil)
      unless $?.success? && w.is_a?(Hash) && (w.key?("on") || w.key?(true)) then puts "unreadable #{File.basename(path)}"; next end
      on = w.key?("on") ? w["on"] : w[true]
      on = { on => nil } if on.is_a?(String)
      on = on.to_h { |e| [e, nil] } if on.is_a?(Array)
      unless on.is_a?(Hash) then puts "unreadable #{File.basename(path)}"; next end
      pr = begin
        on.any? do |ev, f|
          case ev
          when "pull_request", "pull_request_target" then branches(f, base) { true }
          when "push" then branches(f, head) { !(f.key?("tags") || f.key?("tags-ignore")) }
          when "merge_group" then true
          else false
          end
        end
      rescue RegexpError
        puts "unreadable #{File.basename(path)}"; next
      end
      puts "#{pr ? "pr" : "none"} #{File.basename(path)}"
    end' "$root" "$3" "$4" 2>/dev/null)" || out=""
  if grep -q '^pr ' <<<"$out"; then echo pr; return 0; fi
  if [ -z "$out" ] || grep -q '^unreadable ' <<<"$out"; then
    warn "workflow unreadable ($(printf '%s\n' "$out" | sed -n 's/^unreadable //p' | paste -sd ',' - | sed 's/,/, /g;s/^$/read failed/')): counted as pull request CI, wait kept"
    echo unreadable; return 0
  fi
  echo none
}
# pr_ci_none <root> <révision> <tête> <cible> : rc 0 seulement si aucun workflow ne peut produire de contrôle sur la PR
pr_ci_none() { [ "$(pr_workflows_kind "$@")" = none ]; }
# pr_ci_kv : la ligne CI=none, à côté de CHECKS=none, quand aucun workflow de demande de fusion n'existe
pr_ci_kv() { if pr_ci_none "$@" 2>/dev/null; then kv CI "none (no pull request workflow)"; fi; }
# pr_checks_wait <root> <numéro> <révision> <tête> <cible> → green | red | pending | none  (attend jusqu'à LAB_CHECKS_TIMEOUT s, défaut
# 900) ; un contrôle échoué ou annulé → red (lot 23) ; none tout de suite si aucun workflow de demande de fusion (lot 01 de ci-pr)
pr_checks_wait() { pr_checks_wait_set "$@"; printf '%s\n' "$PR_CHECKS"; }
# pr_checks_wait_set : la même attente, son résultat dans PR_CHECKS — sans substitution autour, dans le veilleur (lot 05 de
# charge-processeur)
pr_checks_wait_set() {
  local -a rargs=(); local s out rc kind=""
  PR_CHECKS=
  pr_repo_set "$1"; s="$PR_REPO"; [ -z "$s" ] || rargs=(-R "$s")
  # délai de grâce : les checks CI mettent souvent 10 à 60 s à apparaître après l'ouverture de la PR
  local waited=0 grace="${LAB_CHECKS_GRACE:-90}" poll="${LAB_CHECKS_POLL:-10}" appear
  # attente de l'apparition des contrôles : au rythme du veilleur (LAB_CHECKS_APPEAR_POLL, posé par lui seul), sinon poll
  appear="${LAB_CHECKS_APPEAR_POLL:-$poll}"
  while :; do
    gh_read_all 30 pr checks "${rargs[@]+"${rargs[@]}"}" "$2" && rc=0 || rc=$?; out="$GH_OUT"
    case "$out" in
      *"no checks reported"*|"")
        [ -n "$kind" ] || kind="$(pr_workflows_kind "$1" "$3" "$4" "$5")"
        [ "$kind" != none ] || { PR_CHECKS=none; return 0; }
        ;;
      *) break ;;
    esac
    # délai écoulé sans contrôle : none seulement sans workflow de demande de fusion — jamais une fusion « sans contrôle » (revue du lot 01 de ci-pr)
    [ "$waited" -lt "$grace" ] || { if [ "$kind" = none ]; then PR_CHECKS=none; else PR_CHECKS=pending; fi; return 0; }
    lab_pause "$appear"; waited=$((waited + appear))
  done
  # Vert seulement sans reste de brouillon (lot 13) : un job sauté avant le passage « prête » attend l'exécution neuve, jusqu'à
  # l'échéance commune, puis se lit pending — jamais green. Sans slug lisible, rien à comparer : le vert de gh vaut.
  # gh rend 0 sur un job annulé (limite de durée, lot 23) : une lecture simple tranche — échec, ou annulation hors reste de
  # brouillon → red ; vert seulement sur un relevé non vide de contrôles « pass » ou « skipping », sinon attente puis pending.
  # Les jobs annulés d'une exécution remplacée sont retirés du relevé : --fail-fast rend alors la main trop tôt, l'attente se poursuit.
  local deadline=$((SECONDS + ${LAB_CHECKS_TIMEOUT:-900})) left why sup LEFT_WAIT="" LEFT_UNREAD="" known=0
  # contrôles déjà tous finis et passés à la première lecture (rc 0, aucun message de gh mêlé) : --watch rendrait 0 aussitôt et la
  # relecture le même relevé — dans le veilleur, elle sert de relevé au premier tour (lot 05 de charge-processeur : deux gh de moins)
  if [ -n "$out" ] && [ "$rc" = 0 ] && gh_piped && checks_all_listed "$out"; then known=1; fi
  while :; do
    if [ "$known" = 1 ]; then known=0; rc=0
    else
      rc=0; with_timeout "$((deadline > SECONDS ? deadline - SECONDS : 1))" gh pr checks "${rargs[@]+"${rargs[@]}"}" "$2" --watch --fail-fast >/dev/null 2>&1 || rc=$?
      [ "$rc" != 124 ] || { PR_CHECKS=pending; return 0; }
      gh_read 30 pr checks "${rargs[@]+"${rargs[@]}"}" "$2" 2>/dev/null || true; out="$GH_OUT"
    fi
    sup=""
    if [ -n "$s" ]; then case "$out" in *$'\t'fail*)
      sup="$(pr_superseded_cancels "$s" "$2")"; [ -z "$sup" ] || out="$(printf '%s\n' "$out" | pr_checks_drop "$sup")" ;; esac
    fi
    if [ "$rc" != 0 ]; then
      [ -n "$sup" ] || { PR_CHECKS=red; return 0; }
      case "$out" in *$'\t'fail*) ;; *$'\t'pending*)
        if [ "$SECONDS" -ge "$deadline" ]; then PR_CHECKS=pending; return 0; fi
        lab_pause "$poll"; continue ;;
      esac
    fi
    case "$out" in *$'\t'fail*) PR_CHECKS=red; return 0 ;; esac
    # restes classés par les workflows de la révision (couloir veilleur-saute) : brouillon sans exécution possible → red nommé
    left=""; [ -z "$s" ] || { pr_draft_leftovers_set "$s" "$2" "$1" "${3:-}" && left="$PR_LEFT"; } || left=$'unread\t(checks unreadable by gh)'
    if pr_leftovers_read "$2" "$left"; then PR_CHECKS=red; return 0; fi
    if checks_col "$out" cancel "$LEFT_WAIT"; then PR_CHECKS=red; return 0; fi
    if [ -z "$LEFT_WAIT" ]; then
      if [ -n "$out" ] && checks_all_pass "$out"; then
        PR_CHECKS=green; return 0
      fi
      why="check list empty or a check back in progress"
    else
      why="$(printf '%s' "$LEFT_WAIT" | paste -sd ',' -) skipped or cancelled before the PR was marked ready, no new run yet"
      [ -z "$LEFT_UNREAD" ] || why="$why; not linked to a workflow job (workflow or job unread): $LEFT_UNREAD, wait kept"
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then warn "PR #$2: $why: no pass yet"; PR_CHECKS=pending; return 0; fi
    lab_pause "$poll"
  done
}
# pr_view_state <wt> <numéro> → ÉTAT<TAB>révision de tête (OPEN|MERGED|CLOSED) ; rc ≠ 0 si gh ne répond pas (lot 14)
pr_view_state() { pr_view_set "$1" "$2" || return; [ -z "$PR_VIEW" ] || printf '%s\n' "$PR_VIEW"; }
# pr_view_set <wt> <numéro> : la même lecture dans PR_VIEW, PR_STATE (1re colonne) et PR_HEAD (2e), sans substitution ni découpe — une
# seule lecture GitHub, et dans le veilleur gh seul (lot 05 de charge-processeur)
pr_view_set() {
  local -a rargs=(); local rc=0
  PR_VIEW='' PR_STATE='' PR_HEAD=''
  pr_repo_set "$1"; [ -z "$PR_REPO" ] || rargs=(-R "$PR_REPO")
  gh_read_in "$1" 20 pr view "${rargs[@]+"${rargs[@]}"}" "$2" --json state,headRefOid --jq '[.state, .headRefOid] | @tsv' 2>/dev/null || rc=$?
  PR_VIEW="$GH_OUT"; PR_STATE="${PR_VIEW%%$'\t'*}"; PR_HEAD="${PR_VIEW#*$'\t'}"; PR_HEAD="${PR_HEAD%%$'\t'*}"
  return "$rc"
}
# pr_merge_exact <wt> <numéro> <sha> [méthode] : fusion par l'API à cette révision exacte — GitHub refuse si la tête a bougé (lot 14) ;
# la méthode du projet par défaut, « merge » pour une promotion staging → main (lot 16)
pr_merge_exact() {
  local -a rargs=()
  pr_repo_set "$1"; [ -z "$PR_REPO" ] || rargs=(-R "$PR_REPO")
  gh_read_in "$1" 120 pr merge "${rargs[@]+"${rargs[@]}"}" "$2" "--${4:-${P_MERGE_METHOD:-squash}}" --match-head-commit "$3" >/dev/null 2>&1
}
# pr_checks_now <wt> <numéro> <révision> <tête> <cible> → green | red | pending | none, en une seule lecture, sans attente : lab merge et
# lab close rendent la main (lot 14). Juste après un passage « prête » (PR_READY_RESULT=oui), l'exécution neuve n'existe pas encore :
# pending, jamais green. Aucun contrôle : none seulement si aucun workflow de demande de fusion (lot 01 de ci-pr), sinon pending.
pr_checks_now() {
  local -a rargs=(); local s out rc=0 left LEFT_WAIT="" LEFT_UNREAD=""
  pr_repo_set "$1"; s="$PR_REPO"; [ -z "$s" ] || rargs=(-R "$s")
  gh_read_all 30 pr checks "${rargs[@]+"${rargs[@]}"}" "$2" || rc=$?; out="$GH_OUT"
  case "$out" in
    *"no checks reported"*|"")
      if pr_ci_none "$1" "$3" "$4" "$5"; then echo none; else echo pending; fi; return 0 ;;
  esac
  # jobs annulés d'une exécution remplacée : hors relevé ; le rc de gh venait de leur « fail », il ne vaut plus que pour un job en cours
  if [ -n "$s" ]; then case "$out" in *$'\t'fail*)
    left="$(pr_superseded_cancels "$s" "$2")"
    if [ -n "$left" ]; then
      out="$(printf '%s\n' "$out" | pr_checks_drop "$left")"; case "$out" in *$'\t'pending*) ;; *) rc=0 ;; esac
    fi ;; esac
  fi
  case "$out" in *$'\t'fail*) echo red; return 0 ;; esac
  # restes de brouillon lus avant la règle cancel, comme pr_checks_wait (lot-03 livrer-sans-friction) : l'exécution du brouillon
  # annulée par cancel-in-progress attend l'exécution neuve → pending ; une annulation hors reste (limite de durée) reste rouge
  # lus seulement s'ils décident : une annulation à juger, ou un vert à confirmer (gh en panne → pending sans attente de plus)
  left=""
  case "$out" in *$'\t'cancel*)
    [ -z "$s" ] || { pr_draft_leftovers_set "$s" "$2" "$1" "$3" && left="$PR_LEFT"; } || left=$'unread\t(checks unreadable by gh)'
    if pr_leftovers_read "$2" "$left"; then echo red; return 0; fi
    if checks_col "$out" cancel "$LEFT_WAIT"; then echo red; return 0; fi
    echo pending; return 0 ;;
  esac
  if [ "$rc" != 0 ] || [ "${PR_READY_RESULT:-}" = yes ]; then echo pending; return 0; fi
  if [ -n "$s" ]; then
    { pr_draft_leftovers_set "$s" "$2" "$1" "$3" && left="$PR_LEFT"; } || left=$'unread\t(checks unreadable by gh)'
    if pr_leftovers_read "$2" "$left"; then echo red; return 0; fi
    [ -z "$LEFT_WAIT" ] || { echo pending; return 0; }
  fi
  echo green
}
