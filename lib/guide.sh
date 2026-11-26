# shellcheck shell=bash
# guide.sh — le premier couloir guidé (lot 07 de refonte-onboarding). lab new --guided marque le couloir (guide=first dans .lab/meta) ;
# lab guide lit, sans rien écrire, l'étape du couloir (1 à 4) et l'état de GitHub, avec une phrase simple et le remède.
# stdout = KEY=value ; le texte part sur stderr, replié au mot par onboard_wrap à la largeur d'onboard_cols (40 à 80 colonnes).

GUIDE_STEPS=4
GUIDE_GH_TIMEOUT="${LAB_GUIDE_GH_TIMEOUT:-5}"   # gh auth status passe par le réseau : délai borné, jamais de blocage

# lane_guided <wt> : couloir créé par lab new --guided
lane_guided() { [ "$(wt_meta "$1" guide)" = first ]; }
# guide_prompt_note : la phrase ajoutée aux sessions d'exécution et de recette d'un couloir guidé ($P_NAME, $SLUG)
guide_prompt_note() {
  printf '%s' "Guided first lane: keep applying the first-lane skill, in plain words, with the step line of lab guide $P_NAME $SLUG at each step."
}

# guide_step <wt> → 1 questions (fiche sans objectif ni critère), 2 plan (fiche planifiée), 3 travail (lot en cours),
# 4 relecture (lot clos ou en attente : pull request ouverte, recette). Calculé depuis la fiche courante, à chaque lecture.
guide_step() {
  local lot; lot="$(wt_lot_file "$1")"
  if [ -z "$lot" ] || [ ! -f "$lot" ] || ! lot_framed "$lot" 2>/dev/null; then printf '1\n'; return; fi
  case "$(lot_state "$lot")" in
    'in progress'*) printf '3\n' ;;
    closed*|waiting*) printf '4\n' ;;
    *) printf '2\n' ;;
  esac
}
guide_step_name() { case "$1" in 1) echo questions ;; 2) echo plan ;; 3) echo work ;; 4) echo review ;; esac; }
guide_step_label() {
  case "$1" in
    1) echo 'Questions about your need' ;; 2) echo 'The plan' ;; 3) echo 'The work, checked by tests' ;; 4) echo 'Your review (pull request)' ;;
  esac
}
guide_step_next() {
  case "$1" in
    1) echo 'Next: the agent asks you a few questions about your need, five at most.' ;;
    2) echo 'Next: the agent shows you the plan in plain words, then starts the work in the same session.' ;;
    3) echo 'Next: the agent does the work and checks it with tests, then proposes it to you as a pull request.' ;;
    4) echo 'Next: you try the result. If it suits you, say so: the agent delivers it.' ;;
  esac
}

