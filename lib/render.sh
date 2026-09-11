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

# render_iface_resolve <name> [where-it-is-configured] [seconds-to-wait]
# Prints shell that leaves $iface holding a real interface name on the target,
# or empty if there is none — having already said, on the console and in the
# log, what it looked for, what it found, and where to look next.
#
# Three different things go wrong here and from a distance they look identical.
#
# The name can be wrong. Predictable naming gives eth0 on one box and enp3s0 on
# the next, and a spore is written on a workstation for a machine that is not in
# front of you, so the interface name is the one piece of it that cannot be
# known from there. `auto` exists for that.
#
# The name can be right and not there yet. A card's driver is loaded by coldplug
# and probes asynchronously, so a machine booting off USB can reach the default
# runlevel first. That reads as `ip: ioctl 0x8913 failed: No such device` —
# SIOCGIFFLAGS, *get* flags, returning ENODEV — about an interface that is there
# by the time anyone gets to the console. So: wait, do not believe the first
# look.
#
# Or there is no driver to load, because the modloop never mounted. Then the
# machine has *no* interface, ever, and nothing here can conjure one — but that
# is a completely different repair from the first two, and it is worth one line
# to say which of them you are in rather than another boot spent guessing.
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

# Alpine keeps its kernel modules in a squashfs on the boot medium rather than
# in the RAM root, so "is there a driver for this card" and "did the modloop
# mount" are the same question. Without it a diskless box still boots — kernel
# and initramfs carry what they need for USB and ext4 — and then has no network
# hardware at all, which is the shape of this failure exactly.
spore_modules_here() { [ -d "/lib/modules/$(uname -r)" ]; }

# What coldplug does, done directly. mdev -s creates device nodes but only
# modprobes when its hotplug rules fire, and udevadm is not on a stock mdev
# image at all — so on the machine where this matters most, neither of the two
# polite ways of asking does anything.
spore_coldplug() {
    command -v modprobe >/dev/null 2>&1 || return 0
    find /sys/devices -name modalias -type f 2>/dev/null | while read -r ma; do
        modprobe -b -q -- "$(cat "$ma" 2>/dev/null)" >/dev/null 2>&1 || true
    done
}

# Said only when there is nothing, because then it is the whole story.
spore_why_no_iface() {
    # If there are cards here and the named one simply is not among them, the
    # hardware is fine and the spore is wrong. Saying anything about modloops
    # here would be answering a question nobody asked.
    if [ -n "$(spore_ifaces)" ]; then
        echo 'spore:   there are interfaces on this machine, just not that one.' >&2
        echo 'spore:   The name is wrong, not the hardware.' >&2
        return 0
    fi
    if spore_modules_here; then
        echo "spore:   /lib/modules/$(uname -r) is present" >&2
        echo "spore:   $(grep -c . /proc/modules 2>/dev/null) modules loaded" >&2
    else
        echo "spore:   /lib/modules/$(uname -r) is MISSING — the modloop did not" >&2
        echo 'spore:   mount, so this machine has no drivers beyond what the' >&2
        echo 'spore:   kernel and initramfs carry, and never will have a card.' >&2
        echo 'spore:   Check modloop= and alpine_dev= against the boot medium.' >&2
    fi
    # The other half of that question: the kernel command line says which device
    # the initramfs was told to find the modloop on, and a medium rewritten by
    # `spore media` is exactly where that can stop being true.
    echo "spore:   cmdline: $(cat /proc/cmdline 2>/dev/null)" >&2
    sn_found=0
    for d in /sys/bus/pci/devices/*; do
        [ -f "$d/class" ] || continue
        case $(cat "$d/class" 2>/dev/null) in
            0x02*)
                sn_found=$((sn_found + 1))
                echo "spore:   network controller ${d##*/} wants:" >&2
                echo "spore:     $(cat "$d/modalias" 2>/dev/null)" >&2
                ;;
        esac
    done
    if [ "$sn_found" = 0 ]; then
        echo 'spore:   no PCI device announces itself as a network controller.' >&2
        echo 'spore:   Everything on the bus, in case the card is behind one:' >&2
        for d in /sys/bus/pci/devices/*; do
            [ -f "$d/modalias" ] || continue
            printf '%s %s\n' "${d##*/}" "$(cat "$d/modalias" 2>/dev/null)"
        done 2>/dev/null | head -24 | sed 's/^/spore:     /' >&2
    fi
}

if ! spore_modules_here; then
    echo 'spore: no kernel modules yet; trying to mount the modloop'
    if command -v rc-service >/dev/null 2>&1; then
        rc-service modloop start >/dev/null 2>&1 || true
    elif [ -x /etc/init.d/modloop ]; then
        /etc/init.d/modloop start >/dev/null 2>&1 || true
    fi
