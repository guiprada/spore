# lib/media.sh — writing the boot medium.
#
# GPT, an ESP holding the Alpine ISO extracted, and an ext4 data partition. The
# system is then identical on every boot and cannot drift; everything that
# changes lives on the other partition.
#
# Extracted rather than dd'd, deliberately. `dd` writes the hybrid ISO over the
# whole device, which leaves no room for a data partition and makes the desktop
# mount the raw device — so partition mounts then fail with EBUSY, on a device
# that looks idle.
#
# ext4 rather than vfat for the data side, also deliberately: vfat carries no
# Unix ownership, so the identity that decrypts every secret in the spore cannot
# be mode 0600 there. It would be readable by anyone holding the stick.

# nvme and mmc number their partitions p1/p2; sd and vd do not.
media_part() {
    case $1 in
        *[0-9]) printf '%sp%s' "$1" "$2" ;;
        *)      printf '%s%s'  "$1" "$2" ;;
    esac
}

# A device node with nothing in it — an empty card-reader slot, a stick that came
# loose. It opens fine and reports size 0, and the tools that then fail say so as
# "Error is 123", which is ENOMEDIUM and means nothing to anybody reading it.
media_has_medium() {
    mh_n=$(lsblk -dnbo SIZE "$1" 2>/dev/null | tr -d ' ')
    if [ -z "$mh_n" ]; then
        mh_s=/sys/class/block/${1##*/}/size
        [ -f "$mh_s" ] || return 0        # cannot tell; do not stand in the way
        mh_n=$(cat "$mh_s" 2>/dev/null || echo 0)
    fi
    [ "${mh_n:-0}" -gt 0 ] 2>/dev/null
}

media_need() {
    for mn_c in "$@"; do
        command -v "$mn_c" >/dev/null 2>&1 || die "$mn_c is not installed.
         On Debian or Ubuntu: apt install gdisk dosfstools e2fsprogs"
    done
}

# Refuse a device this machine is running from. Comparing against every mounted
# source catches / and everything else on the same disk, which a `removable`
# flag does not — an external SSD reports 0 and a card reader reports 1.
media_in_use() {
    mu_dev=$1
    awk -v d="$mu_dev" '
        index($1, d) == 1 { print $1 " mounted at " $2; found = 1 }
        END { exit !found }
    ' /proc/mounts 2>/dev/null
}

media_write() {
    mw_dev=$1
    mw_iso=$2

    [ "$(id -u)" = 0 ] || die "partitioning $mw_dev needs root:
             sudo $SPORE_SELF media $mw_dev $mw_iso"
    [ -b "$mw_dev" ] || die "$mw_dev is not a block device"
    media_has_medium "$mw_dev" || die "$mw_dev has no medium in it.
         The device node exists but reports size 0 — an empty card-reader slot,
         or a stick that is not seated. (This is the ENOMEDIUM that sgdisk
         reports as \"Error is 123\".)
         \`lsblk\` shows the real one: it has a size."
    [ -f "$mw_iso" ] || die "no such file: $mw_iso"

    # Before anything else, including whether the tools are even installed: a
    # missing package is an inconvenience, and erasing the disk this machine
    # boots from is not, so that answer must not be able to hide behind it.
    if mw_used=$(media_in_use "$mw_dev"); then
        die "$mw_dev is in use:
$(printf '%s\n' "$mw_used" | sed 's/^/           /')
         Refusing to erase a disk this machine is running from. Unmount it first
         if it really is the one you mean."
    fi

    media_need sgdisk mkfs.vfat mkfs.ext4 partprobe

    printf '\n' >&2
    lsblk -o NAME,SIZE,TYPE,LABEL,MODEL "$mw_dev" 2>/dev/null >&2 ||
        printf '  %s\n' "$mw_dev" >&2
    printf '\n%sThis erases everything on %s.%s\n' "$_c_red" "$mw_dev" "$_c_reset" >&2
    printf 'Type the device path to confirm: ' >&2
    if IFS= read -r mw_ok; then :; else mw_ok=''; fi
    [ "$mw_ok" = "$mw_dev" ] || die "not confirmed; nothing was written"

    # p1 is 1G: the standard ISO is well under that, and the rest is worth more
    # as data than as slack on a partition nothing writes to again.
    say "partitioning $mw_dev"
    run sgdisk --zap-all "$mw_dev"
    run sgdisk -n 1:0:+1G -t 1:ef00 -c 1:ALPINE "$mw_dev"
    run sgdisk -n 2:0:0   -t 2:8300 -c 2:DATA   "$mw_dev"
    run partprobe "$mw_dev"
    command -v udevadm >/dev/null 2>&1 && run udevadm settle

    mw_p1=$(media_part "$mw_dev" 1)
    mw_p2=$(media_part "$mw_dev" 2)
    [ -b "$mw_p1" ] || die "$mw_p1 did not appear after partitioning"

    say "formatting"
    run mkfs.vfat -F 32 -n ALPINE "$mw_p1"
    run mkfs.ext4 -q -L DATA "$mw_p2"

    mw_tmp=$SPORE_WORK/media
    mkdir -p "$mw_tmp/iso" "$mw_tmp/esp"
    say "extracting $(basename "$mw_iso")"
    run mount -o loop,ro "$mw_iso" "$mw_tmp/iso"
    run mount "$mw_p1" "$mw_tmp/esp"
    run cp -a "$mw_tmp/iso/." "$mw_tmp/esp/"
    run sync
    run umount "$mw_tmp/esp"
    run umount "$mw_tmp/iso"

    # Two things have to be rewritten in the image's own boot configuration.
    #
    # The first is not optional. Alpine's grub.cfg finds its root with
    # `search --label "alpine-std 3.24.1 x86_64"` — the ISO9660 volume label. A
    # FAT label is eleven characters with no spaces, so that string cannot exist
    # here, and the search fails on every boot: "no such device". Point it at the
    # label this partition actually has.
    #
    # The second is a serial console, so the boot can be read as text — in a VM,
    # and on a headless box at all. On hardware it changes nothing, since tty0
    # stays first in the list.
    if [ "$SPORE_DRYRUN" != 1 ]; then
        mkdir -p "$mw_tmp/esp"
        if mount "$mw_p1" "$mw_tmp/esp" 2>/dev/null; then
            mw_patched=0
            find "$mw_tmp/esp" -maxdepth 5 -type f \
                 \( -name '*.cfg' -o -name '*.conf' \) 2>/dev/null > "$SPORE_WORK/bootcfgs" || true
            while IFS= read -r mw_cfg; do
                [ -n "$mw_cfg" ] || continue
                grep -qE '(^|[ \t])(linux|linuxefi|linux16|kernel|append|APPEND)[ \t]|search' \
                    "$mw_cfg" 2>/dev/null || continue
                if awk -v LBL=ALPINE -f "$SPORE_PREFIX/lib/bootpatch.awk" "$mw_cfg" > "$mw_cfg.spore" &&
                   ! cmp -s "$mw_cfg" "$mw_cfg.spore"
                then
                    mv "$mw_cfg.spore" "$mw_cfg"
                    mw_patched=$((mw_patched + 1))
                else
                    rm -f "$mw_cfg.spore"
                fi
            done < "$SPORE_WORK/bootcfgs"
            if [ "$mw_patched" -gt 0 ]; then
                say "pointed $mw_patched boot config(s) at label ALPINE, with a serial console"
            else
                warn "found no boot configuration to adjust on this image. If it
         searches for its own ISO volume label it will fail with \"no such
         device\" on every boot, and nothing here can be read as text."
            fi
            umount "$mw_tmp/esp"
        fi
    fi

    # A customized ISO carries its own apkovl, and the initramfs takes the first
    # one it finds — so it would win over the seed and the machine would come up
    # as somebody else's, with the spore never running and nothing saying why.
    if [ "$SPORE_DRYRUN" != 1 ]; then
        mkdir -p "$mw_tmp/esp"
        if mount "$mw_p1" "$mw_tmp/esp" 2>/dev/null; then
            for mw_stray in "$mw_tmp/esp"/*.apkovl.tar.gz; do
                [ -f "$mw_stray" ] || continue
                warn "$(basename "$mw_stray") was in that ISO — removing it.
         The initramfs loads the first apkovl it finds, so it would have won
         over your spore and the machine would have come up as another one."
                rm -f "$mw_stray"
            done
            umount "$mw_tmp/esp"
        fi
    fi
    run sync

    printf '\n%s is ready.\n\n' "$mw_dev" >&2
    printf '  %-14s ALPINE   the system, read-only from here on\n' "$mw_p1" >&2
    printf '  %-14s DATA     your machine goes here\n\n' "$mw_p2" >&2
    printf 'Now write the machine to it — the device, not the partitions; it\n' >&2
    printf 'finds and mounts those itself:\n\n' >&2
    printf '  sudo %s install <dir> %s\n\n' "$SPORE_SELF" "$mw_dev" >&2
    printf 'Then boot it here before carrying it anywhere:\n\n' >&2
    printf '  sudo %s try %s\n' "$SPORE_SELF" "$mw_dev" >&2
}