# guide_url_host <url> → l'hôte d'une URL de dépôt (https://, ssh://, git://, user@hôte:chemin) ; vide pour un dossier local.
# L'hôte d'une URL ssh peut être un alias de ~/.ssh/config, avec ou sans point (github-perso, github.com-work) : toujours résolu
# par ssh -G, lu sans connexion (revue du lot 07).
guide_url_host() {
  local u="$1" h ssh=0
  case "$u" in
    ''|/*|./*|../*|file://*) return 0 ;;
    ssh://*|git+ssh://*|ssh+git://*) ssh=1; h="${u#*://}"; h="${h%%/*}"; h="${h##*@}"; h="${h%%:*}" ;;
    *://*) h="${u#*://}"; h="${h%%/*}"; h="${h##*@}"; h="${h%%:*}" ;;
    *:*) ssh=1; h="${u%%:*}"; h="${h##*@}" ;;
    *) return 0 ;;
  esac
  if [ "$ssh" = 1 ] && [ -n "$h" ] && command -v ssh >/dev/null 2>&1; then
    # -F : la configuration du HOME courant, sinon aucune (ssh lirait celle du compte, même sous un autre HOME)
    local r cfg=/dev/null; [ ! -f "$HOME/.ssh/config" ] || cfg="$HOME/.ssh/config"
    r="$(with_timeout 2 ssh -F "$cfg" -G "$h" 2>/dev/null </dev/null | awk '$1 == "hostname" { print $2; exit }' || true)"; [ -z "$r" ] || h="$r"
  fi
  printf '%s\n' "$h" | tr '[:upper:]' '[:lower:]'
}
# guide_word <mot> → le mot tel quel s'il est sûr pour le shell, sinon cité : lab init sans nom prend celui du dossier, libre
guide_word() { case "$1" in ''|*[!A-Za-z0-9._-]*) shell_quote "$1" ;; *) printf '%s' "$1" ;; esac; }

# guide_github <racine> : pose GUIDE_GH (ready | gh-missing | gh-logged-out | no-remote | other-host | unknown), GUIDE_GH_HOST,
# GUIDE_GH_REPO. Ordre : un distant hors GitHub d'abord (gh n'y peut rien), puis gh absent, gh non connecté (délai borné : unknown
# au-delà), dépôt sans distant, prêt. L'URL lue est celle écrite dans la configuration, avant toute réécriture insteadOf.
guide_github() {
  local root="$1" remote url rc=0
  GUIDE_GH=""; GUIDE_GH_HOST=""; GUIDE_GH_REPO=""
  remote="$(remote_name "$root" || true)"
  if [ -n "$remote" ]; then
    url="$(git -C "$root" config --get "remote.$remote.url" 2>/dev/null || true)"
    GUIDE_GH_HOST="$(guide_url_host "$url")"
    if [ "$GUIDE_GH_HOST" != github.com ]; then
      # un raccourci insteadOf (gh:…) peut mener à GitHub : l'URL réécrite par git décide alors (revue du lot 07)
      local rew; rew="$(git -C "$root" remote get-url "$remote" 2>/dev/null || true)"
      if [ -n "$rew" ] && [ "$rew" != "$url" ] && [ "$(guide_url_host "$rew")" = github.com ]; then url="$rew"; GUIDE_GH_HOST=github.com
      else GUIDE_GH=other-host; return 0; fi
    fi
    GUIDE_GH_REPO="$(guide_repo_of "$url")"
  fi
  if ! has_gh; then GUIDE_GH=gh-missing; return 0; fi
  # le compte actif seul : un autre compte du trousseau au jeton périmé fait rendre 1 à « gh auth status » (lib/cloud.sh) ;
  # un gh trop ancien pour --active est relu sans lui
  (cd "$root" && with_timeout "$GUIDE_GH_TIMEOUT" gh auth status --active --hostname github.com) >/dev/null 2>&1 || rc=$?
  if [ "$rc" != 0 ] && [ "$rc" != 124 ]; then
    rc=0; (cd "$root" && with_timeout "$GUIDE_GH_TIMEOUT" gh auth status --hostname github.com) >/dev/null 2>&1 || rc=$?
  fi
  case "$rc" in 0) ;; 124) GUIDE_GH=unknown; return 0 ;; *) GUIDE_GH=gh-logged-out; return 0 ;; esac
  if [ -z "$remote" ]; then GUIDE_GH=no-remote; return 0; fi
  GUIDE_GH=ready
}
# guide_repo_of <url GitHub> → propriétaire/dépôt
guide_repo_of() {
  local u="${1%.git}"; u="${u%/}"
  case "$u" in *://*) u="${u#*://}"; u="${u#*/}" ;; *:*) u="${u#*:}" ;; esac
  printf '%s\n' "$u"
}
# guide_github_fix <racine> → la commande qui répare l'état GUIDE_GH, vide quand il n'y en a pas
guide_github_fix() {
  case "$GUIDE_GH" in
    gh-missing) printf 'brew install gh\n' ;;
    gh-logged-out) printf 'gh auth login\n' ;;
    no-remote) printf 'gh repo create %s --private --source %s --remote origin --push\n' "$(guide_word "$P_NAME")" "$(shell_quote "$1")" ;;
  esac
}
# guide_github_text → la phrase simple et le remède, pour un lecteur qui ne connaît ni git ni GitHub ; la commande y vise le dossier
# du projet (« . ») : un chemin entier, d'un seul mot, déborderait de 40 colonnes — GITHUB_FIX= le porte en entier
guide_github_text() {
  case "$GUIDE_GH" in
    ready) printf 'GitHub: ready. Your work will be proposed on GitHub, in %s, as a pull request: a page that shows every change before you accept it.\n' "${GUIDE_GH_REPO:-your repository}" ;;
    gh-missing) printf '%s\n' "GitHub: gh, GitHub's command-line tool, is not installed. The agent needs it to put your project on GitHub and propose the work there. To install it, then sign in:" '  brew install gh' '  gh auth login' ;;
    gh-logged-out) printf '%s\n' "GitHub: gh, GitHub's command-line tool, is not signed in to your GitHub account. To sign in (it opens your browser):" '  gh auth login' ;;
    no-remote) printf '%s\n' 'GitHub: this project is not on GitHub yet, so there is no place to propose the work. With your agreement, the agent creates a private repository, visible to you only, from the project folder:' "  gh repo create $(guide_word "$P_NAME") --private --source . --remote origin --push" ;;
    other-host)
      if [ -z "$GUIDE_GH_HOST" ]; then printf 'GitHub: this project sends its work to a folder of this Mac, not to GitHub. Treelab proposes the work as a pull request on GitHub only: here, the work stays ready on its branch.\n'
      else printf 'GitHub: this project is hosted on %s, not on GitHub. Treelab proposes the work as a pull request on GitHub only: here, the work stays ready on its branch, and you propose it yourself on %s.\n' "$GUIDE_GH_HOST" "$GUIDE_GH_HOST"; fi ;;
    unknown) printf '%s\n' "GitHub: gh, GitHub's command-line tool, did not answer within $GUIDE_GH_TIMEOUT seconds, maybe because of the network: your account could not be checked. Nothing is blocked; in a moment, run again:" "  lab guide $(guide_word "$P_NAME") $(guide_word "$SLUG")" ;;
  esac
}

