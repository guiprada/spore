# lib/seed.sh — a generic bootstrap overlay.
#
# The overlay is host-independent and carries no configuration: only the tool and
# a hook that, at first boot, finds a `spore/` directory on any attached
# filesystem and applies it. That keeps the thing you edit as plain text sitting
# next to the overlay on the data partition, rather than sealed inside a tarball
# that can only be rebuilt from an already-working Alpine.
#
# Alpine's initramfs finds *.apkovl.tar.gz by scanning block devices, so the
# overlay lives on the data partition and the boot medium is never written to.
# The hook does the same kind of scan for the spore.

seed_build() {
    sb_out=$1
    sb_stage=$SPORE_WORK/seed
    rm -rf "$sb_stage"
    mkdir -p "$sb_stage/etc/init.d" "$sb_stage/etc/local.d" \
             "$sb_stage/etc/runlevels/default" \
             "$sb_stage/etc/apk/protected_paths.d" \
             "$sb_stage/usr/local/bin" "$sb_stage/usr/local/lib/spore"

    cp -r "$SPORE_PREFIX/bin" "$SPORE_PREFIX/lib" "$SPORE_PREFIX/modules" \
          "$sb_stage/usr/local/lib/spore/"
    chmod 755 "$sb_stage/usr/local/lib/spore/bin/spore"
    printf '#!/bin/sh\nSPORE_PREFIX=/usr/local/lib/spore exec /usr/local/lib/spore/bin/spore "$@"\n' \
        > "$sb_stage/usr/local/bin/spore"
    chmod 755 "$sb_stage/usr/local/bin/spore"

    # lbu tracks /etc by default; the tool lives outside it.
    printf '+usr/local\n' > "$sb_stage/etc/apk/protected_paths.d/spore.list"

    cat > "$sb_stage/usr/local/lib/spore/seed-run" <<'START'
#!/bin/sh
# Managed by spore. Finds a spore on attached media and converges this machine.
exec >>/var/log/spore-seed.log 2>&1
printf '\n=== spore seed: %s ===\n' "$(date 2>/dev/null)"

# /var/log is on the RAM root, so a reboot takes this log with it — and the
# reboot is exactly what you do when the machine did not come up right. Copy it
# beside the spore on the way out, on every path, so the evidence outlives the
# boot that produced it.
seed_data=''
save_log() {
    [ -n "$seed_data" ] || return 0
    cp /var/log/spore-seed.log "$seed_data/spore-seed.log" 2>/dev/null || return 0
    sync 2>/dev/null || true
}
trap save_log EXIT

if [ -f /etc/spore/.seeded ]; then
    echo "already converged; nothing to do"
    exit 0
fi

# Already-mounted media first, then anything mountable. The spore is a directory
# named `spore` at the root of a filesystem — the same place you unpacked it to.
found=
for d in /media/*/spore /mnt/*/spore; do
    [ -f "$d/spore.conf" ] && { found=$d; break; }
done

if [ -z "$found" ]; then
    mkdir -p /mnt/spore-scan
    # vd and xvd are not an afterthought: a VM guest is one of the two things
    # this is for, and a virtio disk is what every hypervisor hands it. Scanning
    # only sd/nvme/mmcblk found nothing there and reported it as "no spore on any
    # attached filesystem", which is true and useless.
    for dev in /dev/sd[a-z][0-9]* /dev/vd[a-z][0-9]* /dev/xvd[a-z][0-9]* \
               /dev/nvme[0-9]n[0-9]p[0-9]* /dev/mmcblk[0-9]p[0-9]*; do
        [ -b "$dev" ] || continue
        mount "$dev" /mnt/spore-scan 2>/dev/null || continue
        if [ -f /mnt/spore-scan/spore/spore.conf ]; then
            found=/mnt/spore-scan/spore
            echo "found a spore on $dev"
            break
        fi
        umount /mnt/spore-scan 2>/dev/null
    done
fi

if [ -z "$found" ]; then
    echo "no spore found on any attached filesystem."
    echo "Unpack one as <filesystem>/spore/ — it needs a spore.conf at its root."
    exit 1
fi

seed_data=$(dirname "$found")

echo "applying $found"
if /usr/local/bin/spore -s "$found" apply --persist; then
    mkdir -p /etc/spore
    date > /etc/spore/.seeded
    echo "converged and committed"
else
    # No stamp: the next boot tries again rather than leaving a half-built
    # machine that looks finished.
    echo "apply failed — will retry on next boot"
    exit 1
fi
START
    chmod 755 "$sb_stage/usr/local/lib/spore/seed-run"

    # Its own service, rather than a hook in /etc/local.d. local.d runs only if
    # the `local` service is present and in the runlevel, which is an assumption
    # about the image that cannot be checked from here — and when it does not
    # hold, nothing runs and nothing is written, so there is not even a log to
    # say so. A service we ship ourselves depends on nothing but OpenRC.
    cat > "$sb_stage/etc/init.d/spore-seed" <<'UNIT'
#!/sbin/openrc-run
description="Find a spore on attached media and converge this machine"

depend() {
    # After the filesystems it will look through, and after the network it will
    # need to fetch packages — but needing neither, since a machine with no
    # network still has a spore worth applying as far as it can get.
    after localmount net
}

start() {
    ebegin "spore: looking for a spore to germinate"
    /usr/local/lib/spore/seed-run
    eend $? "spore: see spore-seed.log beside the spore, and /var/log"
}
UNIT
    chmod 755 "$sb_stage/etc/init.d/spore-seed"
    ln -sf /etc/init.d/spore-seed "$sb_stage/etc/runlevels/default/spore-seed"

    # A one-line breadcrumb in local.d as well, in case that is where somebody
    # looks. It only reports; the service does the work.
    printf '#!/bin/sh\n# The work is done by the spore-seed service, not here.\n# rc-service spore-seed start\n' \
        > "$sb_stage/etc/local.d/spore.start"
    chmod 644 "$sb_stage/etc/local.d/spore.start"

    # The overlay is unpacked by the initramfs as root, which restores whatever
    # ownership the archive records. Built by an ordinary user — which is the
    # normal case, since the point is to prepare this from a workstation — every
    # file would arrive owned by that uid.
    sb_towner=''
    if : > "$SPORE_WORK/.tarprobe" &&
       tar --owner=0 --group=0 --numeric-owner \
           -cf /dev/null -C "$SPORE_WORK" .tarprobe 2>/dev/null
    then
        sb_towner='--owner=0 --group=0 --numeric-owner'
    elif [ "$(id -u)" != 0 ]; then
        warn "this tar cannot force ownership, and you are not root, so the
         overlay will record uid $(id -u). The initramfs restores that verbatim.
         Build it as root, or with GNU tar."
    fi
    rm -f "$SPORE_WORK/.tarprobe"

    # shellcheck disable=SC2086  # deliberate word splitting of the option list
    tar $sb_towner -czf "$sb_out" -C "$sb_stage" .
}
