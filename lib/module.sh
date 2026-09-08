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
    MOD_DESC='' MOD_REQUIRES='' MOD_DATA='' MOD_PORTS=''
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