# guide_show [--no-lane] : l'étape et GitHub du couloir $WT — KEY=value sur stdout, le texte replié sur stderr ; rien n'est écrit.
# --no-lane : appelé par lab new --guided, qui a déjà donné LANE=
guide_show() {
  local step n mark fix width
  step="$(guide_step "$WT")"; guide_github "$P_ROOT"; fix="$(guide_github_fix "$P_ROOT")"
  [ "${1:-}" = --no-lane ] || kv LANE "$SLUG"
  kv GUIDE_STEP "$step/$GUIDE_STEPS"; kv GUIDE_STEP_NAME "$(guide_step_name "$step")"; kv GITHUB "$GUIDE_GH"
  [ -z "$fix" ] || kv GITHUB_FIX "$fix"
  [ -z "$GUIDE_GH_REPO" ] || [ "$GUIDE_GH" != ready ] || kv GITHUB_REPO "$GUIDE_GH_REPO"
  width="$(onboard_cols)"
  {
    if lane_guided "$WT"; then printf 'Your first lane: %s\n' "$SLUG"; else printf 'Lane: %s\n' "$SLUG"; fi
    n=1
    while [ "$n" -le "$GUIDE_STEPS" ]; do
      # l'étape en cours porte aussi un mot : un symbole seul se lit « black circle » à voix haute
      if [ "$n" -lt "$step" ]; then mark='✓'; elif [ "$n" = "$step" ]; then mark='●'; else mark='○'; fi
      printf '  %s %s %s%s\n' "$mark" "$n" "$(guide_step_label "$n")" "$([ "$n" != "$step" ] || printf ' (now)')"
      n=$((n + 1))
    done
    guide_step_next "$step"
    printf '\n'
    guide_github_text
  } | onboard_wrap "$width" >&2
}
