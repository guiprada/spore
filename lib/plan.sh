# lib/plan.sh — the plan.
#
# A plan is a TSV file: <module> <action> <fields...>. It is pure data: the
# planner performs no I/O against the target system and needs no root. Executors
# consume it. That split is why `build` (a staging executor + tar) is later a
# backend rather than a rewrite.
#
# Actions:
#   pkg       <name>
#   blob      <name> <url> <sha256> <dest> <mode> <member>
#   dir       <path> <mode>
#   file      <path> <mode> <owner> <sha256>
#   svc       <name> <runlevel> <on|off>
#   firstboot <id> <sha256>            deferred: run now (apply) / emit to
#                                      /etc/local.d (build)
#   persist   <path>

# Execution order, applied as separate passes so ordering never depends on the
# order modules happened to emit in. `persist` is absent on purpose: it is a
# declaration consumed by the `persist` verb, not work done at apply time.
SPORE_ACTION_ORDER='pkg blob dir file svc firstboot'

plan_reset() { : > "$SPORE_PLAN"; }

# stdin -> content store, prints the sha256
content_put() {
    cp_tmp=$SPORE_WORK/.put.$$
    cat > "$cp_tmp"
    cp_sha=$(sha256_file "$cp_tmp")
    mv -f "$cp_tmp" "$SPORE_WORK/content/$cp_sha"
    printf '%s' "$cp_sha"
}

content_path() { printf '%s' "$SPORE_WORK/content/$1"; }

_emit() { printf '%s\t%s\n' "${SPORE_MOD:-spore}" "$(printf '%s\t' "$@" | sed 's/\t$//')" >> "$SPORE_PLAN"; }

plan_pkg()     { _emit pkg "$1"; }
plan_dir()     { _emit dir "$1" "${2:-0755}"; }
plan_svc()     { _emit svc "$1" "${2:-default}" "${3:-on}"; }
plan_persist() { _emit persist "$1"; }

# plan_file <path> [mode] <content> [owner]
plan_file() {
    pf_path=$1 pf_mode=${2:-0644} pf_content=$3 pf_owner=${4:-root:root}
    pf_sha=$(printf '%s\n' "$pf_content" | content_put)
    _emit file "$pf_path" "$pf_mode" "$pf_owner" "$pf_sha"
}

# plan_file_from <path> [mode] <srcfile> [owner]
plan_file_from() {
    pff_path=$1 pff_mode=${2:-0644} pff_src=$3 pff_owner=${4:-root:root}
    pff_sha=$(content_put < "$pff_src")
    _emit file "$pff_path" "$pff_mode" "$pff_owner" "$pff_sha"
}

plan_firstboot() {
    pfb_id=$1 pfb_script=$2
    pfb_sha=$(printf '%s\n' "$pfb_script" | content_put)
    _emit firstboot "$pfb_id" "$pfb_sha"
}

# plan_blob <name> — resolved against blobs.conf for the target arch at plan time,
# so the emitted action is fully self-contained.
plan_blob() {
    pb_name=$1
    pb_row=$(blob_lookup "$pb_name" "$(fact_arch)") ||
        die "no blob '$pb_name' for arch $(fact_arch) in blobs.conf"
    # shellcheck disable=SC2086
    set -- $pb_row
    _emit blob "$pb_name" "$1" "$2" "$3" "$4" "$5"
    plan_persist "$3"
}

# --- reading -----------------------------------------------------------------

plan_lines_of_type() { awk -F'\t' -v t="$1" '$2 == t' "$SPORE_PLAN"; }
plan_lines_of_module() { awk -F'\t' -v m="$1" '$1 == m' "$SPORE_PLAN"; }
plan_modules() { awk -F'\t' '{ print $1 }' "$SPORE_PLAN" | sort -u; }
plan_count() { wc -l < "$SPORE_PLAN" | tr -d ' '; }

# Paths a module owns, derived from its file/dir actions so it can never drift
# out of sync with what the module actually writes.
plan_owned_paths() {
    awk -F'\t' -v m="$1" '$1 == m && ($2 == "file" || $2 == "dir") { print $3 }' "$SPORE_PLAN"
}

plan_persist_paths() { awk -F'\t' '$2 == "persist" { print $3 }' "$SPORE_PLAN"; }

plan_all_owned_paths() {
    awk -F'\t' '$2 == "file" || $2 == "dir" { print $3 }' "$SPORE_PLAN" | sort -u
}

# Planner-side notes: things the operator should know that are not actions.
plan_note()       { printf '%s\n' "$*" >> "$SPORE_WORK/notes"; }
plan_notes_show() {
    [ -s "$SPORE_WORK/notes" ] || return 0
    printf '\n' >&2
    while read -r pn_l; do printf '  %s%s%s\n' "$_c_yellow" "$pn_l" "$_c_reset" >&2; done < "$SPORE_WORK/notes"
}

# Two modules writing the same path is always a bug — the winner would depend on
# emit order, and modes would silently disagree. A pure plan makes this cheap to
# catch, so catch it rather than letting last-writer-wins decide.
plan_validate() {
    awk -F'\t' '
        $2 == "file" || $2 == "dir" {
            if ($3 in owner && owner[$3] != $1)
                printf "%s\t%s\t%s\n", $3, owner[$3], $1
            else if ($3 in owner)
                printf "%s\t%s\t%s\n", $3, owner[$3], $1
            owner[$3] = $1
        }
    ' "$SPORE_PLAN" | sort -u > "$SPORE_WORK/conflicts"

    [ -s "$SPORE_WORK/conflicts" ] || return 0
    while IFS="$SPORE_TAB" read -r pv_path pv_a pv_b; do
        warn "$pv_path is claimed by both '$pv_a' and '$pv_b'"
    done < "$SPORE_WORK/conflicts"
    die "conflicting claims in the plan; resolve them before applying"
}
