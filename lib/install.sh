# shellcheck shell=bash
# install.sh — transactions locales, bash 3.2. Charger project.sh et git.sh avant usage.
# Aucun effet au chargement. API (stdout vide, diagnostics stderr) :
# Avec set -E (héritage de ERR) : txn_begin ; record_op <action> <cible> [arguments…] ; txn_commit | txn_rollback
# uninstall_replay : processus neuf, même LAB_STATE et même liste de callbacks.
# mkdir cible (parents inclus), symlink cible texte, create/replace/modify cible source,
# skip cible motif, cmd cible fonction inverse [arguments…]. Les callbacks reçoivent
# cible puis arguments distincts. LAB_TXN_COMMANDS=("fonction:inverse" …), définie par
# l'appelant, autorise uniquement des fonctions locales ; tous leurs effets doivent
# être contenus dans la cible déclarée. L'inverse sait traiter un effet partiel.
#
# TSV v1 : en-tête « treelab-install<TAB>1 », puis une ligne par opération :
# @transaction @séquence @action @cible @empreinte-avant @empreinte-après @fonction
# @inverse @argument… (tabulations entre colonnes). @ préserve les valeurs vides.
# Une empreinte est SHA-256, « absent », « none » (skip), ou « pending » avant effet.
# Sauvegarde : backups/<transaction>/<séquence>/before ; row = ligne préparée,
# after = empreinte obtenue ; done = inverse réussi. Les objets sauvegardés gardent
# leurs modes ; les métadonnées sont 0600 dans des dossiers 0700.
# sealed-count fixe le nombre de lignes validées ; manifest-state et manifest.before
# gardent le manifeste antérieur jusqu’à la fin du retour de txn_commit.
# Le manifeste est publié par renommage atomique. Un dossier non référencé dans
# celui-ci est une transaction incomplète, jamais réutilisée par txn_begin.
# txn_rollback peut la reprendre depuis un shell neuf. Les sauvegardes validées et
# marqueurs done restent sur disque : leur rétention relève de la future CLI.
# Pas de concurrence, SIGKILL, ACL/xattrs ni restauration des dates des dossiers.
# Les traps temporaires traitent ERR/EXIT/INT/TERM ; les retours des mutations sont
# également vérifiés si l'appelant neutralise errexit par une condition.

