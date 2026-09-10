# lib/persist.sh — make it survive a reboot, by whatever mechanism this host has.
#
# The command is identical everywhere; only the backend differs. This is where
# diskless and container/VM hosts are unified.

persist_backend() { fact_persist; }

persist_commit() {
    case $(persist_backend) in
        lbu)
            lbu_warnings
            # Deliberately NOT remounting the media read-write here. lbu does it
            # itself (mount_once_rw), records what it remounted, and restores
            # read-only on exit. Remounting first would make lbu's is_ro check
            # see it as already writable, so it would not be added to
            # REMOUNT_RO_LIST and the boot medium would be left mounted rw — a
            # corruption risk on a USB stick at power loss. The original wizard's
            # make_usb_writable was for writing certs and the apk cache to the
            # medium directly, which is a different operation.

            # /etc is already in the overlay by default; everything else has to
            # be declared. Owned paths come from the plan, so this can't drift.
            { plan_persist_paths; plan_all_owned_paths; } | sort -u > "$SPORE_WORK/persist.final"
            while read -r pc_p; do
                [ -n "$pc_p" ] || continue
                case $pc_p in /etc|/etc/*) continue ;; esac
                run lbu include "$pc_p"
            done < "$SPORE_WORK/persist.final"
            run lbu commit
            # lbu returns once the write is issued, not once it has reached the
            # medium. On removable media a page-cached apkovl can survive a
            # clean shutdown and be lost to a power cut, leaving a truncated
            # archive that only fails at the next boot.
            run sync
            persist_verify
            say "committed to apkovl"
            ;;
        rootfs)
            pc_out=$(rootpath /var/lib/spore/spore)
            if mutate; then
                mkdir -p "$(dirname "$pc_out")"
                rm -rf "$pc_out"
                cp -a "$SPORE_DIR" "$pc_out"
            fi
            say "root is writable — nothing to commit; spore exported to /var/lib/spore/spore"
            ;;
    esac
}

# A broken trust store is silent until something fetches over HTTPS.
ca_warnings() {
    case $(fact_ca_store) in
        missing) warn "no CA trust store at /etc/ssl/certs/ca-certificates.crt.
         apk carries its own, so packages install while git, curl and every blob
         fetch fail with 'unable to get local issuer certificate'.
         Fix: apk add ca-certificates-bundle" ;;
        empty)   warn "the CA trust store at /etc/ssl/certs/ca-certificates.crt
         exists but holds no certificates. update-ca-certificates regenerates
         that file and can leave it empty.

         Note that \`openssl s_client\` will still verify happily: it reads the
         DIRECTORY /etc/ssl/certs, while git and curl read the single bundle
         FILE. A passing s_client does not mean this is fine.

         Fix: apk add --force-overwrite ca-certificates-bundle
         (do not run update-ca-certificates after — that is what empties it)
         Or point a tool at the directory: git config http.sslCAPath /etc/ssl/certs" ;;
    esac
}

# `lbu commit` with nowhere to write fails in a way that reads like a bug in
# spore rather than a missing line in lbu.conf.
lbu_warnings() {
    [ "$(persist_backend)" = lbu ] || return 0
    if [ "$(fact_lbu_dest)" = unset ]; then
        warn "this host is diskless but /etc/lbu/lbu.conf names no destination.
         \`spore persist\` has nowhere to write the apkovl, so nothing will
         survive a reboot. Set LBU_MEDIA to a mounted, writable device (a data
         partition is fine — the boot medium can stay read-only, since the
         initramfs finds the apkovl by scanning devices), or run setup-alpine
         and answer its 'store configs' question."
    fi
}

# A commit that cannot be read back is worse than no commit: it looks like
# success and fails at boot, when the machine is least able to tell you why.
persist_verify() {
    synthetic && return 0
    [ "$SPORE_NOEXEC" = 1 ] && return 0
    pv_dir=$(fact_lbu_dest)
    [ "$pv_dir" != unset ] && [ -d "$pv_dir" ] || return 0
    pv_f=$pv_dir/$(hostname 2>/dev/null).apkovl.tar.gz
    [ -f "$pv_f" ] || return 0
    if tar -tzf "$pv_f" >/dev/null 2>&1; then
        say "verified $pv_f ($(wc -c < "$pv_f") bytes)"
    else
        die "$pv_f was written but is not a readable archive.
         Do not reboot until this is resolved: the machine restores from this
         file and will come back without its configuration."
    fi
}

# The classic diskless trap.
persist_warnings() {
    [ "$(persist_backend)" = lbu ] || return 0
    if [ ! -d /var/cache/apk ] || [ ! -L /etc/apk/cache ]; then
        warn "diskless host with no apk cache on persistent media: /etc/apk/world will
         persist the intent to have a package, but the package files will be
         re-downloaded on every boot. See setup-apkcache."
    fi
}
