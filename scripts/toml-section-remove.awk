# Retrait exact d'une table ; conserve les lignes extérieures sans reformater.
# L'intégralité est analysée avant la première sortie. Aucun texte évalué.
BEGIN { apostrophe = sprintf("%c", 39); wanted = name(ENVIRON["LAB_TOML_SECTION"]); if (wanted == "") unsafe = 1 }
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
# Canonisation par segments, sans confondre [a.b] et ["a.b"].
function name(s,    c, q, part, i, result) {
    s = trim(s); result = ""
    while (length(s)) {
        c = substr(s, 1, 1)
        if (c == "\"" || c == apostrophe) {
            q = c; part = ""; i = 2
            while (i <= length(s) && substr(s, i, 1) != q) {
                c = substr(s, i++, 1)
                if (c == "\\" || c ~ /[[:cntrl:]]/) return ""
                part = part c
            }
            if (i > length(s)) return ""
            s = substr(s, i + 1)
        } else {
            if (!match(s, /^[A-Za-z0-9_-]+/)) return ""
            part = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
        }
        result = result length(part) ":" part ";"
        s = trim(s)
        if (s == "") return result
        if (substr(s, 1, 1) != ".") return ""
        s = trim(substr(s, 2)); if (s == "") return ""
    }
    return ""
}
# Suit chaînes et valeurs composites. Une fausse table reste opaque.
function scan(s,    i, c, three, out, count) {
    out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1); three = substr(s, i, 3)
        if (quote != "") {
            if (c == "\\" && (quote == "\"" || quote == "\"\"\"")) { i++; continue }
            if (length(quote) == 3 && three == quote) {
                count = 3
                while (substr(s, i + count, 1) == c) count++
                if (count > 5) unsafe = 1
                i += count - 1; quote = ""
            } else if (length(quote) == 1 && c == quote) quote = ""
        } else {
            if (c == "#") break
            out = out c
            if (c == "\"" || c == apostrophe) {
                quote = c
                if (three == c c c) { quote = three; i += 2 }
            } else if (c == "[" || c == "{") stack = stack c
            else if (c == "]" || c == "}") {
                if ((c == "]" && substr(stack, length(stack)) != "[") || (c == "}" && substr(stack, length(stack)) != "{")) unsafe = 1
                stack = substr(stack, 1, length(stack) - 1)
            }
        }
    }
    if (length(quote) == 1) unsafe = 1
    return out
}
{
    lines[NR] = $0; line = $0
    cr = sub(/\r$/, "", line)
    if (NR == 1) ending = cr
    if (cr != ending || line ~ /\r/) unsafe = 1
    opaque = (quote != "" || stack != "")
    if (!opaque && line ~ /^[ \t]*\[/) {
        # Trouver le crochet extérieur hors nom cité, puis le commentaire éventuel.
        h = trim(line); q = ""; closing = 0
        array_table = (substr(h, 1, 2) == "[["); first = 2 + array_table
        for (j = first; j <= length(h); j++) {
            c = substr(h, j, 1)
            if (q != "") { if (c == q) q = ""; else if (c == "\\") unsafe = 1 }
            else if (c == "\"" || c == apostrophe) q = c
            else if (c == "]") { closing = j; break }
        }
        if (!closing || trim(substr(h, closing + 1 + array_table)) !~ /^(#.*)?$/) unsafe = 1
        table = name(substr(h, first, closing - first))
        # Le retrait reste conservateur ; la lecture traverse les tableaux clients
        # et leurs sous-tables répétées, sans accepter une approbation en tableau.
        if (array_table && (mode != "approved" || substr(h, closing, 2) != "]]" || table == wanted)) unsafe = 1
        if (table == "" || ((mode != "approved" || table == wanted) && seen[table]++)) unsafe = 1
        skipping = (table == wanted)
    } else {
        code = scan(line)
        if (!opaque && trim(code) != "" && code !~ /=/) unsafe = 1
        # En lecture d'approbation, un en-tête seul ne déclare aucun accord.
        # Les faux champs dans les chaînes multilignes restent opaques.
        equal = index(line, "=")
        if (skipping && !opaque && equal && name(substr(line, 1, equal - 1)) == name("trusted_hash")) {
            approval_count++
            value = trim(substr(line, equal + 1))
            if (value ~ /^"[^"\\]+"[ \t]*(#.*)?$/ ||
                value ~ ("^" apostrophe "[^" apostrophe "]+" apostrophe "[ \t]*(#.*)?$")) approval_value = 1
        }
    }
    removed[NR] = skipping
}
END {
    if (unsafe || quote != "" || stack != "") exit 2
    if (mode == "approved") exit !(approval_count == 1 && approval_value)
    for (n = 1; n <= NR; n++) if (!removed[n]) print lines[n]
}
