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
#   secret    <path> <mode> <owner> <sha256>   template with @@SECRET:name@@
#                                              markers; plaintext never enters
#                                              the plan
#   svc       <name> <runlevel> <on|off>
#   bootstrap <id> <sha256>            runs BEFORE packages (enabling a repo,
#                                      pointing the apk cache at real media)
#   firstboot <id> <sha256>            deferred: run now (apply) / emit to
#                                      /etc/local.d (build)
#   persist   <path>

# Execution order, applied as separate passes so ordering never depends on the
# order modules happened to emit in. Services come last: the accounts they run
# as, the capabilities they need, the volumes they serve and the keys they
# present are all firstboot work, and starting a service before that exists
# fails in ways that look like the service is broken. `persist` is absent on purpose: it is a
# declaration consumed by the `persist` verb, not work done at apply time.
# netup before bootstrap, and both before packages. Bringing the interface up is
# not just another bootstrap step: bootstrap actions run in the order modules
# were listed, so `repos` ahead of `net` in MODULES put `apk update` before the
# machine had an address. That fails as a DNS error, which reads as a bad mirror
# rather than as a machine with no network — and it depends on the order of a
# line in a config file, which is no way to decide whether a box can reach the
# internet.
SPORE_ACTION_ORDER='netup bootstrap pkg blob dir file secret firstboot svc'

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

# plan_secret_file <path> [mode] <template-with-markers> [owner]
plan_secret_file() {
    psf_path=$1 psf_mode=${2:-0600} psf_tpl=$3 psf_owner=${4:-root:root}
    psf_sha=$(printf '%s\n' "$psf_tpl" | content_put)
    _emit secret "$psf_path" "$psf_mode" "$psf_owner" "$psf_sha"
}

# plan_secret <path> [mode] <secret-name> [owner] — the secret IS the file.
plan_secret() {
    plan_secret_file "$1" "${2:-0600}" "@@SECRET:$3@@" "${4:-root:root}"
}

plan_firstboot() {
    pfb_id=$1 pfb_script=$2
    pfb_sha=$(printf '%s\n' "$pfb_script" | content_put)
    _emit firstboot "$pfb_id" "$pfb_sha"
}

# Same shape as firstboot, but executed before any package is installed.
plan_bootstrap() {
    pbs_id=$1 pbs_script=$2
    pbs_sha=$(printf '%s\n' "$pbs_script" | content_put)
    _emit bootstrap "$pbs_id" "$pbs_sha"
}

# Same shape as a bootstrap action, but in the phase before it: whatever has to
# be true before anything reaches the network.
plan_netup() {
    pnu_id=$1 pnu_script=$2
    pnu_sha=$(printf '%s\n' "$pnu_script" | content_put)
    _emit netup "$pnu_id" "$pnu_sha"
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
    awk -F'\t' -v m="$1" '$1 == m && ($2 == "file" || $2 == "dir" || $2 == "secret") { print $3 }' "$SPORE_PLAN"
}

plan_persist_paths() { awk -F'\t' '$2 == "persist" { print $3 }' "$SPORE_PLAN"; }

plan_all_owned_paths() {
    awk -F'\t' '$2 == "file" || $2 == "dir" || $2 == "secret" { print $3 }' "$SPORE_PLAN" | sort -u
}

# Planner-side notes: things the operator should know that are not actions.
plan_note()       { printf '%s\n' "$*" >> "$SPORE_WORK/notes"; }
plan_notes_show() {
    [ -s "$SPORE_WORK/notes" ] || return 0
    printf '\n' >&2
    while read -r pn_l; do printf '  %s%s%s\n' "$_c_yellow" "$pn_l" "$_c_reset" >&2; done < "$SPORE_WORK/notes"
}

# Two modules writing the same *file* is always a bug — the winner would depend
# on emit order and the modes could silently disagree. Two modules wanting the
# same *directory* to exist is not a bug, it is agreement; that is only a
# conflict when they disagree about its mode. A pure plan makes both cheap to
# check, so check rather than letting last-writer-wins decide.
plan_validate() {
    awk -F'\t' '
        $2 == "file" || $2 == "secret" || $2 == "dir" {
            path = $3; mode = $4
            kind = ($2 == "dir") ? "dir" : "content"
            if (path in seen) {
                if (kind != "dir" || seen[path] != "dir")
                    printf "%s\t%s\t%s\t%s\n", path, owner[path], $1, "written by both"
                else if (mode_of[path] != mode)
                    printf "%s\t%s\t%s\t%s\n", path, owner[path], $1,
                        "created with mode " mode_of[path] " and " mode
            }
            seen[path] = kind; mode_of[path] = mode; owner[path] = $1
        }
    ' "$SPORE_PLAN" | sort -u > "$SPORE_WORK/conflicts"

    [ -s "$SPORE_WORK/conflicts" ] || return 0
    while IFS="$SPORE_TAB" read -r pv_path pv_a pv_b pv_why; do
        warn "$pv_path: $pv_why ('$pv_a' and '$pv_b')"
    done < "$SPORE_WORK/conflicts"
    die "conflicting claims in the plan; resolve them before applying"
}

# plan_age
# age has to exist on the target before any sealed secret can be opened, and
# `apk add age` is the wrong way to get it: it needs a working mirror, and the
# machine that most needs an unattended password is the one whose network is
# not up yet. `spore install` puts the binary on the medium for exactly this,
# so look there first and fall back to the package.
#
# Bootstrap, not pkg: it must be in place before the secret pass, and the whole
# point is that it must not depend on the package pass working at all.
plan_age() {
    # shellcheck disable=SC2016  # the target's shell expands these, not ours
    plan_bootstrap age-available 'if command -v age >/dev/null 2>&1; then
    exit 0
fi
for b in /media/*/spore-bin/age /mnt/*/spore-bin/age; do
    [ -f "$b" ] || continue
    mkdir -p /usr/local/bin
    cp "$b" /usr/local/bin/age || continue
    chmod 755 /usr/local/bin/age
    if age --version >/dev/null 2>&1; then
        echo "spore: using the age carried on the boot medium"
        exit 0
    fi
    rm -f /usr/local/bin/age
done
if apk add --no-progress age; then
    exit 0
fi
echo "spore: age is not installed and could not be fetched, so no sealed" >&2
echo "spore: secret can be opened — no password will be set on this machine." >&2
echo "spore: Re-run spore install on a workstation with a network and it will" >&2
echo "spore: carry the binary on the medium instead of needing one here." >&2
exit 1'
}
