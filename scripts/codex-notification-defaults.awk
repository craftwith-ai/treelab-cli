# Ajoute seulement les réglages absents des tables desktop et tui.
# Les chaînes multilignes sont opaques : leur contenu ne définit aucune table.
BEGIN {
    tables[1] = "desktop"; tables[2] = "tui"
    count["desktop"] = 3; count["tui"] = 2
    key["desktop", 1] = "notifications-turn-mode"; value["desktop", 1] = "\"off\""
    key["desktop", 2] = "notifications-permissions-enabled"; value["desktop", 2] = "true"
    key["desktop", 3] = "notifications-questions-enabled"; value["desktop", 3] = "true"
    key["tui", 1] = "notifications"; value["tui", 1] = "[\"approval-requested\"]"
    key["tui", 2] = "notification_condition"; value["tui", 2] = "\"unfocused\""
    apostrophe = sprintf("%c", 39)
}
function name_pattern(name) {
    return "(" name "|\"" name "\"|" apostrophe name apostrophe ")"
}
# Retire les commentaires et suit les délimiteurs de chaînes, sans interpréter les valeurs.
function scan(line,    i, c, three, out) {
    out = ""
    for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1); three = substr(line, i, 3)
        if (quote != "") {
            out = out c
            if (c == "\\" && (quote == "\"" || quote == "\"\"\"")) {
                out = out substr(line, ++i, 1)
            } else if (length(quote) == 3 && three == quote) {
                out = out substr(line, i + 1, 2); i += 2; quote = ""
            } else if (length(quote) == 1 && c == quote) quote = ""
        } else {
            if (c == "#") break
            out = out c
            if (c == "[" || c == "{") nesting++
            if (c == "]" || c == "}") nesting--
            if (c == "\"" || c == apostrophe) {
                quote = c
                if (three == c c c) { quote = three; out = out c c; i += 2 }
            }
        }
    }
    return out
}
{
    lines[NR] = $0
    if (NR == 1 && $0 ~ /\r$/) ending = "\r"
    opaque = (quote != "" || nesting > 0)
    line = $0; sub(/\r$/, "", line)
    code = scan(line)
    if (opaque) next
    if (code ~ /^[ \t]*\[/) {
        section = "other"
        for (t = 1; t <= 2; t++) {
            table = tables[t]
            if (code ~ "^[ \t]*\\[[ \t]*" name_pattern(table) "[ \t]*\\][ \t]*$") {
                section = table
                if (header[table]) unsafe = 1
                header[table] = NR
            }
        }
        # Les noms échappés peuvent être équivalents à desktop ou tui : ne pas deviner.
        if (code ~ /\\/) unsafe = 1
        next
    }
    # Une table définie par clé pointée ou inline ne peut pas être redéfinie par [table].
    if (section == "") {
        for (t = 1; t <= 2; t++)
            if (code ~ "^[ \t]*" name_pattern(tables[t]) "[ \t]*[.=]") unsafe = 1
        assignment = code; sub(/=.*/, "", assignment)
        if (assignment ~ /\\/) unsafe = 1
    }
    if (section != "desktop" && section != "tui") next
    for (k = 1; k <= count[section]; k++) {
        if (code ~ "^[ \t]*" name_pattern(key[section, k]) "[ \t]*=") present[section, k] = 1
    }
    # Même prudence pour les noms de clés TOML échappés.
    assignment = code; sub(/=.*/, "", assignment)
    if (assignment ~ /\\/) unsafe = 1
}
function defaults(table,    k) {
    for (k = 1; k <= count[table]; k++)
        if (!present[table, k]) print key[table, k] " = " value[table, k] ending
}
END {
    if (unsafe || quote != "" || nesting != 0) exit 2
    for (n = 1; n <= NR; n++) {
        print lines[n]
        for (t = 1; t <= 2; t++) if (header[tables[t]] == n) defaults(tables[t])
    }
    for (t = 1; t <= 2; t++) {
        table = tables[t]
        if (!header[table]) {
            if (NR || t > 1) print ending
            print "[" table "]" ending
            defaults(table)
        }
    }
}
