# lib/apkfetch.sh — put a package's binary on the medium, from the workstation.
#
# `age` is the one package spore's own machinery needs on the target: a sealed
# secret cannot be opened without it. Everything else a spore installs is the
# spore's business, and it can fail with a clear message. This one cannot —
# without age there is no root password, no user password, and a machine that
# comes up with nothing to log in as.
#
# Which makes it exactly the wrong thing to require a working mirror for. The
# workstation building the medium has a network by definition; the machine that
# boots it may not, may have one that resolves nothing, or may be behind a CDN
# having a bad day. So the binary travels on the medium, like everything else
# in a spore.
#
# Not the workstation's own age: on Debian and Ubuntu that is linked against
# glibc, and a glibc binary does not run on musl Alpine. It has to come from an
# Alpine package, which is a tarball, so one file can be lifted straight out.

# apk_branch <alpine-release>   3.24.1 -> v3.24, edge stays edge
apk_branch() {
    case $1 in
        ''|*[!0-9.]*[!0-9._]*) printf 'edge' ;;
        *_*)                   printf 'edge' ;;
        *) printf 'v%s' "$(printf '%s' "$1" | cut -d. -f1,2)" ;;
    esac
}

# apk_get <url> <dest>   Whichever fetcher is here; neither is guaranteed.
apk_get() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 120 -o "$2" "$1" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 120 -O "$2" "$1" 2>/dev/null
    else
        return 127
    fi
}

# apk_version <mirror> <branch> <repo> <arch> <pkg>
# The index is a tarball holding one text file, in paragraphs keyed by letter:
# P: is the name, V: the version. The version is needed because the .apk is
# named for it and nothing else on the mirror will say which one is current.
apk_version() {
    av_idx=$SPORE_WORK/APKINDEX.tar.gz
    apk_get "$1/$2/$3/$4/APKINDEX.tar.gz" "$av_idx" || return 1
    [ -s "$av_idx" ] || return 1
    tar -xzOf "$av_idx" APKINDEX 2>/dev/null |
        awk -v p="P:$5" '
            $0 == p      { found = 1; next }
            found && /^V:/ { print substr($0, 3); exit }
            /^$/         { found = 0 }
        '
}

# apk_extract_binary <mirror> <branch> <repo> <arch> <pkg> <path> <dest>
# Prints nothing on success. An .apk is a gzip stream (three concatenated, in
# fact: signature, control, data) wrapping a tar, so tar reads it directly.
apk_extract_binary() {
    ae_mirror=$1 ae_branch=$2 ae_repo=$3 ae_arch=$4
    ae_pkg=$5 ae_path=$6 ae_dest=$7

    ae_ver=$(apk_version "$ae_mirror" "$ae_branch" "$ae_repo" "$ae_arch" "$ae_pkg") || return 1
    [ -n "$ae_ver" ] || return 1

    ae_apk=$SPORE_WORK/$ae_pkg.apk
    apk_get "$ae_mirror/$ae_branch/$ae_repo/$ae_arch/$ae_pkg-$ae_ver.apk" "$ae_apk" || return 1
    [ -s "$ae_apk" ] || return 1

    mkdir -p "$(dirname "$ae_dest")"
    tar -xzOf "$ae_apk" "$ae_path" > "$ae_dest" 2>/dev/null || return 1

    # Look at what came out. A mirror that answers every request with an HTML
    # error page would otherwise leave a "binary" on the medium that fails on
    # the target with something unrecognisable, one boot later and far from
    # here. Cheaper to refuse it now.
    [ -s "$ae_dest" ] || { rm -f "$ae_dest"; return 1; }
    case $(head -c 4 "$ae_dest" | od -An -tx1 2>/dev/null | tr -d ' \n') in
        7f454c46) : ;;
        *) rm -f "$ae_dest"; return 1 ;;
    esac
    chmod 755 "$ae_dest"
    printf '%s' "$ae_ver"
}
