# modules/system.sh — keyboard layout and timezone.
#
# The timezone and the time client go through Alpine's own setup-* tools. The
# keymap does not, and that is deliberate: setup-keymap prompts whenever the
# pair it is given does not match a file, and its prompt cannot be answered on
# a machine that is booting itself — it loops on EOF instead, for ever. See
# render_keymap, which does the five lines that tool does once it has a valid
# pair, and reports the ones that exist when it does not.

system_meta() {
    MOD_DESC='keyboard layout and timezone'
    MOD_REQUIRES='root'
}

system_plan() {
    # "<layout> <variant>", as setup-keymap takes them: `br br-abnt2`, `us us`.
    sy_keymap=$(mconf SYSTEM_KEYMAP '')
    if [ -n "$sy_keymap" ]; then
        case $sy_keymap in
            *[!A-Za-z0-9_\ -]*) die "system: SYSTEM_KEYMAP may only contain letters, digits, - and _" ;;
        esac
        # A layout on its own uses itself as its variant, which is all `us us`
        # ever was. A pair that does not exist is now a message naming the ones
        # that do, rather than a question nobody is there to answer.
        sy_n=0
        for sy_w in $sy_keymap; do sy_n=$((sy_n + 1)); done
        case $sy_n in
            1)  sy_keymap="$sy_keymap $sy_keymap" ;;
            2)  : ;;
            *)  die "system: SYSTEM_KEYMAP is '<layout> <variant>' — 'br br-abnt2',
        'us us', 'de de-nodeadkeys'. Got '$sy_keymap'." ;;
        esac
        plan_pkg kbd-bkeymaps
        plan_firstboot system-keymap "$(render_keymap "${sy_keymap%% *}" "${sy_keymap##* }")"
    fi

    # A diskless box with no battery-backed clock comes up in 1970, and a clock
    # that far out makes every HTTPS certificate look not-yet-valid. setup-alpine
    # asks for this for the same reason.
    sy_ntp=$(mconf SYSTEM_NTP '')
    if [ -n "$sy_ntp" ] && [ "$sy_ntp" != none ]; then
        case $sy_ntp in
            chrony|busybox|openntpd) : ;;
            *) die "system: SYSTEM_NTP is chrony, busybox, openntpd or none — not '$sy_ntp'" ;;
        esac
        # setup-ntp's last line is `rc-service $svc start`, so its exit status
        # is that start's — and started from inside a service in the default
        # runlevel, OpenRC refuses anything whose dependencies belong to an
        # earlier one: "cannot start chronyd as fsck would not start". The
        # daemon is configured correctly and the whole apply dies anyway.
        #
        # Everything before that line is deterministic: a one-shot sync so the
        # clock is right now, and a package. The service belongs to spore's own
        # svc pass, which enables it and treats starting as best-effort.
        case $sy_ntp in
            chrony)   sy_pkg=chrony   sy_svc=chronyd  ;;
            openntpd) sy_pkg=openntpd sy_svc=openntpd ;;
            busybox)  sy_pkg=''       sy_svc=ntpd     ;;
        esac
        [ -z "$sy_pkg" ] || plan_pkg "$sy_pkg"
        plan_svc "$sy_svc" default on
        # Before anything reaches for a certificate. A box with no battery-backed
        # clock boots in 1970, where everything looks not-yet-valid — which is
        # why this is a step of its own and not just the daemon's job later.
        plan_firstboot system-ntp "if command -v busybox >/dev/null 2>&1; then
    if busybox ntpd -qnN -p pool.ntp.org >/dev/null 2>&1; then
        echo \"spore: clock set to \$(date 2>/dev/null)\"
    else
        echo 'spore: could not reach pool.ntp.org to set the clock now.' >&2
        echo \"spore: $sy_svc is enabled and will correct it once the network is up.\" >&2
    fi
fi"
    fi

    sy_tz=$(mconf SYSTEM_TIMEZONE '')
    if [ -n "$sy_tz" ]; then
        case $sy_tz in
            *[!A-Za-z0-9_/+-]*) die "system: SYSTEM_TIMEZONE is a zone name like America/Sao_Paulo" ;;
        esac
        plan_pkg tzdata
        plan_firstboot system-timezone "if ! command -v setup-timezone >/dev/null 2>&1; then
    echo 'spore: setup-timezone is missing (alpine-conf); cannot set the timezone' >&2
    exit 1
fi
setup-timezone -z '$sy_tz'"
    fi
}
