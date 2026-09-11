# lib/try.sh — boot the thing you just made, before walking it to a machine.
#
# The loop this project lived without for too long: write a stick, carry it to
# the box, boot, watch it not work, carry it back. Every mistake cost a round
# trip, and the evidence was on a RAM disk that the next reboot erased.
#
# A VM boots the same medium in seconds, with the console right there. It cannot
# tell you about that machine's hardware — its network card, its disks, its
# firmware — but it answers the question that has been expensive every time:
# does the seed run, and does the spore apply.

try_ovmf() {
    # An explicit path wins, for a distribution that puts it somewhere none of
    # these look. CODE:VARS for the split layout, or just CODE for a combined
    # image.
    if [ -n "${SPORE_OVMF:-}" ]; then
        to_code=${SPORE_OVMF%%:*}
        case $SPORE_OVMF in *:*) to_vars=${SPORE_OVMF#*:} ;; *) to_vars='' ;; esac
        [ -f "$to_code" ] || die "SPORE_OVMF names $to_code, which does not exist"
        printf '%s\t%s' "$to_code" "$to_vars"
        return 0
    fi

    # OVMF is required, not optional: the medium is EFI-only, so a BIOS guest
    # finds nothing bootable and fails in a way that looks like a bad stick.
    # Distributions disagree about both the path and whether it is split.
    for to_pair in \
        '/usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd' \
        '/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd' \
        '/usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd' \
        '/usr/share/edk2-ovmf/x64/OVMF_CODE.fd:/usr/share/edk2-ovmf/x64/OVMF_VARS.fd'
    do
        to_code=${to_pair%%:*}
        to_vars=${to_pair#*:}
        if [ -f "$to_code" ] && [ -f "$to_vars" ]; then
            printf '%s\t%s' "$to_code" "$to_vars"
            return 0
        fi
    done
    for to_one in /usr/share/ovmf/OVMF.fd /usr/share/qemu/OVMF.fd; do
        if [ -f "$to_one" ]; then
            printf '%s\t' "$to_one"
            return 0
        fi
    done
    return 1
}

# The guest's network is a NAT, so a spore configured for 192.168.1.50 comes up
# with no route and apk fails — which looks exactly like a real bug rather than
# an artefact of the VM. Reading the address off the medium lets the NAT be put
# on the same numbering, so the spore under test is the one that runs.
try_guest_net() {
    tg_target=$1
    tg_addr='' tg_gw='' tg_dns=''

    if [ -b "$tg_target" ] && [ "$(id -u)" = 0 ]; then
        tg_p2=$(media_part "$tg_target" 2)
        if [ -b "$tg_p2" ]; then
            mkdir -p "$SPORE_WORK/peek"
            if mount -o ro "$tg_p2" "$SPORE_WORK/peek" 2>/dev/null; then
                tg_c=$SPORE_WORK/peek/spore/modules/net.conf
                tg_addr=$(conf_get "$tg_c" NET_ADDRESS '')
                tg_gw=$(conf_get "$tg_c" NET_GATEWAY '')
                # The first is the one that has to answer; the rest are spares
                # this VM has no way to be either.
                tg_dns=$(conf_get "$tg_c" NET_DNS '')
                tg_dns=${tg_dns%% *}
                umount "$SPORE_WORK/peek" 2>/dev/null || true
            fi
        fi
    fi

    case $tg_addr in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*) : ;;
        *) SPORE_TRY_NETDEV='user,id=n0'; return 0 ;;
    esac

    # A /24 around the declared address, so the guest's own address is its own
    # and its gateway is where the spore says it is.
    tg_net=${tg_addr%.*}
    case $tg_gw in
        "$tg_net".*) tg_host=$tg_gw ;;
        *)           tg_host=$tg_net.1 ;;
    esac
    tg_opts="user,id=n0,net=$tg_net.0/24,host=$tg_host"

    # And DNS where the spore's resolv.conf will look for it. Without this the
    # guest asks an address nothing in the VM answers, apk reports "temporary
    # error (try again later)", and that reads as a flaky mirror rather than as
    # a resolver that does not exist here.
    case $tg_dns in
        "$tg_host")
            SPORE_TRY_DNS_CLASH=$tg_dns ;;
        "$tg_net".*)
            tg_opts="$tg_opts,dns=$tg_dns" ;;
        ?*)
            SPORE_TRY_DNS_OUTSIDE=$tg_dns ;;
    esac
    SPORE_TRY_NETDEV=$tg_opts
}