fi

if command -v udevadm >/dev/null 2>&1; then
    udevadm trigger --subsystem-match=net >/dev/null 2>&1 || true
    udevadm settle --timeout=10 >/dev/null 2>&1 || true
elif command -v mdev >/dev/null 2>&1; then
    mdev -s >/dev/null 2>&1 || true
fi
spore_coldplug

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
        echo "spore: no network interface other than loopback, and none appeared" >&2
        echo "spore: in ${ifacewaited}s. Why:" >&2
    else
        echo "spore: this machine has no interface named '$iface', and none" >&2
        echo "spore: appeared in ${ifacewaited}s. Why:" >&2
    fi
    spore_why_no_iface
    iface=''
fi
RIR
}

# render_net_report [seconds-to-wait-for-an-address]
# Prints shell that says what the interface in $iface actually got.
#
# Whether it worked, not whether it was attempted. Four phases later every one
# of these reads as `DNS: transient error (try again later)`: no address, an
# address with no route, a route to something that is not there, a working route
# with no resolver, and a genuinely slow mirror. Five repairs behind one message,
# and nothing in the log could tell them apart — which is how a wrong gateway
# gets diagnosed as a flaky CDN, twice.
#
# The wait is not decoration either: dhcp takes a moment, and `apk update` in the
# very next phase will happily run before the lease lands.
#
# And where it cannot find out, it says that instead of saying "none". A report
# that cannot tell "no address" from "no tool to ask with" is worse than no
# report, because it is believed.
render_net_report() {
    printf "netwait=%s\n" "${1:-15}"
    cat <<'RNR'
spore_addr_of() {
    if command -v ip >/dev/null 2>&1; then
        { ip -4 addr show dev "$1" 2>/dev/null || ip addr show dev "$1" 2>/dev/null; } |
            sed -n 's/.*inet \([0-9.][0-9.]*\).*/\1/p' | head -1
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig "$1" 2>/dev/null |
            sed -n 's/.*inet \(addr:\)*\([0-9.][0-9.]*\).*/\2/p' | head -1
    else
        printf '?'
    fi
}

# Little-endian hex, as the kernel writes it into /proc.
spore_hex_ip() {
    printf '%d.%d.%d.%d' \
        "0x$(printf '%s' "$1" | cut -c7-8)" \
        "0x$(printf '%s' "$1" | cut -c5-6)" \
        "0x$(printf '%s' "$1" | cut -c3-4)" \
        "0x$(printf '%s' "$1" | cut -c1-2)"
}

# /proc/net/route rather than ip(1): it is always there, and the default route
# is the single most useful fact in this whole report.
spore_default_route() {
    [ -r /proc/net/route ] || return 1
    while read -r rif rdest rgw rrest; do
        [ "$rdest" = 00000000 ] || continue
        printf '%s via %s' "$rif" "$(spore_hex_ip "$rgw")"
        return 0
    done < /proc/net/route
    return 1
}

netwaited=0
netaddr=''
while :; do
    netaddr=$(spore_addr_of "$iface")
    if [ -n "$netaddr" ]; then break; fi
    if [ "$netwaited" -ge "$netwait" ]; then break; fi
    sleep 1
    netwaited=$((netwaited + 1))
done

if [ "$netaddr" = '?' ]; then
    echo "spore: no ip or ifconfig here, so $iface's address cannot be read." >&2
elif [ -n "$netaddr" ]; then
    echo "spore: $iface has $netaddr after ${netwaited}s"
else
    echo "spore: $iface has no address after ${netwaited}s — dhcp got no lease," >&2
    echo 'spore: or the static address in this spore was never applied.' >&2
fi

if netroute=$(spore_default_route); then
    echo "spore: default route: $netroute"
    netgw=${netroute##* }
    if command -v ping >/dev/null 2>&1; then
        if ping -c 1 -W 2 "$netgw" >/dev/null 2>&1; then
            echo "spore: gateway $netgw answers"
        else
            echo "spore: gateway $netgw does not answer — nothing leaves this" >&2
            echo 'spore: machine, whatever the mirror says about itself.' >&2
        fi
    fi
else
    echo 'spore: no default route, so nothing can leave this subnet.' >&2
fi

if [ -f /etc/resolv.conf ]; then
    netdns=$(sed -n 's/^[[:space:]]*nameserver[[:space:]][[:space:]]*//p' \
             /etc/resolv.conf | tr '\n' ' ')
    if [ -n "$netdns" ]; then
        echo "spore: resolvers: $netdns"
    else
        echo 'spore: /etc/resolv.conf names no resolver, so no name resolves.' >&2
    fi
else
    echo 'spore: no /etc/resolv.conf at all, so no name resolves.' >&2
fi
RNR
}
