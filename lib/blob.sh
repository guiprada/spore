# lib/blob.sh — third-party static binaries.
#
# Things apk does not carry (dufs, and later caddy/restic/syncthing) are
# referenced by url + sha256, never carried inside the spore. That is what keeps
# a spore text-only and small enough to stay movable.
#
# blobs.conf rows:  <name> <arch> <url> <sha256> <dest> <mode> <member>
# <member> is the path inside a tar.gz, or '-' for a bare binary.

blob_lookup() {
    bl_conf=$SPORE_DIR/blobs.conf
    [ -f "$bl_conf" ] || return 1
    awk -v n="$1" -v a="$2" '
        /^[[:space:]]*#/ { next }
        NF == 0          { next }
        $1 == n && $2 == a { print $3, $4, $5, $6, $7; found = 1; exit }
        END { exit !found }
    ' "$bl_conf"
}

# Download, verify, then extract — in that order. A blob is never unpacked
# before its checksum has been confirmed.
blob_install() {
    bi_name=$1 bi_url=$2 bi_sha=$3 bi_dest=$4 bi_mode=$5 bi_member=$6
    bi_tmp=$SPORE_WORK/blob.$bi_name
    bi_dst=$(rootpath "$bi_dest")

    if ! fetch_url "$bi_url" "$bi_tmp"; then
        if [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
            warn "no CA trust store at /etc/ssl/certs/ca-certificates.crt — HTTPS
         verification cannot succeed. apk carries its own store, so package
         installs work while this does not. Fix: apk add ca-certificates"
        fi
        die "failed to download $bi_name from $bi_url"
    fi

    bi_got=$(sha256_file "$bi_tmp")
    if [ "$bi_got" != "$bi_sha" ]; then
        rm -f "$bi_tmp"
        die "checksum mismatch for $bi_name: expected $bi_sha, got $bi_got"
    fi

    mkdir -p "$(dirname "$bi_dst")"
    if [ "$bi_member" = '-' ]; then
        cp "$bi_tmp" "$bi_dst"
    else
        bi_ex=$SPORE_WORK/blobx.$bi_name
        rm -rf "$bi_ex"; mkdir -p "$bi_ex"
        tar -xzf "$bi_tmp" -C "$bi_ex" || die "failed to extract $bi_name"
        [ -f "$bi_ex/$bi_member" ] || die "$bi_member not found inside $bi_name archive"
        cp "$bi_ex/$bi_member" "$bi_dst"
        rm -rf "$bi_ex"
    fi
    chmod "$bi_mode" "$bi_dst"
    rm -f "$bi_tmp"
}
