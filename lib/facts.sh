# lib/facts.sh — host probing.
#
# Every fact is overridable via SPORE_FACT_* so the planner and executor can be
# driven through host shapes that don't exist on this machine (tests).

fact_arch() { printf '%s' "${SPORE_FACT_ARCH:-$(uname -m)}"; }

fact_root() {
    if [ -n "${SPORE_FACT_ROOT:-}" ]; then printf '%s' "$SPORE_FACT_ROOT"; return 0; fi
    if [ "$(id -u)" = 0 ]; then printf yes; else printf no; fi
}

fact_init() {
    if [ -n "${SPORE_FACT_INIT:-}" ]; then printf '%s' "$SPORE_FACT_INIT"; return 0; fi
    if command -v rc-update >/dev/null 2>&1; then printf openrc; else printf none; fi
}

# Diskless is the case that matters: root on tmpfs AND lbu present.
fact_persist() {
    if [ -n "${SPORE_FACT_PERSIST:-}" ]; then printf '%s' "$SPORE_FACT_PERSIST"; return 0; fi
    if command -v lbu >/dev/null 2>&1 &&
       awk '$2 == "/" && $3 == "tmpfs" { found = 1 } END { exit !found }' /proc/mounts 2>/dev/null
    then
        printf lbu
    else
        printf rootfs
    fi
}

# CAP_NET_ADMIN is bit 12 of CapEff, i.e. the low bit of the 4th hex digit from
# the right. Tested on the hex string directly to avoid depending on shell
# arithmetic width or on awk's strtonum (absent from busybox awk).
fact_netadmin() {
    if [ -n "${SPORE_FACT_NETADMIN:-}" ]; then printf '%s' "$SPORE_FACT_NETADMIN"; return 0; fi

    capeff=$(awk '/^CapEff:/ { print $2; exit }' /proc/self/status 2>/dev/null || true)
    if [ -z "$capeff" ] || [ "${#capeff}" -lt 4 ]; then printf no; return 0; fi

    nibble=$(printf '%s' "$capeff" | sed 's/.*\(.\)...$/\1/')
    case $nibble in
        [13579bdfBDF]) printf yes ;;
        *)             printf no ;;
    esac
}

# The CA trust store. apk carries its own, so this can be broken while package
# installs still work — and then git, curl and every blob fetch fail with
# "unable to get local issuer certificate", which reads like a network fault.
# Note that `update-ca-certificates` regenerates the bundle from
# /usr/share/ca-certificates, so it can leave it EMPTY rather than absent.
fact_ca_store() {
    if [ -n "${SPORE_FACT_CA_STORE:-}" ]; then printf '%s' "$SPORE_FACT_CA_STORE"; return 0; fi
    fcs_b=/etc/ssl/certs/ca-certificates.crt
    if [ ! -f "$fcs_b" ]; then
        printf missing
    elif [ ! -s "$fcs_b" ] || ! grep -q 'BEGIN CERTIFICATE' "$fcs_b" 2>/dev/null; then
        printf empty
    else
        printf ok
    fi
}

# Where `lbu commit` will actually write. LBU_BACKUPDIR wins outright and skips
# mounting; otherwise the destination is /media/$LBU_MEDIA. Worth reporting
# because a read-only boot medium with the apkovl on a separate data partition is
# a good design — the initramfs finds it by scanning devices, so nothing has to
# be written to the medium the system booted from.
fact_lbu_dest() {
    if [ -n "${SPORE_FACT_LBU_DEST:-}" ]; then printf '%s' "$SPORE_FACT_LBU_DEST"; return 0; fi
    fld_c=/etc/lbu/lbu.conf
    fld_dir=$(conf_get "$fld_c" LBU_BACKUPDIR '')
    if [ -n "$fld_dir" ]; then printf '%s' "$fld_dir"; return 0; fi
    fld_media=$(conf_get "$fld_c" LBU_MEDIA '')
    if [ -n "$fld_media" ]; then printf '/media/%s' "$fld_media"; return 0; fi
    printf 'unset'
}

fact_alpine() {
    if [ -n "${SPORE_FACT_ALPINE:-}" ]; then printf '%s' "$SPORE_FACT_ALPINE"; return 0; fi
    if [ -f /etc/alpine-release ]; then cat /etc/alpine-release; else printf none; fi
}

facts_show() {
    printf 'arch      %s\n' "$(fact_arch)"
    printf 'root      %s\n' "$(fact_root)"
    printf 'init      %s\n' "$(fact_init)"
    printf 'persist   %s\n' "$(fact_persist)"
    printf 'netadmin  %s\n' "$(fact_netadmin)"
    printf 'ca store  %s\n' "$(fact_ca_store)"
    if [ "$(fact_persist)" = lbu ]; then
        printf 'apkovl to %s\n' "$(fact_lbu_dest)"
    fi
    printf 'alpine    %s\n' "$(fact_alpine)"
}

# Returns the first unmet requirement, or nothing when all are satisfied.
requirement_unmet() {
    for req in $1; do
        case $req in
            init.openrc) [ "$(fact_init)"     = openrc ] || { printf '%s' "$req"; return 0; } ;;
            net.admin)   [ "$(fact_netadmin)" = yes ]    || { printf '%s' "$req"; return 0; } ;;
            boot.media)  [ "$(fact_persist)"  = lbu ]    || { printf '%s' "$req"; return 0; } ;;
            root)        [ "$(fact_root)"     = yes ]    || { printf '%s' "$req"; return 0; } ;;
            '') : ;;
            *) printf '%s' "$req"; return 0 ;;
        esac
    done
    return 0
}

requirement_reason() {
    case $1 in
        init.openrc) printf 'no OpenRC' ;;
        net.admin)   printf 'no NET_ADMIN' ;;
        boot.media)  printf 'not diskless' ;;
        root)        printf 'not root' ;;
        *)           printf 'unknown requirement %s' "$1" ;;
    esac
}
