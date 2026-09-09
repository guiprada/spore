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
apk update'
    fi

    # On a diskless box /etc/apk/world persists the *intent* to have a package,
    # but without a cache on real media the files are re-downloaded every boot.
    repos_cache=$(mconf REPOS_APK_CACHE '')
    if [ -n "$repos_cache" ]; then
        plan_bootstrap repos-apkcache "set -e
mkdir -p '$repos_cache'
if command -v setup-apkcache >/dev/null 2>&1; then
    setup-apkcache '$repos_cache'
else
    mkdir -p /etc/apk
    ln -sf '$repos_cache' /etc/apk/cache
fi"
        plan_persist /etc/apk/cache
    fi
}
