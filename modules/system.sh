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
        plan_pkg kbd-bkeymaps
        plan_firstboot system-keymap "if ! command -v setup-keymap >/dev/null 2>&1; then
    echo 'spore: setup-keymap is missing (alpine-conf); cannot set the keymap' >&2
    exit 1
fi
setup-keymap $sy_keymap"
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
