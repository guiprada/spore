# lib/render.sh — config file rendering.
#
# Priority when touching an existing config: a drop-in directory if the package
# supports one, otherwise a block this tool owns. Never a blind sed.

SPORE_MARK_BEGIN='# BEGIN spore'
SPORE_MARK_END='# END spore'

# render_marked_block <path> <marker> <content>
# Prints the full new file: existing content with any previous block of the same
# marker stripped, then the block appended. Re-rendering an unchanged block
# reproduces the file byte for byte, which is what makes it idempotent.
render_marked_block() {
    rmb_path=$1 rmb_marker=$2 rmb_content=$3
    rmb_begin="$SPORE_MARK_BEGIN:$rmb_marker"
    rmb_end="$SPORE_MARK_END:$rmb_marker"
    rmb_real=$(rootpath "$rmb_path")

    if [ -f "$rmb_real" ]; then
        awk -v b="$rmb_begin" -v e="$rmb_end" '
            $0 == b { skip = 1 }
            !skip   { print }
            $0 == e { skip = 0 }
        ' "$rmb_real"
    fi
    printf '%s\n%s\n%s\n' "$rmb_begin" "$rmb_content" "$rmb_end"
}

# Alpine patches `Include /etc/ssh/sshd_config.d/*.conf` in near the TOP of
# sshd_config (include-config-dir.patch), and OpenSSH takes the first value it
# sees for a directive — so a drop-in overrides the main file rather than being
# overridden by it. That makes the drop-in branch the correct one on Alpine; the
# marked-block fallback is for anything that ships without the patch.
sshd_include_supported() {
    ssi_f=$(rootpath /etc/ssh/sshd_config)
    [ -f "$ssi_f" ] &&
        grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$ssi_f"
}

# render_iface_resolve <name> [where-it-is-configured]
# Prints shell that leaves $iface holding a real interface name on the target.
#
# An interface name is the one piece of a spore that cannot be known in advance:
# predictable naming gives eth0 on one box and enp3s0 on the next. `auto` defers
# the choice to the machine — preferring eth0 when it exists, so a spore that
# used to name it explicitly keeps getting it. Any other name is checked here,
# because a name that does not exist means no network at all, forever, on a
# machine nobody is standing in front of, and it surfaces three layers later as
# a mirror that will not resolve rather than as the one wrong word it is.
render_iface_resolve() {
    printf "iface='%s'\nifacekey='%s'\n" \
        "$1" "${2:-NET_IFACE in modules/net.conf}"
    cat <<'RIR'
if [ "$iface" = auto ]; then
    if [ -e /sys/class/net/eth0 ]; then
        iface=eth0
    else
        iface=$(for i in /sys/class/net/*; do
            n=${i##*/}
            [ "$n" = lo ] || printf '%s\n' "$n"
        done | head -1)
    fi
    if [ -z "$iface" ]; then
        echo 'spore: this machine has no network interface other than loopback.' >&2
        exit 1
    fi
    echo "spore: using interface $iface"
fi
if [ ! -e "/sys/class/net/$iface" ]; then
    echo "spore: this machine has no interface named '$iface'. It has:" >&2
    for i in /sys/class/net/*; do
        n=${i##*/}
        [ "$n" = lo ] || echo "spore:   $n" >&2
    done
    echo "spore: set $ifacekey to one of those, or to auto to take" >&2
    echo 'spore: whichever one this machine turns out to have.' >&2
    exit 1
fi
RIR
}
