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
# render_iface_resolve <name> [where-it-is-configured] [seconds-to-wait]
# Prints shell that leaves $iface holding a real interface name on the target,
# or empty if there is none — having already said, on the console and in the
# log, what it looked for and what it found.
#
# Two different things go wrong here and from a distance they look identical.
#
# The name can be wrong. Predictable naming gives eth0 on one box and enp3s0 on
# the next, and a spore is written on a workstation for a machine that is not in
# front of you, so the interface name is the one piece of it that cannot be
# known from there. `auto` exists for that.
#
# Or the name can be right and simply not there yet. A network card is not
# present the moment userspace starts: its driver is loaded by coldplug and
# probes asynchronously, so a machine booting off USB can reach the default
# runlevel first and lose the race. That reads as
#
#     ip: ioctl 0x8913 failed: No such device
#     ifup: failed to change interface eth0 state to 'up'
#
# — SIOCGIFFLAGS, *get* flags, returning ENODEV — and by the time anyone is at
# the console the interface has appeared and the message has become a lie. So
# ask for the drivers, then wait, rather than believing the first look. Both
# cases end with the list of what was actually there, because that one line is
# the difference between a five-minute fix and another boot spent guessing.
render_iface_resolve() {
    printf "iface='%s'\nifacekey='%s'\nifacewait=%s\n" \
        "$1" "${2:-NET_IFACE in modules/net.conf}" "${3:-30}"
    cat <<'RIR'
spore_ifaces() {
    for i in /sys/class/net/*; do
        [ -e "$i" ] || continue
        n=${i##*/}
        if [ "$n" != lo ]; then printf '%s\n' "$n"; fi
    done
}

if command -v udevadm >/dev/null 2>&1; then
    udevadm trigger --subsystem-match=net >/dev/null 2>&1 || true
    udevadm settle --timeout=10 >/dev/null 2>&1 || true
elif command -v mdev >/dev/null 2>&1; then
    mdev -s >/dev/null 2>&1 || true
fi

ifacewaited=0
ifacefound=''
while :; do
    if [ "$iface" = auto ]; then
        if [ -e /sys/class/net/eth0 ]; then
            ifacefound=eth0
        else
            ifacefound=$(spore_ifaces | head -1)
        fi
    elif [ -e "/sys/class/net/$iface" ]; then
        ifacefound=$iface
    fi
    if [ -n "$ifacefound" ]; then break; fi
    if [ "$ifacewaited" -ge "$ifacewait" ]; then break; fi
    if [ "$ifacewaited" = 0 ]; then
        echo "spore: no interface yet; waiting up to ${ifacewait}s for one to appear"
    fi
    sleep 1
    ifacewaited=$((ifacewaited + 1))
done

echo "spore: interfaces present after ${ifacewaited}s: $(spore_ifaces | tr '\n' ' ')"
if [ -n "$ifacefound" ]; then
    iface=$ifacefound
    echo "spore: using interface $iface"
else
    if [ "$iface" = auto ]; then
        echo "spore: this machine has no network interface other than loopback," >&2
        echo "spore: and none appeared in ${ifacewaited}s. Either its card has no" >&2
        echo 'spore: driver in this Alpine image, or the modloop did not mount.' >&2
    else
        echo "spore: this machine has no interface named '$iface', and none" >&2
        echo "spore: appeared in ${ifacewaited}s. Set $ifacekey to one of the" >&2
        echo 'spore: names listed above, or to auto to take whichever one this' >&2
        echo 'spore: machine turns out to have.' >&2
    fi
    iface=''
fi
RIR
}