# lab_say <texte> : « lab: texte » sur stderr, replié au mot à la largeur du terminal (onboard_wrap, 40 à 80 colonnes) quand
# lib/onboard.sh est chargé et que stderr est un terminal ou COLUMNS est posé — setup, update et uninstall lisibles à 40 colonnes
# (lot 05 du couloir anglais) ; sinon intacte, car update_auto relit la première ligne de l'erreur.
lab_say() {
  if { [ -t 2 ] || [ -n "${COLUMNS:-}" ]; } && declare -F onboard_wrap >/dev/null; then printf 'lab: %s\n' "$*" | onboard_wrap "$(onboard_cols)" >&2
  else printf 'lab: %s\n' "$*" >&2; fi
}
_txn_message() { lab_say "$*"; }
_txn_field() { case "$1" in *$'\t'*|*$'\r'*|*$'\n'*) return 1 ;; esac; }
_txn_readlink() { # -n et sentinelle : aucun LF ajouté, aucun octet terminal perdu.
  local value
  value="$(command readlink -n "$1"; local rc=$?; printf '.'; exit "$rc")" || return
  LAB_TXN_LINK="${value%.}"
  _txn_field "$LAB_TXN_LINK"
}
_txn_exists() { [ -e "$1" ] || [ -L "$1" ]; }
_txn_plain_path() { # Refus de lien dans TOUS les composants techniques.
  local p="$1"
  case "$p" in /*) ;; *) return 1 ;; esac
  # validation groupée : le dossier des sauvegardes, vérifié en tête, et les deux derniers chemins vérifiés ne sont pas reparcourus, ni
  # aucun de leurs dossiers — chacun de leurs composants l'a été. Deux : chaque ligne vérifie son dossier de sauvegarde puis le parent de
  # sa cible, deux arbres en alternance (lot 03 de charge-processeur : 40 % des commandes de la validation)
  if [ -n "${LAB_TXN_PLAIN_OK:-}" ]; then
    [ "$p" != "${LAB_TXN_PLAIN_LAST:-}" ] || return 0
    if [ "$p" != "${LAB_TXN_PLAIN_PREV:-}" ]; then
      while [ "$p" != / ]; do
        [ "$p" != "$LAB_TXN_PLAIN_OK" ] || break
        case "${LAB_TXN_PLAIN_LAST:-}/" in "$p"/*) break ;; esac
        case "${LAB_TXN_PLAIN_PREV:-}/" in "$p"/*) break ;; esac
        [ ! -L "$p" ] || return 1
        p="${p%/*}"; p="${p:-/}"
      done
    fi
    LAB_TXN_PLAIN_PREV="${LAB_TXN_PLAIN_LAST:-}"; LAB_TXN_PLAIN_LAST="$1"; return 0
  fi
  while [ "$p" != / ]; do
    [ ! -L "$p" ] || return 1
    p="${p%/*}"; p="${p:-/}"
  done
}
_txn_paths() {
  if ! { [ -n "${LAB_STATE:-}" ] && _txn_field "$LAB_STATE" && _txn_plain_path "$LAB_STATE"; }; then
    _txn_message "Invalid or linked state: ${LAB_STATE:-none}. Choose a real folder for the backups."; return 1;
  fi
  case "$LAB_STATE/" in *'/../'*|*'/./'*|*'//'*)
    _txn_message "State path not normalised: $LAB_STATE. Use an absolute path without dots or double separators."; return 1 ;;
  esac
  LAB_TXN_MANIFEST="$LAB_STATE/install-manifest.tsv"
  LAB_TXN_BACKUPS="$LAB_STATE/backups"
  if ! { _txn_plain_path "$LAB_TXN_MANIFEST" && _txn_plain_path "$LAB_TXN_BACKUPS"; }; then
    _txn_message "Log or backups are linked: $LAB_STATE. Restore their real location before resuming."; return 1;
  fi
}
_txn_private_file() { (umask 077; : >"$1") && chmod 600 "$1"; }
_txn_write() { # Publication technique atomique ; données seulement.
  local dest="$1"; shift
  _txn_plain_path "$dest" && _txn_plain_path "$dest.tmp" || return 1
  _txn_private_file "$dest.tmp" && printf '%s\n' "$*" >"$dest.tmp" && mv -f "$dest.tmp" "$dest"
}
_txn_row() {
  local field sep=''
  for field in "$@"; do printf '%s@%s' "$sep" "$field" || return; sep=$'\t'; done
  printf '\n'
}
_txn_parse() { # Tableau local à l'appelant, valeurs @ non vides avant découpage.
  # Chaque champ commence par @ : aucun champ vide, le découpage par tabulation est exact (lot 03 de charge-processeur : une
  # expansion au lieu d'une boucle par champ, quatre passes sur l'historique par doctor).
  local line="$1" IFS=$'\t' glob=''
  LAB_TXN_FIELDS=()
  case "$line" in @*) ;; *) return 1 ;; esac
  case "$line" in *$'\t'|*$'\t'[!@]*) return 1 ;; esac
  case "$-" in *f*) ;; *) glob=1; set -f ;; esac
  # shellcheck disable=SC2206 # découpage voulu, sur la seule tabulation, sans motif
  LAB_TXN_FIELDS=($line)
  [ -z "$glob" ] || set +f
  # IFS par défaut avant "${t[@]#@}" : sous bash 3.2, un IFS sans espace y recolle les éléments en un seul mot
  IFS=$' \t\n'
  LAB_TXN_FIELDS=("${LAB_TXN_FIELDS[@]#@}")
  [ "${#LAB_TXN_FIELDS[@]}" -ge 8 ]
}
# TXN_FACTS_PL (lot 03 de charge-processeur) : les faits de l'historique lus par un seul perl — un programme par empreinte, mode ou
# fichier coûtait six programmes par ligne du manifeste. Les règles restent en bash ; ce programme ne fait que lire.
#   fp <chemin> : l'empreinte d'une arborescence, sans lien suivi — SHA-256 des lignes triées en octets « chemin relatif, mode %Lp
#     de stat (mode & 0777), L cible | F date shasum-de-son-contenu | D », « absent », ou « ! » (nom ou cible à tabulation ou fin de
#     ligne, type spécial, illisible) ; à l'octet celle de l'ancien parcours stat, shasum et sort (preuves du lot 03)
#   rows <manifeste> <sauvegardes> <0|1> : « mode<TAB>dernier octet » du manifeste (- s'il est vide), puis une ligne par ligne du
#     manifeste — « - », ou « d<TAB>mode row<TAB>after<TAB>done<TAB>types<TAB>empreinte before<TAB>mode retirement<TAB>state<TAB>
#     empreinte retirement/before<TAB>retirement/after » (- : non demandé ; ! : illisible), empreintes avec 1 seulement ; types :
#     row, after, done en trois lettres d'après lstat — a absent ou illisible, l lien, f fichier, o autre
#   committed <manifeste> <id…> : chaque id dont « @id<TAB> » paraît dans le manifeste, un par ligne (grep -F de _txn_committed)
# shellcheck disable=SC2016 # programme perl littéral
TXN_FACTS_PL='
use strict; use Digest::SHA; use filetest "access";
my $cmd = shift @ARGV;
sub plain { $_[0] !~ /[\t\r\n]/ }
sub tree {
  my ($p, $root, $out) = @_;
  return 0 unless plain($p);
  my @st = lstat($p) or return 0;
  my $line = substr($p, length($root)) . "\t" . sprintf("%o", $st[2] & 0777) . "\t";
  if (-l _) { my $l = readlink($p); return 0 unless defined $l && plain($l); push @$out, $line . "L\t$l"; }
  elsif (-f _) {
    open(my $fh, "<:raw", $p) or return 0; my $sha = Digest::SHA->new(256); eval { $sha->addfile($fh); 1 } or return 0; close $fh;
    push @$out, $line . "F\t$st[9]\t" . $sha->hexdigest . "  -";
  } elsif (-d _) {
    return 0 unless -r $p && -x $p;
    push @$out, $line . "D";
    opendir(my $dh, $p) or return 0; my @k = grep { $_ ne "." && $_ ne ".." } readdir($dh); closedir $dh;
    for my $c (@k) { tree("$p/$c", $root, $out) or return 0; }
  } else { return 0 }
  return 1;
}
sub fp { my $p = shift; return "absent" unless -e $p || -l $p; my @l; tree($p, $p, \@l) or return "!"; Digest::SHA::sha256_hex(join("\n", sort @l) . "\n") }
sub lp { my @s = lstat($_[0]); @s ? sprintf("%o", $s[2] & 0777) : "!" }
sub ty { join "", map { my @s = lstat("$_[0]/$_"); !@s ? "a" : -l _ ? "l" : -f _ ? "f" : "o" } qw(row after done) }
sub ex { -e $_[0] || -l $_[0] }
# contenu comme bash le lit (read -d "" : jusqu au premier NUL), fins de ligne finales retirées
sub slurp { open(my $fh, "<:raw", $_[0]) or return ""; local $/; my $c = <$fh>; close $fh; $c = "" unless defined $c; $c =~ tr/\0//d; $c =~ s/\n+\z//; $c }
# métadonnées d une ligne validée, celles du doctor : ok, removal (retrait en cours) ou fail
sub meta_row {
  my ($line, $f, $d, $bk) = @_;
  return "removal" if ex("$d/done") || ex("$d/retirement") || ex("$bk/" . substr($f->[0], 1) . "/remove-started");
  return "fail" unless -r "$d/row" && -r "$d/after" && defined $f->[5] && slurp("$d/after") eq substr($f->[5], 1) && lp($d) eq "700";
  my $exp = $line;
  if (substr($f->[2], 1) ne "skip") { my @g = @$f; $g[5] = "\@pending"; $exp = join("\t", @g) }
  return slurp("$d/row") eq $exp ? "ok" : "fail";
}
if ($cmd eq "fp") { print fp($ARGV[0]), "\n"; exit 0 }
# has <manifeste> <texte> : 0 si le texte (octets NUL retirés, comme bash les lit) contient la chaîne, 1 sinon, 2 illisible
if ($cmd eq "has") {
  my ($man, $s) = @ARGV; open(my $fh, "<:raw", $man) or exit 2; local $/; my $c = <$fh>; close $fh; $c = "" unless defined $c;
  $c =~ tr/\0//d; exit(index($c, $s) >= 0 ? 0 : 1);
}
if ($cmd eq "committed") {
  my $man = shift @ARGV; open(my $fh, "<:raw", $man) or exit 0; local $/; my $c = <$fh>; close $fh; $c = "" unless defined $c;
  for my $id (@ARGV) { print "$id\n" if index($c, "\@$id\t") >= 0 }
  exit 0;
}
if ($cmd eq "rows" || $cmd eq "meta") {
  my ($man, $bk, $with) = @ARGV; my $last = "!"; my $meta = "ok"; my $rows = $cmd eq "rows";
  if (open(my $fh, "<:raw", $man)) { if (-s $fh) { seek($fh, -1, 2); read($fh, my $c, 1); $last = ord($c) } else { $last = "-" } close $fh }
  print lp($man), "\t$last\n" if $rows;
  open(my $in, "<:raw", $man) or exit 0;
  while (my $line = <$in>) {
    chomp $line; $line =~ tr/\0//d;
    my @f = split /\t/, $line, -1;
    if (@f < 3 || $f[0] !~ /^\@txn\.[a-zA-Z0-9]+$/ || $f[1] !~ /^\@[1-9][0-9]*$/) { print "-\n" if $rows; next }
    my $d = "$bk/" . substr($f[0], 1) . "/" . substr($f[1], 1);
    $meta = meta_row($line, \@f, $d, $bk) if $meta eq "ok";
    next unless $rows;
    my @o = ($d, lp("$d/row"), lp("$d/after"), lp("$d/done"), ty($d), ($with && defined $f[4] && $f[4] =~ /^\@[0-9a-f]{64}$/) ? fp("$d/before") : "-");
    if (-e "$d/retirement" || -l "$d/retirement") {
      push @o, lp("$d/retirement"), lp("$d/retirement/state"), $with ? (fp("$d/retirement/before"), fp("$d/retirement/after")) : ("-", "-");
    } else { push @o, "-", "-", "-", "-" }
    print join("\t", @o), "\n";
  }
  # après la dernière ligne : le verdict des métadonnées de toutes les lignes (la première ligne fausse décide)
  print "meta\t$meta\n";
}'
_txn_fingerprint() {
  local fp
  fp="$(perl -e "$TXN_FACTS_PL" fp "$1" 2>/dev/null)" && [ -n "$fp" ] && [ "$fp" != '!' ] || return 1
  printf '%s\n' "$fp"
}
# _txn_slurp <fichier> : LAB_TXN_SLURP, son contenu comme $(cat fichier) le donnait (octets NUL ôtés, fins de ligne finales
# retirées), sans programme
_txn_slurp() {
  local _c=''
  LAB_TXN_SLURP=''
  { while IFS= read -r -d '' _c; do LAB_TXN_SLURP="$LAB_TXN_SLURP$_c"; done; LAB_TXN_SLURP="$LAB_TXN_SLURP$_c"; } 2>/dev/null <"$1" || true
  while [ "${LAB_TXN_SLURP%$'\n'}" != "$LAB_TXN_SLURP" ]; do LAB_TXN_SLURP="${LAB_TXN_SLURP%$'\n'}"; done
}
# _txn_mode_is <chemin> <mode> : le mode « %Lp » de stat vaut <mode>. Validation groupée : lu dans les faits de la ligne courante
# (LAB_TXN_B, réponse rows de TXN_FACTS_PL) ; tout autre chemin, ou un fait non lu, par stat
_txn_mode_is() {
  local v='-' b="${LAB_TXN_B[0]:--}"
  if [ "$b" != - ]; then
    case "$1" in
      "$b/row") v="${LAB_TXN_B[1]:--}" ;; "$b/after") v="${LAB_TXN_B[2]:--}" ;; "$b/done") v="${LAB_TXN_B[3]:--}" ;;
      "$b/retirement") v="${LAB_TXN_B[6]:--}" ;; "$b/retirement/state") v="${LAB_TXN_B[7]:--}" ;;
    esac
  fi
  [ "$v" != - ] || v="$(stat -f '%Lp' "$1")"
  [ "$v" = "$2" ]
}
# _txn_fp_is <chemin> <empreinte> : même lecture pour une empreinte (before, retirement/before, retirement/after)
_txn_fp_is() {
  local v='-' b="${LAB_TXN_B[0]:--}"
  if [ "$b" != - ]; then
    case "$1" in
      "$b/before") v="${LAB_TXN_B[5]:--}" ;; "$b/retirement/before") v="${LAB_TXN_B[8]:--}" ;; "$b/retirement/after") v="${LAB_TXN_B[9]:--}" ;;
    esac
  fi
  if [ "$v" = - ]; then v="$(_txn_fingerprint "$1")" || v=''; fi
  [ "$v" = "$2" ]
}
_txn_allowed() {
  local pair
  [[ "$1" =~ ^[a-zA-Z_][a-zA-Z_0-9]*$ ]] && [[ "$2" =~ ^[a-zA-Z_][a-zA-Z_0-9]*$ ]] || return 1
  declare -F "$1" >/dev/null && declare -F "$2" >/dev/null || return 1
  for pair in ${LAB_TXN_COMMANDS[@]+"${LAB_TXN_COMMANDS[@]}"}; do
    [ "$pair" != "$1:$2" ] || return 0
  done
  return 1
}
_txn_target_allowed() {
  local target="$1" action="${2:-}" name
  # Données dérivées du programme, à distance du manifeste et des sauvegardes.
  case "$target" in
    "$LAB_STATE/generated"|"$LAB_STATE/generated/codex-agents")
      case "$action" in mkdir|skip) return 0 ;; *) return 1 ;; esac ;;
    "$LAB_STATE/generated/codex-agents/"*)
      name="${target##*/}"
      [ "$target" = "$LAB_STATE/generated/codex-agents/$name" ] || return 1
      [[ "$name" =~ ^[a-zA-Z0-9_-]+\.toml$ ]] || return 1
      case "$action" in create|modify|cmd|skip) return 0 ;; *) return 1 ;; esac ;;
  esac
  case "$target/" in "$LAB_STATE/"*) return 1 ;; esac
  case "$LAB_STATE/" in "$target/"*) return 1 ;; esac
}
_txn_target() { # Canonise le parent, conserve le lien final sauf pour modify.
  local p="$1" parent base
  _txn_field "$p" && [ -n "$p" ] || return 1
  base="$(basename "$p")"; parent="$(dirname "$p")"
  case "$base" in /|.|..) return 1 ;; esac
  parent="$(cd "$parent" && pwd -P && printf '.')" || return
  parent="${parent%$'\n.'}"
  _txn_field "$parent" || return 1
  LAB_TXN_TARGET="${parent%/}/$base"
  _txn_target_allowed "$LAB_TXN_TARGET" "${2:-}"
}
_txn_validate_row() {
  local line="$1" committed="$2" d before after action target forward inverse
  _txn_field "${line//$'\t'/}" && _txn_parse "$line" || return 1
  [[ "${LAB_TXN_FIELDS[0]}" =~ ^txn\.[a-zA-Z0-9]+$ ]] || return 1
  [[ "${LAB_TXN_FIELDS[1]}" =~ ^[1-9][0-9]*$ ]] || return 1
  action="${LAB_TXN_FIELDS[2]}"; target="${LAB_TXN_FIELDS[3]}"
  before="${LAB_TXN_FIELDS[4]}"; after="${LAB_TXN_FIELDS[5]}"
  forward="${LAB_TXN_FIELDS[6]}"; inverse="${LAB_TXN_FIELDS[7]}"
  case "$action" in mkdir|symlink|replace|create|modify|cmd|skip) ;; *) return 1 ;; esac
  case "$target" in /*) ;; *) return 1 ;; esac
  case "$target/" in *'/../'*|*'/./'*|*'//'*) return 1 ;; esac
  _txn_target_allowed "$target" "$action" || return 1
  if [ "$action" = skip ]; then [ "$before:$after" = none:none ] || return 1
  else
    [[ "$before" = absent || "$before" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$after" = absent || "$after" = pending || "$after" =~ ^[0-9a-f]{64}$ ]] || return 1
    [ "$committed:$after" != yes:pending ] || return 1
  fi
  if [ "$action" = cmd ]; then _txn_allowed "$forward" "$inverse" || return 1
  else [ -z "$forward$inverse" ] || return 1; fi
  d="$LAB_TXN_BACKUPS/${LAB_TXN_FIELDS[0]}/${LAB_TXN_FIELDS[1]}"
  _txn_plain_path "$d" && [ -d "$d" ] || return 1
  local f t="${LAB_TXN_B[4]:-}"
  # row, after, done : lien refusé, absent admis, sinon fichier 0600. Types et modes lus par le programme perl pour ce dossier
  # (lot 03 de charge-processeur : trois stat et un appel par fichier et par ligne) ; sans ces faits, chaque fichier relu ici.
  if [ "${#t}" -eq 3 ] && [ "${LAB_TXN_B[0]:-}" = "$d" ]; then
    case "$t" in *[!af]*) return 1 ;; esac
    [ "${t:0:1}" = a ] || [ "${LAB_TXN_B[1]:-}" = 600 ] || return 1
    [ "${t:1:1}" = a ] || [ "${LAB_TXN_B[2]:-}" = 600 ] || return 1
    [ "${t:2:1}" = a ] || [ "${LAB_TXN_B[3]:-}" = 600 ] || return 1
  else
    for f in row after 'done'; do
      [ ! -L "$d/$f" ] || return 1   # $d vérifié juste au-dessus : seul le dernier composant reste
      if [ -e "$d/$f" ]; then
        [ -f "$d/$f" ] && _txn_mode_is "$d/$f" 600 || return 1
      fi
    done
  fi
  if [ -f "$d/done" ]; then _txn_slurp "$d/done"; [ "$LAB_TXN_SLURP" = 'done' ] || return 1; fi
  # Une migration annulée rétablit le lien du dossier parent après ses enfants.
  # Les opérations déjà acquittées n'accèdent plus à cette cible désormais liée.
  # Parent d'une cible absolue normalisée (vérifiée plus haut) : celui de dirname, sans programme.
  f="${target%/*}"; [ -n "$f" ] || f=/
  [ -f "$d/done" ] || _txn_plain_path "$f" || return 1
  _txn_retirement_validate "$d" "$target" || return 1
  if [ "$before" != absent ] && [ "$before" != none ]; then
    # before peut lui-même être le lien sauvegardé ; son contenu doit correspondre.
    _txn_fp_is "$d/before" "$before" || return 1
  fi
}
_txn_sealed_count() {
  local file="$LAB_TXN_BACKUPS/$1/sealed-count"
  _txn_plain_path "$file" && [ -f "$file" ] && _txn_slurp "$file" && [ "$LAB_TXN_SLURP" = "$2" ] || return 1
  file="$LAB_TXN_BACKUPS/$1/remove-started"
  if [ -e "$file" ] || [ -L "$file" ]; then
    _txn_plain_path "$file" && [ -f "$file" ] && [ "$(stat -f %Lp "$file")" = 600 ] &&
      _txn_slurp "$file" && [ "$LAB_TXN_SLURP" = treelab-removal-v1 ] || return 1
  fi
}
# Validation groupée (lot 03 de charge-processeur) : les mêmes règles, ligne par ligne, avec les faits de tout l'historique lus en
# une passe par TXN_FACTS_PL (descripteur 4, une réponse par ligne du manifeste lu sur 3) ; sans réponse, chaque fait est relu seul.
_txn_validate_manifest() {
  LAB_TXN_META=''; LAB_TXN_SETUP_FOR=''; LAB_TXN_SETUP_NOTE=''
  [ ! -e "$LAB_TXN_MANIFEST" ] || {
    [ -f "$LAB_TXN_MANIFEST" ] || return 1
    # illisible : le mode décide seul, sans ouvrir le fichier, comme avant
    [ -r "$LAB_TXN_MANIFEST" ] || [ "$(stat -f '%Lp' "$LAB_TXN_MANIFEST")" = 600 ] || return 1
    # shellcheck disable=SC2094 # le manifeste est lu deux fois, jamais écrit
    _txn_validate_rows 3<"$LAB_TXN_MANIFEST" 4< <(exec perl -e "$TXN_FACTS_PL" rows "$LAB_TXN_MANIFEST" "$LAB_TXN_BACKUPS" 1 2>/dev/null)
  }
}
_txn_validate_rows() {
  local line n=0 prev='' seq=0 seen='|' id order mode='' last='' setup=yes LAB_TXN_PLAIN_OK='' LAB_TXN_PLAIN_LAST='' LAB_TXN_PLAIN_PREV=''
  local -a LAB_TXN_B=()
  ! _txn_plain_path "$LAB_TXN_BACKUPS" || LAB_TXN_PLAIN_OK="$LAB_TXN_BACKUPS"
  IFS=$'\t' read -r mode last <&4 || true
  [ -n "$mode" ] && [ "$mode" != '!' ] || mode="$(stat -f '%Lp' "$LAB_TXN_MANIFEST")"
  [ "$mode" = 600 ] || return 1
  while IFS= read -r line <&3 || [ -n "$line" ]; do
    n=$((n + 1)); LAB_TXN_B=()
    IFS=$'\t' read -r -a LAB_TXN_B <&4 || true
    if [ "$n" -eq 1 ]; then [ "$line" = $'treelab-install\t1' ] || return 1; continue; fi
    _txn_validate_row "$line" yes || return 1
    # note de pose de la dernière ligne skip qui en porte une, comme _setup_info la relirait ; skip sans note : _setup_info la jugera
    # shellcheck disable=SC2034 # LAB_TXN_SETUP_NOTE : lu par doctor_setup_info (lib/doctor_product.sh)
    if [ "${LAB_TXN_FIELDS[2]}" = skip ]; then
      if [ "${#LAB_TXN_FIELDS[@]}" -lt 9 ]; then setup=no
      else case "${LAB_TXN_FIELDS[8]}" in treelab-setup-v1:*) LAB_TXN_SETUP_NOTE="${LAB_TXN_FIELDS[8]#treelab-setup-v1:}" ;; esac; fi
    fi
    id="${LAB_TXN_FIELDS[0]}"; order="${LAB_TXN_FIELDS[1]}"
    if [ "$id" != "$prev" ]; then
      [ -z "$prev" ] || _txn_sealed_count "$prev" "$seq" || return 1
      case "$seen" in *"|$id|"*) return 1 ;; esac
      seen="$seen$id|"; prev="$id"; seq=0
    fi
    seq=$((seq + 1)); [ "$order" = "$seq" ] || return 1
  done
  # LAB_TXN_META : le verdict des métadonnées (ok, removal, fail), lu après la dernière ligne — celui du doctor, sans second passage
  IFS=$'\t' read -r -a LAB_TXN_B <&4 || true
  # shellcheck disable=SC2034 # lu par doctor_manifest_metadata (lib/doctor_product.sh)
  [ "${LAB_TXN_B[0]:-}" != meta ] || LAB_TXN_META="${LAB_TXN_B[1]:-}"
  LAB_TXN_B=()
  [ "$n" -ge 1 ] || return 1
  [ -z "$prev" ] || _txn_sealed_count "$prev" "$seq" || return 1
  # Une dernière ligne sans terminateur est tronquée.
  case "$last" in ''|'!') last="$(tail -c 1 "$LAB_TXN_MANIFEST" | od -An -tu1 | tr -d ' ')" ;; -) last='' ;; esac
  [ "$last" = 10 ] || return 1
  # LAB_TXN_SETUP_FOR (lot 03 de charge-processeur) : manifeste validé dont LAB_TXN_SETUP_NOTE est la note de pose — lu par le doctor
  # seul, qui n'écrit pas entre les deux (doctor_setup_info) ; setup et update relisent par _setup_info
  # shellcheck disable=SC2034 # lu par doctor_setup_info (lib/doctor_product.sh)
  [ "$setup" = no ] || LAB_TXN_SETUP_FOR="$LAB_TXN_MANIFEST"
}
_txn_committed() { [ -f "$LAB_TXN_MANIFEST" ] && grep -Fq "@$1"$'\t' "$LAB_TXN_MANIFEST"; }
# _txn_committed_in <id> <ids lus> <ids validés> : réponse de la lecture groupée de _txn_pending, sinon _txn_committed
_txn_committed_in() {
  case "$2" in *$'\n'"$1"$'\n'*) case "$3" in *$'\n'"$1"$'\n'*) return 0 ;; *) return 1 ;; esac ;; esac
  _txn_committed "$1"
}
_txn_pending() {
  local d asked=$'\n' set=$'\n'; local -a ids=()
  LAB_TXN_PENDING=''
  # les transactions validées lues en un seul programme ; un nom à fin de ligne, ou absent de cette lecture, par _txn_committed
  for d in "$LAB_TXN_BACKUPS"/txn.*; do
    _txn_exists "$d" || continue
    case "${d##*/}" in *$'\n'*) ;; *) ids+=("${d##*/}"); asked="$asked${d##*/}"$'\n' ;; esac
  done
  if [ "${#ids[@]}" -gt 0 ] && [ -f "$LAB_TXN_MANIFEST" ]; then
    set="$set$(perl -e "$TXN_FACTS_PL" committed "$LAB_TXN_MANIFEST" "${ids[@]}" 2>/dev/null)"$'\n' || asked=$'\n'
  fi
  for d in "$LAB_TXN_BACKUPS"/txn.*; do
    _txn_exists "$d" || continue
    _txn_plain_path "$d" && [ -d "$d" ] || return 1
    if [ -e "$d/retired" ] || [ -L "$d/retired" ]; then
      _txn_plain_path "$d/retired" && [ -f "$d/retired" ] &&
        [ "$(stat -f %Lp "$d/retired")" = 600 ] && _txn_slurp "$d/retired" && [ "$LAB_TXN_SLURP" = treelab-retired-v1 ] || return 1
      continue
    fi
    if [ -e "$d/rollback" ] || ! _txn_committed_in "${d##*/}" "$asked" "$set"; then
      [ -z "$LAB_TXN_PENDING" ] || return 1
      LAB_TXN_PENDING="$d"
    fi
  done
}
_txn_restore_shell() {
  [ "${LAB_TXN_ARMED:-no}" = yes ] || return 0
  trap - ERR EXIT INT TERM
  # Seul le texte produit par trap -p de l'appelant est réinstallé. Jamais le TSV.
  eval "$LAB_TXN_SAVED_TRAPS"
  [ "$LAB_TXN_SAVED_E" = yes ] || set +E
  [ "$LAB_TXN_SAVED_PIPE" = yes ] || set +o pipefail
  LAB_TXN_ARMED=no
}
_txn_abort() {
  local rc="$1" cause="$2"
  [ "$rc" -ne 0 ] || rc=1
  export LAB_TXN_ERROR_CODE="$rc" LAB_TXN_ERROR_CAUSE="$cause"
  trap - ERR EXIT INT TERM
  _txn_message "Failed (code $rc): $cause"
  txn_rollback || true
  _txn_restore_shell
  exit "$rc"
}
_txn_fail() {
  local rc="$1" cause="$2"
  export LAB_TXN_ERROR_CODE="$rc" LAB_TXN_ERROR_CAUSE="$cause"
  _txn_message "Failed (code $rc): $cause"
  txn_rollback || true
  return "$rc"
}
_txn_mkdir_technical() {
  local p="$1"
  [ ! -d "$p" ] || return 0
  _txn_mkdir_technical "$(dirname "$p")" || return
  mkdir -m 700 "$p" || return
  LAB_TXN_CREATED=("$p" ${LAB_TXN_CREATED[@]+"${LAB_TXN_CREATED[@]}"})
}
txn_begin() {
  # Sans errtrace, bash masque le trap ERR extérieur dès l'entrée en fonction :
  # il serait impossible de le sauvegarder. Exiger l'héritage avant toute écriture.
  case "$-" in *E*) ;; *) _txn_message 'Enable set -E before txn_begin to keep the ERR trap of your shell.'; return 2 ;; esac
  [ -z "${LAB_TXN_ACTIVE:-}" ] || { _txn_message 'Transaction already open. Finish its restore before starting again.'; return 1; }
  if ! { _txn_paths && _txn_validate_manifest && _txn_pending; }; then
    _txn_message "Invalid log: ${LAB_TXN_MANIFEST:-none}. Keep the backups and restore the log before resuming."; return 1;
  fi
  [ -z "$LAB_TXN_PENDING" ] || {
    _txn_message "Restore pending: $LAB_TXN_PENDING. Resume txn_rollback before an installation."; return 1;
  }
  LAB_TXN_CREATED=()
  if _txn_mkdir_technical "$LAB_TXN_BACKUPS"; then :; else _txn_begin_cleanup; return 1; fi
  LAB_TXN_ACTIVE="$(mktemp -d "$LAB_TXN_BACKUPS/txn.XXXXXXXX")" || { _txn_begin_cleanup; return 1; }
  LAB_TXN_ID="${LAB_TXN_ACTIVE##*/}"; LAB_TXN_SEQ=0
  if _txn_private_file "$LAB_TXN_ACTIVE/parents" &&
     printf '%s\n' ${LAB_TXN_CREATED[@]+"${LAB_TXN_CREATED[@]}"} >"$LAB_TXN_ACTIVE/parents"; then :
  else _txn_begin_cleanup; return 1; fi
  if [ -f "$LAB_TXN_MANIFEST" ]; then
    _txn_write "$LAB_TXN_ACTIVE/manifest-state" present || { _txn_begin_cleanup; return 1; }
    _txn_copy "$LAB_TXN_MANIFEST" "$LAB_TXN_ACTIVE/manifest.before" || { _txn_begin_cleanup; return 1; }
  else
    _txn_write "$LAB_TXN_ACTIVE/manifest-state" absent || { _txn_begin_cleanup; return 1; }
  fi
  LAB_TXN_SAVED_TRAPS="$(trap -p ERR EXIT INT TERM)"
  LAB_TXN_SAVED_E=no; case "$-" in *E*) LAB_TXN_SAVED_E=yes ;; esac
  LAB_TXN_SAVED_PIPE=no; if shopt -qo pipefail; then LAB_TXN_SAVED_PIPE=yes; fi
  set -E -o pipefail
  LAB_TXN_ARMED=yes
  trap '_txn_abort "$?" "$BASH_COMMAND"' ERR
  trap '_txn_abort "$?" "exit without commit"' EXIT
  trap '_txn_abort 130 "INT interruption"' INT
  trap '_txn_abort 143 "TERM interruption"' TERM
}
_txn_begin_cleanup() {
  local p
  if [ -n "${LAB_TXN_ACTIVE:-}" ]; then rm -R "$LAB_TXN_ACTIVE" || return; fi
  LAB_TXN_ACTIVE=''
  for p in ${LAB_TXN_CREATED[@]+"${LAB_TXN_CREATED[@]}"}; do rmdir "$p" || return; done
}
_txn_copy() { cp -pPR "$1" "$2"; }
_txn_remove() { if _txn_exists "$1"; then rm -R "$1"; fi; }
_txn_apply() {
  local action="$1" target="$2"; shift 2
  case "$action" in
    mkdir) mkdir "$target" ;;
    symlink) ln -s "$1" "$target" ;;
    create) _txn_copy "$1" "$target" ;;
    replace) _txn_remove "$target" && _txn_copy "$1" "$target" ;;
    modify) cat "$1" >"$target" ;;
    cmd) local forward="$1"; shift 2; "$forward" "$target" "$@" ;;
    skip) : ;;
  esac
}
record_op() {
  [ -n "${LAB_TXN_ACTIVE:-}" ] || { _txn_message 'No open transaction. Call txn_begin before any write.'; return 1; }
  local rc
  if _txn_record "$@"; then return 0; else rc=$?; fi
  if [ "$rc" -eq 2 ]; then
    _txn_message 'Arguments refused. Check collisions, allowed functions and paths; tab, carriage return and line feed are forbidden.'
  fi
  _txn_fail "$rc" "operation ${1:-missing} on ${2:-missing target}; check the shown cause before trying again."
}
_txn_resolve_modify() (
  # Garder le résolveur commun ; refuser les cibles illisibles en TSV avant qu’une
  # substitution de commande interne puisse retirer leurs LF terminaux.
  # shellcheck disable=SC2329 # Appel indirect par resolve_file de lib/git.sh.
  readlink() { _txn_readlink "$1" && printf '%s\n' "$LAB_TXN_LINK"; }
  resolve_file "$1"
)
_txn_record() {
  [ "$#" -ge 2 ] || return 2
  local action="$1" target="$2" field before after d forward='' inverse='' parent
  shift 2
  for field in "$target" "$@"; do _txn_field "$field" || return 2; done
  case "$action" in
    mkdir)
      [ "$#" -eq 0 ] || return 2
      if [ -d "$target" ] && [ ! -L "$target" ]; then action=skip; set -- 'existing folder'
      elif ! _txn_exists "$target"; then
        parent="$(dirname "$target")"
        [ -d "$parent" ] || _txn_record mkdir "$parent" || return
      else return 2; fi ;;
    symlink)
      [ "$#" -eq 1 ] || return 2
      if [ -L "$target" ] && _txn_readlink "$target" && [ "$LAB_TXN_LINK" = "$1" ]; then action=skip; set -- 'same link'
      else ! _txn_exists "$target" || return 2; fi ;;
    create) [ "$#" -eq 1 ] && [ -f "$1" ] && [ ! -L "$1" ] && ! _txn_exists "$target" || return 2 ;;
    replace) [ "$#" -eq 1 ] && _txn_exists "$1" && _txn_exists "$target" || return 2 ;;
    modify)
      [ "$#" -eq 1 ] && [ -f "$1" ] || return 2
      target="$(_txn_resolve_modify "$target")" && [ -f "$target" ] || return 2 ;;
    cmd) [ "$#" -ge 2 ] && _txn_allowed "$1" "$2" || return 2; forward="$1"; inverse="$2" ;;
    skip) [ "$#" -eq 1 ] || return 2 ;;
    *) return 2 ;;
  esac
  _txn_target "$target" "$action" || return 2; target="$LAB_TXN_TARGET"
  before=none; after=none
  if [ "$action" != skip ]; then before="$(_txn_fingerprint "$target")" || return; after=pending; fi
  LAB_TXN_SEQ=$((LAB_TXN_SEQ + 1)); d="$LAB_TXN_ACTIVE/$LAB_TXN_SEQ"
  mkdir -m 700 "$d" || return
  if [ "$before" != absent ] && [ "$before" != none ]; then _txn_copy "$target" "$d/before" || return; fi
  _txn_private_file "$d/row.tmp" || return
  if [ "$action" = cmd ]; then
    _txn_row "$LAB_TXN_ID" "$LAB_TXN_SEQ" "$action" "$target" "$before" "$after" "$forward" "$inverse" "${@:3}" >"$d/row.tmp" || return
  elif [ "$action" = skip ]; then
    _txn_row "$LAB_TXN_ID" "$LAB_TXN_SEQ" "$action" "$target" "$before" "$after" '' '' "$1" >"$d/row.tmp" || return
  else _txn_row "$LAB_TXN_ID" "$LAB_TXN_SEQ" "$action" "$target" "$before" "$after" '' '' >"$d/row.tmp" || return; fi
  mv "$d/row.tmp" "$d/row" || return
  # Dès cet instant l'opération courante fait partie de l'annulation, même partielle.
  _txn_apply "$action" "$target" "$@" >&2 || return
  if [ "$action" != skip ]; then after="$(_txn_fingerprint "$target")" || return; fi
  _txn_write "$d/after" "$after"
}
_txn_undo_row() {
  local line="$1" prudent="$2" d action target before after current inverse
  _txn_validate_row "$line" "$prudent" || return 1
  d="$LAB_TXN_BACKUPS/${LAB_TXN_FIELDS[0]}/${LAB_TXN_FIELDS[1]}"
  if [ "$prudent" = yes ] && [ -d "$d/retirement" ]; then
    _txn_retirement_apply "$d" "${LAB_TXN_FIELDS[3]}"; return
  fi
  [ ! -f "$d/done" ] || return 0
  action="${LAB_TXN_FIELDS[2]}"; target="${LAB_TXN_FIELDS[3]}"
  before="${LAB_TXN_FIELDS[4]}"; after="${LAB_TXN_FIELDS[5]}"; inverse="${LAB_TXN_FIELDS[7]}"
  if [ "$action" != skip ]; then
    if ! current="$(_txn_fingerprint "$target")"; then
      _txn_message "Object kept, unreadable or holding a control character: $target"
      _txn_message 'Check the permissions and the link target, then resume the replay.'
      return 1
    fi
    # Une panne de publication du marqueur ne répète pas un inverse achevé.
    if [ "$current" = "$before" ]; then _txn_write "$d/done" 'done'; return; fi
  fi
  if [ "$prudent" = yes ] && [ "$action" != skip ]; then
    if [ "$action" = mkdir ] && [ "$current" = absent ]; then :
    elif [ "$current" != "$after" ]; then
      _txn_message "Kept because changed since the installation: $target"
      _txn_message "Backup: $d. Put the recent data somewhere safe, restore the installed state, then resume uninstall_replay."
      return 1
    fi
  fi
  case "$action" in
    skip) : ;;
    mkdir) if _txn_exists "$target"; then rmdir "$target" || return; fi ;;
    cmd)
      local rc
      if "$inverse" "$target" "${LAB_TXN_FIELDS[@]:8}" >&2; then :; else
        rc=$?
        _txn_message "Inverse $inverse failed (code $rc): $target. Fix this function before resuming."
        return "$rc"
      fi
      [ "$(_txn_fingerprint "$target")" = "$before" ] || return 1 ;;
    *)
      _txn_remove "$target" || return
      if [ "$before" != absent ]; then _txn_copy "$d/before" "$target" || return; fi ;;
  esac
  _txn_write "$d/done" 'done'
}
# Retrait sélectif versionné, hors des transactions d'installation : il n'a pas
# d'inverse qui puisse réinstaller une intégration. L'état prêt et les deux copies
# sont publiés avant l'effet. Les lignes précédentes de la même cible sont ensuite
# acquittées ; une reprise répète cet acquittement même si la dernière est déjà done.
_txn_retirement_validate() {
  local d="$1/retirement" target="$2" f
  [ ! -e "$d" ] && [ ! -L "$d" ] && return 0
  _txn_plain_path "$d" && [ -d "$d" ] && _txn_mode_is "$d" 700 || return 1
  for f in state before after; do
    _txn_plain_path "$d/$f" && [ -f "$d/$f" ] || return 1
  done
  _txn_mode_is "$d/state" 600 || return 1
  local lines=() line
  while IFS= read -r line; do lines+=("$line"); done <"$d/state"
  [ "${#lines[@]}" -eq 4 ] && [ "${lines[0]}" = treelab-retirement-v1 ] && [ "${lines[1]}" = "$target" ] || return 1
  _txn_fp_is "$d/before" "${lines[2]}" && _txn_fp_is "$d/after" "${lines[3]}"
}
_txn_retirement_ack() {
  local stop="$1" target="$2" line d
  while IFS= read -r line; do
    [ "$line" != $'treelab-install\t1' ] || continue
    _txn_parse "$line" || return 1
    d="$LAB_TXN_BACKUPS/${LAB_TXN_FIELDS[0]}/${LAB_TXN_FIELDS[1]}"
    if [ "${LAB_TXN_FIELDS[3]}" = "$target" ] && [ ! -f "$d/done" ]; then
      # Un ajout client peut empêcher de rétablir le lien d'instructions ancien.
      # Garder cette restauration en attente, même après retrait de notre bloc.
      if [ "${LAB_TXN_FIELDS[2]}" = replace ] && [ -L "$d/before" ]; then :
      else _txn_write "$d/done" 'done' || return; fi
    fi
    [ "$d" != "$stop" ] || return 0
  done <"$LAB_TXN_MANIFEST"
  return 1
}
_txn_retirement_apply() {
  local d="$1" target="$2" current before after tmp
  _txn_retirement_validate "$d" "$target" || return 1
  if [ ! -f "$d/done" ]; then
    current="$(_txn_fingerprint "$target")" || return
    before="$(sed -n '3p' "$d/retirement/state")"; after="$(sed -n '4p' "$d/retirement/state")"
    if [ "$current" = "$before" ]; then
      tmp="$(mktemp "$(dirname "$target")/.treelab-retire.XXXXXXXX")" || return
      if _txn_copy "$d/retirement/after" "$tmp" && mv -f "$tmp" "$target"; then :
      else local rc=$?; rm -f "$tmp"; return "$rc"; fi
    elif [ "$current" != "$after" ]; then
      _txn_message "Incomplete removal, recent change kept: $target. Backups: $d/retirement. Restore the saved target before resuming."
      return 1
    fi
  fi
  _txn_retirement_ack "$d" "$target"
}
# uninstall_retire <cible canonique> <fichier préparé> : seulement un fichier
# partagé modifié depuis sa pose. La préparation sélective appartient à la CLI.
uninstall_retire() {
  local target="$1" prepared="$2" line latest='' d='' staging before after action
  [ -z "${LAB_TXN_ACTIVE:-}" ] && _txn_paths && _txn_validate_manifest && _txn_pending && [ -z "$LAB_TXN_PENDING" ] || return 1
  [ -f "$target" ] && [ ! -L "$target" ] && [ -f "$prepared" ] && [ ! -L "$prepared" ] || return 1
  [ -f "$LAB_TXN_MANIFEST" ] || return 1
  while IFS= read -r line; do
    [ "$line" != $'treelab-install\t1' ] || continue
    _txn_parse "$line" || return 1
    if [ "${LAB_TXN_FIELDS[3]}" = "$target" ] && [ "${LAB_TXN_FIELDS[2]}" != skip ]; then latest="$line"; fi
  done <"$LAB_TXN_MANIFEST"
  [ -n "$latest" ] && _txn_parse "$latest" || return 1
  action="${LAB_TXN_FIELDS[2]}"; case "$action" in create|modify) ;; *) return 1 ;; esac
  d="$LAB_TXN_BACKUPS/${LAB_TXN_FIELDS[0]}/${LAB_TXN_FIELDS[1]}"
  if [ -d "$d/retirement" ]; then _txn_retirement_apply "$d" "$target"; return; fi
  [ ! -f "$d/done" ] || return 0
  staging="$(mktemp -d "$d/retirement.XXXXXXXX")" || return
  if _txn_copy "$target" "$staging/before" && _txn_copy "$prepared" "$staging/after" &&
     chmod "$(stat -f %Lp "$target")" "$staging/after" &&
     before="$(_txn_fingerprint "$staging/before")" && after="$(_txn_fingerprint "$staging/after")" &&
     _txn_write "$staging/state" "$(printf 'treelab-retirement-v1\n%s\n%s\n%s' "$target" "$before" "$after")" &&
     mv "$staging" "$d/retirement"; then :
  else local rc=$?; _txn_remove "$staging"; return "$rc"; fi
  _txn_retirement_apply "$d" "$target"
}
_txn_restore_manifest() {
  local d="$LAB_TXN_ACTIVE"
  _txn_plain_path "$d/manifest.before" && _txn_plain_path "$d/manifest.restore" && _txn_plain_path "$d/manifest-state" || return 1
  local previous; previous="$(cat "$d/manifest-state")" || return
  case "$previous" in present|absent) ;; *) return 1 ;; esac
  if [ "$previous" = present ]; then
    [ -f "$d/manifest.before" ] || return 1
    # Préserver octets, mode et date du manifeste ancien, y compris après son mv.
    if ! cmp -s "$d/manifest.before" "$LAB_TXN_MANIFEST"; then
      _txn_copy "$d/manifest.before" "$d/manifest.restore" && mv -f "$d/manifest.restore" "$LAB_TXN_MANIFEST"
    fi
  elif [ -e "$LAB_TXN_MANIFEST" ]; then rm "$LAB_TXN_MANIFEST"
  fi
}
txn_rollback() {
  _txn_paths || return
  if [ -z "${LAB_TXN_ACTIVE:-}" ]; then
    _txn_validate_manifest && _txn_pending || return 1
    LAB_TXN_ACTIVE="$LAB_TXN_PENDING"
  fi
  if [ -z "$LAB_TXN_ACTIVE" ]; then _txn_message 'Nothing to restore.'; return 0; fi
  local d line p failed=0 dirs=() parents=()
  if ! { _txn_write "$LAB_TXN_ACTIVE/rollback" pending && _txn_restore_manifest; }; then
    _txn_restore_shell
    _txn_message "Incomplete restore of the manifest: $LAB_TXN_MANIFEST. Backups kept: $LAB_TXN_ACTIVE. Fix the permissions, then resume txn_rollback."
    return 1
  fi
  _txn_plain_path "$LAB_TXN_ACTIVE" && _txn_plain_path "$LAB_TXN_ACTIVE/parents" || return 1
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    _txn_field "$p" && _txn_plain_path "$p" || return 1
    case "$LAB_TXN_BACKUPS/" in "$p/"*) parents+=("$p") ;; *) return 1 ;; esac
  done <"$LAB_TXN_ACTIVE/parents"
  while IFS= read -r d; do dirs+=("$d"); done < <(find "$LAB_TXN_ACTIVE" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort -t / -k 1,1)
  # Les noms des opérations sont numériques ; ne jamais trier 10 avant 2.
  local n max=0
  for d in ${dirs[@]+"${dirs[@]}"}; do n="${d##*/}"; [[ "$n" =~ ^[1-9][0-9]*$ ]] || { failed=1; break; }; [ "$n" -le "$max" ] || max="$n"; done
  # Prévalider toutes les lignes avant le premier inverse, même en reprise.
  for d in ${dirs[@]+"${dirs[@]}"}; do
    _txn_plain_path "$d/row" || { failed=1; break; }
    if [ -f "$d/row" ]; then
      if ! { line="$(cat "$d/row")" && _txn_validate_row "$line" no; }; then failed=1; break; fi
    fi
  done
  n="$max"
  while [ "$failed" -eq 0 ] && [ "$n" -gt 0 ]; do
    d="$LAB_TXN_ACTIVE/$n"
    if [ -f "$d/row" ]; then
      line="$(cat "$d/row")" || { failed=1; break; }
      if _txn_undo_row "$line" no; then :; else failed=1; break; fi
    fi
    n=$((n - 1))
  done
  if [ "$failed" -eq 0 ]; then
    rm -R "$LAB_TXN_ACTIVE" || failed=1
    if [ "$failed" -eq 0 ]; then
      LAB_TXN_ACTIVE=''
      for p in ${parents[@]+"${parents[@]}"}; do rmdir "$p" || { failed=1; break; }; done
    fi
  fi
  _txn_restore_shell
  if [ "$failed" -ne 0 ]; then
    _txn_message "Incomplete restore. Backups kept: ${LAB_TXN_ACTIVE:-$LAB_TXN_BACKUPS}"
    _txn_message 'Fix the shown cause (permissions or inverse), then resume txn_rollback.'
    return 1
  fi
  _txn_message 'Restore finished.'
}
txn_commit() {
  [ -n "${LAB_TXN_ACTIVE:-}" ] || { _txn_message 'No transaction to commit. Call txn_begin before trying again.'; return 1; }
  local rc
  if _txn_commit; then LAB_TXN_ACTIVE=''; _txn_restore_shell; return 0; else rc=$?; fi
  _txn_fail "$rc" 'commit impossible; check the log and the permissions, then try again.'
}
_txn_commit() {
  local tmp="$LAB_TXN_ACTIVE/manifest" n=1 d line after
  _txn_validate_manifest && _txn_private_file "$tmp" || return
  if [ -f "$LAB_TXN_MANIFEST" ]; then cat "$LAB_TXN_MANIFEST" >"$tmp" || return
  else printf 'treelab-install\t1\n' >"$tmp" || return; fi
  # Même une transaction vide est représentée ; elle ne doit pas devenir orpheline.
  [ "$LAB_TXN_SEQ" -gt 0 ] || _txn_record skip "$(dirname "$LAB_STATE")/transaction-vide" 'transaction vide' || return
  while [ "$n" -le "$LAB_TXN_SEQ" ]; do
    d="$LAB_TXN_ACTIVE/$n"; line="$(cat "$d/row")" && after="$(cat "$d/after")" || return
    _txn_validate_row "$line" no || return
    LAB_TXN_FIELDS[5]="$after"
    line="$(_txn_row "${LAB_TXN_FIELDS[@]}")" || return
    _txn_validate_row "$line" yes || return
    printf '%s\n' "$line" >>"$tmp" || return
    n=$((n + 1))
  done
  _txn_write "$LAB_TXN_ACTIVE/sealed-count" "$LAB_TXN_SEQ" || return
  mv -f "$tmp" "$LAB_TXN_MANIFEST"
}
uninstall_replay() {
  [ -z "${LAB_TXN_ACTIVE:-}" ] || { _txn_message 'Transaction open. Finish txn_rollback before the replay.'; return 1; }
  if ! { _txn_paths && _txn_validate_manifest && _txn_pending; }; then
    _txn_message "Invalid log: ${LAB_TXN_MANIFEST:-none}. Keep the backups and restore the log before resuming."; return 1;
  fi
  [ -z "$LAB_TXN_PENDING" ] || { _txn_message "Restore pending: $LAB_TXN_PENDING. Resume txn_rollback."; return 1; }
  if [ ! -f "$LAB_TXN_MANIFEST" ]; then _txn_message 'Nothing to undo.'; return 0; fi
  local line rows=() i
  while IFS= read -r line; do rows+=("$line"); done <"$LAB_TXN_MANIFEST"
  i=$((${#rows[@]} - 1))
  while [ "$i" -ge 1 ]; do
    if _txn_undo_row "${rows[i]}" yes; then :; else
      _txn_message "Incomplete restore. Backups kept: $LAB_TXN_BACKUPS"
      _txn_message 'Fix the shown cause, then resume uninstall_replay.'; return 1
    fi
    i=$((i - 1))
  done
  _txn_message 'Undo finished; nothing more to undo.'
}
