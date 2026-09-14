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
        plan_firstboot system-ntp "if ! command -v setup-ntp >/dev/null 2>&1; then
    echo 'spore: setup-ntp is missing (alpine-conf); cannot set up time sync' >&2
    exit 1
fi
setup-ntp $sy_ntp"
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
