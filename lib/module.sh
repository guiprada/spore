# lib/module.sh — module loading and the planner.
#
# Modules emit actions; they never act. Because the plan is pure data, `status`,
# `diff` and `remove` are generic over it and modules do not implement them.

module_path()   { printf '%s/%s.sh' "$SPORE_MODULES" "$1"; }
module_exists() { [ -f "$(module_path "$1")" ]; }

module_load() {
    module_exists "$1" || die "unknown module: $1"
    . "$(module_path "$1")"
}

# Read a key from the current module's own conf file.
mconf()      { conf_get  "$SPORE_DIR/modules/$SPORE_MOD.conf" "$1" "${2-}"; }
mconf_bool() { conf_bool "$SPORE_DIR/modules/$SPORE_MOD.conf" "$1" "${2-}"; }

module_meta() {
    MOD_DESC='' MOD_REQUIRES='' MOD_DATA='' MOD_PORTS='' MOD_LOGINS=''
    MOD_ROOT_PASSWORD=no
    SPORE_MOD=$1
    "${1}_meta"
}

module_available() {
    find "$SPORE_MODULES" -maxdepth 1 -name '*.sh' -type f -exec basename {} .sh \; | sort
}

# --- the planner -------------------------------------------------------------
#
# Pure: touches nothing on the target, needs no root, and runs anywhere.

plan_build() {
    plan_reset
    : > "$SPORE_WORK/skipped"
    SPORE_ALL_PORTS=''
    SPORE_ALL_LOGINS=''
    # Whether the spore itself will give root a password. Not the same question
    # as whether root has one now: a stock Alpine boots without one, which is
    # fine — it only stops being fine once something lets the network at it.
    SPORE_ROOT_PASSWORD=no

    for pb_m in $SPORE_MODULE_LIST; do
        module_load "$pb_m"
    done

    # Pass 1 — metadata and requirements. Ports are collected here so the
    # firewall module can plan against what every other module declared.
    for pb_m in $SPORE_MODULE_LIST; do
        module_meta "$pb_m"
        pb_unmet=$(requirement_unmet "$MOD_REQUIRES")
        if [ -n "$pb_unmet" ]; then
            printf '%s\t%s\n' "$pb_m" "$pb_unmet" >> "$SPORE_WORK/skipped"
            continue
        fi
        SPORE_ALL_PORTS="$SPORE_ALL_PORTS $MOD_PORTS"
        SPORE_ALL_LOGINS="$SPORE_ALL_LOGINS $MOD_LOGINS"
        if [ "$MOD_ROOT_PASSWORD" = yes ]; then SPORE_ROOT_PASSWORD=yes; fi
    done

    # Pass 2 — emit actions.
    for pb_m in $SPORE_MODULE_LIST; do
        if module_is_skipped "$pb_m"; then continue; fi
        module_meta "$pb_m"
        SPORE_MOD=$pb_m
        "${pb_m}_plan"
    done

    SPORE_MOD=spore
    plan_spore_packages
    plan_spore_files

    # Secrets are decrypted on the target, so age has to be there first —
    # from the medium if `spore install` put it there, from a mirror only as a
    # fallback. The bootstrap pass runs before the secret pass.
    if [ -s "$SPORE_PLAN" ] && awk -F'\t' '$2 == "secret" { found = 1 } END { exit !found }' "$SPORE_PLAN"; then
        plan_age
    fi

    # Blobs are fetched over HTTPS by curl/wget, which need a CA trust store. A
    # freshly booted Alpine often has none — apk carries its own, so package
    # installs succeed and the first blob fetch then fails with "unable to get
    # local issuer certificate", which reads like a network fault rather than a
    # missing package.
    if [ -s "$SPORE_PLAN" ] && awk -F'\t' '$2 == "blob" { found = 1 } END { exit !found }' "$SPORE_PLAN"; then
        plan_pkg ca-certificates-bundle
    fi

    plan_validate
}

module_is_skipped() { awk -F'\t' -v m="$1" '$1 == m { f = 1 } END { exit !f }' "$SPORE_WORK/skipped"; }
module_skip_reason() { awk -F'\t' -v m="$1" '$1 == m { print $2; exit }' "$SPORE_WORK/skipped"; }

plan_spore_packages() {
    [ -f "$SPORE_DIR/packages" ] || return 0
    while read -r psp_line; do
        case $psp_line in ''|\#*) continue ;; esac
        plan_pkg "$psp_line"
    done < "$SPORE_DIR/packages"
}

# The literal overlay tree: files/ mirrors /.
plan_spore_files() {
    [ -d "$SPORE_DIR/files" ] || return 0
    find "$SPORE_DIR/files" -type f | sort > "$SPORE_WORK/files.list"
    while read -r psf_src; do
        [ -n "$psf_src" ] || continue
        psf_rel=${psf_src#"$SPORE_DIR/files"}
        psf_mode=$(stat -c '%a' "$psf_src" 2>/dev/null || echo 644)
        plan_file_from "$psf_rel" "0$psf_mode" "$psf_src"
    done < "$SPORE_WORK/files.list"
}
