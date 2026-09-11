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
