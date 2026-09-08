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
