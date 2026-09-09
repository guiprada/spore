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
    if mconf_bool REPOS_COMMUNITY yes; then
        plan_bootstrap repos-community \
            "sed -i 's|^#\\(.*/community\\)\$|\\1|' /etc/apk/repositories && apk update"
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