# try_boot <device|image> [write]
try_boot() {
    tb_target=$1
    tb_write=${2:-no}

    [ -e "$tb_target" ] || die "no such device or image: $tb_target"
    command -v qemu-system-x86_64 >/dev/null 2>&1 ||
        die "qemu-system-x86_64 is not installed.
         On Debian or Ubuntu: apt install qemu-system-x86 ovmf"

    if [ -b "$tb_target" ]; then
        [ "$(id -u)" = 0 ] || die "opening $tb_target as a raw disk needs root:
             sudo $SPORE_SELF try $*
         An image file does not — only a real device."
        media_has_medium "$tb_target" || die "$tb_target has no medium in it"
        if tb_used=$(media_in_use "$tb_target"); then
            die "$tb_target is mounted:
$(printf '%s\n' "$tb_used" | sed 's/^/           /')
         Handing the guest a device this kernel is also writing to corrupts
         both. Unmount it first."
        fi
    fi

    tb_fw=$(try_ovmf) || die "OVMF is not installed, and the medium is EFI-only —
         a BIOS guest would find nothing bootable and look like a bad stick.
         On Debian or Ubuntu: apt install ovmf"
    tb_code=${tb_fw%"$SPORE_TAB"*}
    tb_vars=${tb_fw#*"$SPORE_TAB"}

    set -- -machine q35 -m 2048 -smp 2

    # Firmware variables have to be writable, and must not be the system copy.
    if [ -n "$tb_vars" ]; then
        cp "$tb_vars" "$SPORE_WORK/OVMF_VARS.fd" || die "cannot stage OVMF variables"
        set -- "$@" \
            -drive "if=pflash,format=raw,readonly=on,file=$tb_code" \
            -drive "if=pflash,format=raw,file=$SPORE_WORK/OVMF_VARS.fd"
    else
        set -- "$@" -bios "$tb_code"
    fi

    # KVM if this kernel will give it to us; otherwise emulate and be slow
    # rather than refuse. The question being answered does not need speed.
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        set -- "$@" -enable-kvm -cpu host
    else
        say 'no access to /dev/kvm — emulating, which is slower but works'
    fi

    # Attached over USB rather than virtio, because that is what the target does.
    # A virtio disk arrives as /dev/vda and a stick as /dev/sda, and the boot
    # path cares: it scans device names. Testing over virtio would exercise a
    # different route than the one that runs on hardware, which is the one bug a
    # rehearsal must not introduce.
    set -- "$@" -device qemu-xhci,id=xhci \
        -drive "if=none,id=sporemedium,format=raw,file=$tb_target" \
        -device usb-storage,bus=xhci.0,drive=sporemedium
    # Writes land in a temporary file unless asked otherwise: a test boot that
    # can corrupt the medium it is testing is not much of a test.
    if [ "$tb_write" = write ]; then
        warn "the guest writes to $tb_target for real. Its apkovl will be
         committed to the medium, which is the point — but a half-finished boot
         leaves it half-written too."
    else
        set -- "$@" -snapshot
    fi

    SPORE_TRY_NETDEV='user,id=n0' SPORE_TRY_DNS_CLASH='' SPORE_TRY_DNS_OUTSIDE=''
    try_guest_net "$tb_target"
    if [ -n "$SPORE_TRY_DNS_CLASH" ]; then
        warn "this spore's DNS server and its gateway are the same address
         ($SPORE_TRY_DNS_CLASH), and the VM cannot be both. Name resolution will
         fail in here — apk will say \"temporary error (try again later)\" —
         while working perfectly on the real network. Add a second resolver to
         NET_DNS to rehearse this properly."
    elif [ -n "$SPORE_TRY_DNS_OUTSIDE" ]; then
        warn "this spore resolves through $SPORE_TRY_DNS_OUTSIDE, which is outside
         the network this VM can answer on. Name resolution will fail in here and
         not on the real network."
    fi
    set -- "$@" -netdev "$SPORE_TRY_NETDEV" -device virtio-net,netdev=n0

    # The boot, as text. A console you can only photograph is a console you
    # cannot paste, and that is most of why this project spent so long guessing:
    # the machine was saying something the whole time.
    tb_log=${SPORE_TRY_LOG:-$PWD/spore-boot.log}
    : > "$tb_log" 2>/dev/null || tb_log=$SPORE_WORK/spore-boot.log
    set -- "$@" -serial "file:$tb_log"

    # Somewhere to look. Without a display this would run blind, and running
    # blind is what made all of this expensive in the first place.
    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        tb_where='a window'
    else
        set -- "$@" -display none -vnc 127.0.0.1:0
        tb_where='VNC on 127.0.0.1:5900'
    fi

    printf '\nbooting %s%s — console in %s\n' "$tb_target" \
        "$([ "$tb_write" = write ] && printf ' (writing)' || printf ' (snapshot; the medium is not touched)')" \
        "$tb_where" >&2
    printf 'The boot console is written to %s — that is the\n' "$tb_log" >&2
    printf 'one to read when it comes up wrong.\n\n' >&2

    # Printing the invocation rather than running it: for the tests, and for
    # anyone who wants to take these arguments and add their own.
    if [ -n "${SPORE_TRY_PRINT:-}" ]; then
        printf 'qemu-system-x86_64'
        for tb_a in "$@"; do printf ' %s' "$tb_a"; done
        printf '\n'
        return 0
    fi

    qemu-system-x86_64 "$@"
}
