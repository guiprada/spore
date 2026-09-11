# modules/system.sh — keyboard layout and timezone.
#
# Both are set through Alpine's own setup-keymap and setup-timezone rather than
# by writing their files here. The layouts live in a package that has to be
# fetched, the keymap is a compressed binary rather than text, and where either
# lands has moved between releases — so reimplementing them would be guessing at
# a format on a machine we cannot see, to save calling a tool that is already
# installed and already correct.

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
        # Given only a layout, setup-keymap asks the machine which variant it
        # wants — and on a box that is booting itself nobody answers, so it
        # reads EOF and asks again, for ever, with no console to say so on.
        #
        # Rather than refuse, which fails a whole apply over a keyboard, the
        # layout becomes its own variant. That is all `us us` ever was, and a
        # layout named twice is a real answer to that prompt, so the machine
        # gets a keymap instead of a hang either way.
        sy_n=0
        for sy_w in $sy_keymap; do sy_n=$((sy_n + 1)); done
        case $sy_n in
            1)  sy_keymap="$sy_keymap $sy_keymap"
                plan_note "system: SYSTEM_KEYMAP named a layout and no variant, so
         '$sy_keymap' is used. Name the variant — 'br br-abnt2' — if that is
         not the one you meant." ;;
            2)  : ;;
            *)  die "system: SYSTEM_KEYMAP is '<layout> <variant>' — 'br br-abnt2',
        'us us', 'de de-nodeadkeys'. Got '$sy_keymap'." ;;
        esac
        plan_pkg kbd-bkeymaps
        # And stdin closed anyway, so a version of alpine-conf that asks
        # something we did not anticipate fails rather than hanging the boot.
        plan_firstboot system-keymap "if ! command -v setup-keymap >/dev/null 2>&1; then
    echo 'spore: setup-keymap is missing (alpine-conf); cannot set the keymap' >&2
    exit 1
fi
setup-keymap $sy_keymap < /dev/null"
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
setup-ntp $sy_ntp < /dev/null"
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
setup-timezone -z '$sy_tz' < /dev/null"
    fi
}
