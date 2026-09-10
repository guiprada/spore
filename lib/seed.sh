# lib/seed.sh — a bootstrap apkovl for unattended first boot.
#
# Alpine's initramfs finds *.apkovl.tar.gz by scanning block devices, so an
# overlay dropped on the data partition is picked up with the boot medium never
# being written to. This builds one that carries the tool and the spore, plus a
# local.d script that converges the machine on first boot and commits.
#
# It is deliberately not `build`: nothing here bakes the plan into the overlay.
# The machine still converges itself, a minute into its first boot, by running
# the same apply path as everywhere else. That avoids the ordering problem a
# baked plan has — bootstrap actions must precede Alpine's package restore, and
# local.d runs long after it — by baking configuration rather than scripts.

seed_build() {
    sb_out=$1
    sb_stage=$SPORE_WORK/seed
    rm -rf "$sb_stage"
    mkdir -p "$sb_stage/etc/local.d" "$sb_stage/etc/runlevels/default" \
             "$sb_stage/etc/spore" "$sb_stage/etc/apk/protected_paths.d" \
             "$sb_stage/usr/local/bin" "$sb_stage/usr/local/lib/spore"

    # The tool, relocated. The wrapper sets SPORE_PREFIX so bin/spore finds its
    # libraries without depending on where it was invoked from.
    cp -r "$SPORE_PREFIX/bin" "$SPORE_PREFIX/lib" "$SPORE_PREFIX/modules" \
          "$sb_stage/usr/local/lib/spore/"
    chmod 755 "$sb_stage/usr/local/lib/spore/bin/spore"
    printf '#!/bin/sh\nSPORE_PREFIX=/usr/local/lib/spore exec /usr/local/lib/spore/bin/spore "$@"\n' \
        > "$sb_stage/usr/local/bin/spore"
    chmod 755 "$sb_stage/usr/local/bin/spore"

    # The spore itself travels inside the overlay, so the machine carries its own
    # definition and needs nothing fetched to converge.
    cp -r "$SPORE_DIR" "$sb_stage/etc/spore/spore"

    # Repositories are baked as a file rather than left to a bootstrap script:
    # Alpine restores packages from /etc/apk/world early in boot, long before
    # local.d could enable a repository the restore depends on.
    sb_mirror=$(conf_get "$SPORE_DIR/modules/repos.conf" REPOS_MIRROR '')
    sb_release=$(conf_get "$SPORE_DIR/modules/repos.conf" REPOS_RELEASE '')
    if [ -n "$sb_mirror" ] && [ -n "$sb_release" ]; then
        printf '%s/%s/main\n%s/%s/community\n' \
            "$sb_mirror" "$sb_release" "$sb_mirror" "$sb_release" \
            > "$sb_stage/etc/apk/repositories"
        say "baked repositories: $sb_mirror/$sb_release"
    else
        plan_note "seed: REPOS_MIRROR and REPOS_RELEASE are unset in modules/repos.conf,
         so the overlay carries no repository list. The first boot will have only
         whatever the boot medium provides, and installing anything from the
         network will need setup-apkrepos by hand — which is not unattended."
    fi

    # lbu tracks /etc by default; the tool lives outside it.
    printf '+usr/local\n' > "$sb_stage/etc/apk/protected_paths.d/spore.list"

    cat > "$sb_stage/etc/local.d/spore.start" <<'START'
#!/bin/sh
# Managed by spore. Converges this machine on first boot, then commits.
exec >>/var/log/spore-seed.log 2>&1
printf '\n=== spore seed: %s ===\n' "$(date)"

if [ -f /etc/spore/.seeded ]; then
    echo "already converged; nothing to do"
    exit 0
fi

if /usr/local/bin/spore -s /etc/spore/spore apply --persist; then
    date > /etc/spore/.seeded
    echo "converged and committed"
else
    # No stamp: the next boot tries again rather than leaving a half-built
    # machine that looks finished.
    echo "apply failed — will retry on next boot"
    exit 1
fi
START
    chmod 755 "$sb_stage/etc/local.d/spore.start"

    # local.d only runs if the `local` service is in the default runlevel.
    ln -sf /etc/init.d/local "$sb_stage/etc/runlevels/default/local"

    tar -czf "$sb_out" -C "$sb_stage" .
    printf '%s\n' "$sb_out"
}
