# lib/exec_print.sh — the print executor (--dry-run listing, `spore plan`).

exec_print() {
    awk -F'\t' '
        { by_mod[$1] = by_mod[$1] sprintf("    %-10s %s\n", $2, describe($0)) }
        function describe(line,   f) {
            split(line, f, "\t")
            if (f[2] == "pkg")       return f[3]
            if (f[2] == "dir")       return f[3] " (" f[4] ")"
            if (f[2] == "file")      return f[3] " (" f[4] ", " f[5] ")"
            if (f[2] == "svc")       return f[3] " -> " f[4] " [" f[5] "]"
            if (f[2] == "blob")      return f[3] " -> " f[6]
            if (f[2] == "firstboot") return f[3]
            if (f[2] == "bootstrap") return f[3]
            if (f[2] == "persist")   return f[3]
            return f[3]
        }
        END {
            n = asorti_fallback(by_mod, keys)
            for (i = 1; i <= n; i++) { printf "  %s\n", keys[i]; printf "%s", by_mod[keys[i]] }
        }
        function asorti_fallback(arr, out,   k, n, i, j, t) {
            n = 0
            for (k in arr) out[++n] = k
            for (i = 1; i < n; i++) for (j = i + 1; j <= n; j++)
                if (out[i] > out[j]) { t = out[i]; out[i] = out[j]; out[j] = t }
            return n
        }
    ' "$SPORE_PLAN"
}
