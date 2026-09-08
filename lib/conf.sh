# lib/conf.sh — KEY=VALUE reader.
#
# Parsed, never sourced. Sourcing a spore would be arbitrary code execution and
# would make validation impossible.

conf_get() {
    conf_file=$1
    conf_key=$2
    conf_def=${3-}

    case $conf_key in
        ''|*[!A-Za-z0-9_]*) die "invalid config key: $conf_key" ;;
    esac

    if [ ! -f "$conf_file" ]; then
        printf '%s' "$conf_def"
        return 0
    fi

    conf_val=$(sed -n "s/^[[:space:]]*${conf_key}[[:space:]]*=[[:space:]]*//p" "$conf_file" \
               | sed 's/[[:space:]]*$//' | tail -n 1)

    if [ -z "$conf_val" ]; then
        printf '%s' "$conf_def"
        return 0
    fi

    case $conf_val in
        \"*\") conf_val=${conf_val#\"}; conf_val=${conf_val%\"} ;;
        \'*\') conf_val=${conf_val#\'}; conf_val=${conf_val%\'} ;;
    esac

    printf '%s' "$conf_val"
}

conf_has() {
    [ -f "$1" ] && grep -q "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null
}

# Truthiness for yes/no style keys.
conf_bool() {
    case $(conf_get "$1" "$2" "$3") in
        yes|true|1|on) return 0 ;;
        *) return 1 ;;
    esac
}
