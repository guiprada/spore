# lib/persist.sh — make it survive a reboot, by whatever mechanism this host has.
#
# The command is identical everywhere; only the backend differs. This is where
# diskless and container/VM hosts are unified.

persist_backend() { fact_persist; }

persist_commit() {
    case $(persist_backend) in
        lbu)
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

# The classic diskless trap.
persist_warnings() {
    [ "$(persist_backend)" = lbu ] || return 0
    if [ ! -d /var/cache/apk ] || [ ! -L /etc/apk/cache ]; then
        warn "diskless host with no apk cache on persistent media: /etc/apk/world will
         persist the intent to have a package, but the package files will be
         re-downloaded on every boot. See setup-apkcache."
    fi
}
