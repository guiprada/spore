# modules/repos.sh — apk repositories and cache.
#
# Both actions are `bootstrap`, not `firstboot`: enabling community has to happen
# before any package is installed, and pointing the cache at persistent media is
# only useful if it precedes the first apk add.

repos_meta() {
    MOD_DESC='apk repositories and package cache'
    MOD_REQUIRES='root'
}

repos_plan() {
    # A mirror, if this spore names one. setup-alpine asks for this and it is
    # not cosmetic: the default CDN can be slow or unreachable from where the
    # machine actually lives, and a diskless box re-fetches on every boot.
    #
    # The branch is read off the target rather than carried here — a spore that
    # hardcoded v3.20 would quietly install the wrong release on a 3.22 image.
    repos_mirror=$(mconf REPOS_MIRROR '')
    if [ -n "$repos_mirror" ]; then
        case $repos_mirror in
            http://*|https://*) : ;;
            *) die "repos: REPOS_MIRROR must be an http:// or https:// URL" ;;
        esac
        repos_mirror=${repos_mirror%/}
        # shellcheck disable=SC2016  # the target's shell expands these, not ours
        plan_bootstrap repos-mirror "set -e
f=/etc/apk/repositories
branch=\$(sed -n 's|^[^#].*/alpine/\\(v[0-9.]*\\)/main.*|\\1|p' \"\$f\" 2>/dev/null | head -1)
if [ -z \"\$branch\" ] && [ -f /etc/alpine-release ]; then
    rel=\$(cat /etc/alpine-release)
    case \$rel in
        *_*) branch=edge ;;
        *)   branch=v\$(printf '%s' \"\$rel\" | cut -d. -f1,2) ;;
    esac
fi
if [ -z \"\$branch\" ]; then
    echo 'spore: cannot tell which Alpine branch this is, so the mirror was not set' >&2
    exit 1
fi
# Keep a local repository from the boot medium if there is one: it makes the
# first install work even when the network does not.
local_apks=\$(grep -m1 '^/media/.*/apks' \"\$f\" 2>/dev/null || true)
{
    [ -n \"\$local_apks\" ] && printf '%s\\n' \"\$local_apks\"
    printf '%s/%s/main\\n' '$repos_mirror' \"\$branch\"
    printf '%s/%s/community\\n' '$repos_mirror' \"\$branch\"
} > \"\$f\"
if ! apk update; then
    echo 'spore: apk update could not reach every repository.' >&2
    echo 'spore: continuing — a package that is genuinely missing will say so' >&2
    echo 'spore: when it fails to install, which is a far clearer place to stop.' >&2
fi"
    fi

    # Three states have to be handled, not one. A configured box has the
    # community line present but commented; a freshly booted one often has no
    # community line at all, so there is nothing to uncomment and a naive sed
    # silently succeeds while changing nothing — and the next apk add fails for
    # a reason that looks unrelated.
    if mconf_bool REPOS_COMMUNITY yes; then
        # Single-quoted on purpose: $f and $main are for the target's shell to
        # expand when this runs there, not for us to expand now.
        # shellcheck disable=SC2016
        plan_bootstrap repos-community 'set -e
f=/etc/apk/repositories
if [ ! -f "$f" ]; then
    echo "spore: $f does not exist — run setup-apkrepos first" >&2
    exit 1
fi
if grep -qE "^[[:space:]]*[^#[:space:]].*/community" "$f"; then
    :                                   # already enabled
elif grep -qE "^[[:space:]]*#.*/community" "$f"; then
    sed -i "s|^[[:space:]]*#[[:space:]]*\(.*/community\)|\1|" "$f"
else
    main=$(grep -m1 -E "^[[:space:]]*[^#[:space:]].*/main[[:space:]]*$" "$f" || true)
    if [ -z "$main" ]; then
        echo "spore: no active /main repository in $f to derive /community from." >&2
        echo "spore: a booted ISO often lists only its local /apks repository." >&2
        echo "spore: run \`setup-apkrepos -1\` to add a network mirror, then apply again." >&2
        exit 1
    fi
    printf "%s\n" "$main" | sed "s|/main[[:space:]]*$|/community|" >> "$f"
fi
# One unreachable mirror is not a reason to abandon a machine: a local
# repository on the boot medium may carry what is needed, and a package that
# genuinely is not available anywhere will say so when it fails to install,
# which is a far clearer place to stop than here.
if ! apk update; then
    echo "spore: apk update could not reach every repository; continuing" >&2
fi'
    fi

    # On a diskless box /etc/apk/world persists the *intent* to have a package,
    # and the cache is what turns that intent back into software. The initramfs
    # reinstalls all of world into the RAM root on every boot and runs apk with
    # --no-network unless the machine net-booted, so an uncached package is not
    # slow to come back, it does not come back. See persist_warnings.
    repos_cache=$(mconf REPOS_APK_CACHE '')
    # A relative value is resolved against the medium this spore was read from,
    # and that is the form to prefer. The same stick is /media/sdc2 on a machine
    # with two internal disks and /media/sda2 under qemu where it is the only
    # one, so an absolute path is correct in exactly one of the two places you
    # are going to boot it — and wrong silently, because a cache directory on a
    # device that does not exist is just a cache that never fills.
    #
    # The plan is built on the target, by the seed, against the spore on the
    # medium, so SPORE_DIR here is already that machine's own answer.
    case $repos_cache in
        ''|/*) : ;;
        *) repos_cache="${SPORE_DIR%/*}/$repos_cache"
           plan_note "repos: REPOS_APK_CACHE is relative, so the cache is
         $repos_cache on this machine — beside the spore, on whatever the
         medium is called here. An absolute path would name a device, and the
         same stick is not the same device in a machine and in a VM." ;;
    esac
    if [ -n "$repos_cache" ]; then
        # The boot medium is mounted read-only, so the remount comes first and
        # everything else follows it. Written the other way round — mkdir, then
        # setup-apkcache, then the remount — this died on its own first line,
        #
        #     mkdir: can't create directory '/media/sdc2/apkcache':
        #            Read-only file system
        #
        # three phases before any package, so the machine got the repositories
        # and nothing else. And it must stay writable afterwards: setup-apkcache
        # remounts rw only long enough to make the directory and the symlink
        # before putting it back, and apk runs after that. Left read-only, the
        # setting looks applied, the cache stays empty, and the next boot is
        # missing exactly the packages this exists to keep. The commit at the end
        # of the apply remounts it read-only again.
        #
        # Never fatal. A cache that cannot be made is a machine that will not
        # come back whole, which the rehearsal at the end of the apply says in
        # those words — but the user account, the password and the keymap are
        # exactly what you still want on a box you are about to lose the network
        # to, so this explains itself and lets the rest of the run happen.
        plan_bootstrap repos-apkcache "cache_dir='$repos_cache'
cache_mp=\$(df -P \"\${cache_dir%/*}\" 2>/dev/null | awk 'NR==2 { print \$6 }')
cache_rw() {
    [ -n \"\$cache_mp\" ] && mount -o remount,rw \"\$cache_mp\" 2>/dev/null
}
if ! mkdir -p \"\$cache_dir\" 2>/dev/null; then
    if cache_rw && mkdir -p \"\$cache_dir\" 2>/dev/null; then
        echo \"spore: remounted \$cache_mp read-write to make the apk cache\"
    else
        echo \"spore: cannot create an apk cache at \$cache_dir — \${cache_mp:-its filesystem}\" >&2
        echo \"spore: is read-only and would not remount. The rest of the spore still\" >&2
        echo \"spore: applies, but the next boot reinstalls world with no network and\" >&2
        echo \"spore: will be missing whatever is not already on this medium.\" >&2
        exit 0
    fi
fi
if command -v setup-apkcache >/dev/null 2>&1; then
    setup-apkcache \"\$cache_dir\" || true
else
    mkdir -p /etc/apk
    ln -sf \"\$cache_dir\" /etc/apk/cache
fi
if ! touch \"\$cache_dir/.spore-w\" 2>/dev/null; then
    if cache_rw; then
        echo \"spore: remounted \$cache_mp read-write so apk can fill the cache\"
    else
        echo \"spore: the apk cache at \$cache_dir is not writable and would not\" >&2
        echo \"spore: remount, so apk will install from the network and cache\" >&2
        echo \"spore: nothing. The next boot is still missing its packages.\" >&2
    fi
fi
rm -f \"\$cache_dir/.spore-w\" 2>/dev/null || true
# And an index in it, which is the half that is easy to miss. apk resolves
# against an APKINDEX and cannot fetch one with --no-network, so a cache holding
# every .apk and no index is a shelf the boot will not look at. The index is
# written into the cache by apk update — and both of the apk updates above ran
# in repos-mirror and repos-community, before this cache existed, so they wrote
# it nowhere. Doing it again now costs one round trip and is the difference
# between a machine that comes back and one that does not.
if apk update >/dev/null 2>&1; then
    echo \"spore: apk index cached, so the next boot can resolve packages offline\"
else
    echo \"spore: could not refresh the apk index into the cache. The cached\" >&2
    echo \"spore: packages are there but the next boot has no index to resolve\" >&2
    echo \"spore: them against, and installs from the medium /apks alone.\" >&2
fi"
        plan_persist /etc/apk/cache

        # Filling it on purpose rather than by accident. apk caches what it
        # downloads, so a run that found half of world already installed caches
        # half of world — and the half it skipped is missing from the next boot,
        # which is the boot that has no network to go and get it. `apk cache
        # download` resolves world and fetches whatever is not there yet, so the
        # cache holds the whole machine however this particular run went.
        #
        # firstboot, because it has to run after the package phase: the point is
        # to catch up with whatever apk did there.
        # shellcheck disable=SC2016  # the target's shell expands these, not ours
        plan_firstboot repos-apkcache-fill 'if ! [ -d /etc/apk/cache ] && ! [ -L /etc/apk/cache ]; then
    exit 0
fi
echo "spore: filling the apk cache so the next boot can install world offline"
if apk cache download 2>&1; then
    echo "spore: apk cache holds $(find /etc/apk/cache/ -name "*.apk" 2>/dev/null | wc -l) package file(s)"
else
    echo "spore: apk cache download did not complete. Whatever is missing from" >&2
    echo "spore: the cache is missing from the next boot too — the initramfs" >&2
    echo "spore: installs world with no network." >&2
fi'
    fi

    repos_plan_bootrepo
}

# A boot repository on the medium, which is the only package source on a
# diskless boot that does not depend on what the disk happens to be called.
#
# The cache does depend on it, and that is what defeated a day of this. apk
# opens its cache through /etc/apk/cache, a symlink the apply writes with the
# medium's absolute path baked in — /media/sdc2/apkcache, because on that
# machine the stick was the third disk. Move the same stick to a machine where
# it is the first, or boot it under qemu where it is the only one, and it is
# /media/sda2: the symlink points at nothing, apk says
#
#     WARNING: opening from cache .../APKINDEX.tar.gz: No such file or directory
#
# and installs none of world. An overlay that only germinates where the device
# letters match is not a spore.
#
# initramfs-init finds its package sources by *searching* instead:
#
#     find "$ROOT"/media/* -maxdepth 3 -name .boot_repository -type f
#
# so a directory marked that way is found under whatever name the medium got.
# That is the mechanism behind /media/sdc1/apks, the one source that has worked
# on every boot of this machine under both names.
#
# And it needs no signing key, which the obvious version of this does. apk
# verifies index signatures and the initramfs passes no --allow-untrusted, so
# an index spore built itself would be rejected — but an index does not have to
# be built. Each upstream repository already publishes one, signed by Alpine,
# whose key is already trusted. Mirror those verbatim, one directory per
# upstream repository, and hardlink the package pool into each: the index is
# authentic, the packages are the ones apk already chose, and the disk cost is
# one copy however many repositories share it.
repos_plan_bootrepo() {
    repos_br=$(mconf REPOS_BOOT_REPO '')
    [ -n "$repos_br" ] || return 0
    case $repos_br in
        /*) : ;;
        *)  repos_br="${SPORE_DIR%/*}/$repos_br"
            plan_note "repos: REPOS_BOOT_REPO is relative, so the boot repository is
         $repos_br on this machine. Relative is the form to prefer: the
         initramfs finds it by searching /media for a .boot_repository marker,
         so nothing here is tied to the medium being sdc rather than sda." ;;
    esac
    plan_note "repos: the medium carries its own package repository, so a boot
         with no network installs all of /etc/apk/world from it. This is what
         the apk cache cannot do portably — the cache is reached through an
         absolute symlink naming a device, and the device is not called the
         same thing on the next machine."
    # firstboot: after the package phase, so the pool is whatever apk settled on.
    plan_firstboot repos-bootrepo "set -u
br_root='$repos_br'
br_arch=\$(apk --print-arch 2>/dev/null || echo x86_64)
br_mp=\$(df -P \"\${br_root%/*}\" 2>/dev/null | awk 'NR==2 { print \$6 }')
if ! mkdir -p \"\$br_root\" 2>/dev/null; then
    if ! { [ -n \"\$br_mp\" ] && mount -o remount,rw \"\$br_mp\" 2>/dev/null &&
           mkdir -p \"\$br_root\" 2>/dev/null; }; then
        echo \"spore: cannot write a boot repository at \$br_root. The next boot\" >&2
        echo \"spore: installs world with no network and will be missing packages.\" >&2
        exit 0
    fi
fi

# The pool. Hardlinked from the cache where there is one, because the files are
# already on this filesystem and a second copy of a desktop is not free.
br_pool=\$br_root/.pool
mkdir -p \"\$br_pool\"
for br_f in /etc/apk/cache/*.apk; do
    [ -e \"\$br_f\" ] || continue
    ln -f \"\$br_f\" \"\$br_pool/\${br_f##*/}\" 2>/dev/null ||
        cp -f \"\$br_f\" \"\$br_pool/\" 2>/dev/null || true
done
# And whatever the cache did not have. --recursive is the point: world names
# the packages you asked for, and the boot has to install their dependencies
# too, with no network to resolve them over.
# shellcheck disable=SC2046
apk fetch --recursive --output \"\$br_pool\" \$(tr '\\n' ' ' < /etc/apk/world) \\
    >/dev/null 2>&1 || true

br_n=0
br_made=0
while IFS= read -r br_url; do
    case \$br_url in http://*|https://*) ;; *) continue ;; esac
    br_n=\$((br_n + 1))
    br_d=\$br_root/r\$br_n
    mkdir -p \"\$br_d/\$br_arch\" || continue
    # Alpine's own index, signed with Alpine's own key, copied rather than
    # rebuilt. A rebuilt one would need a key of ours and the initramfs would
    # refuse it.
    if ! { wget -q -O \"\$br_d/\$br_arch/APKINDEX.new\" \"\$br_url/\$br_arch/APKINDEX.tar.gz\" 2>/dev/null ||
           curl -fsSL -o \"\$br_d/\$br_arch/APKINDEX.new\" \"\$br_url/\$br_arch/APKINDEX.tar.gz\" 2>/dev/null; }; then
        rm -f \"\$br_d/\$br_arch/APKINDEX.new\"
        echo \"spore: could not mirror the index for \$br_url\" >&2
        continue
    fi
    mv -f \"\$br_d/\$br_arch/APKINDEX.new\" \"\$br_d/\$br_arch/APKINDEX.tar.gz\"
    for br_f in \"\$br_pool\"/*.apk; do
        [ -e \"\$br_f\" ] || continue
        ln -f \"\$br_f\" \"\$br_d/\$br_arch/\${br_f##*/}\" 2>/dev/null || true
    done
    # Last, so a half-built repository is never marked as one.
    : > \"\$br_d/.boot_repository\"
    br_made=\$((br_made + 1))
done < /etc/apk/repositories

if [ \"\$br_made\" -gt 0 ]; then
    echo \"spore: boot repository at \$br_root — \$br_made repo(s), \$(find \"\$br_pool\" -name '*.apk' 2>/dev/null | wc -l) package file(s)\"
    echo \"spore: the initramfs finds it by searching for .boot_repository, so it\"
    echo \"spore: works whatever this medium is called on the next machine.\"
else
    echo \"spore: no boot repository could be built, so the next boot installs\" >&2
    echo \"spore: world with no network and will be missing packages.\" >&2
fi
sync 2>/dev/null || true"
}
