# lib/secret.sh — secrets travel inside the spore, always encrypted.
#
# A spore carries its secrets as age ciphertext (secrets/<name>.age) plus the
# public recipients (secrets/recipients). Both are safe to commit. The private
# identity lives on the host and never enters the spore — that is the one thing
# a spore cannot carry, because it is what unlocks everything it does carry.
#
# Plaintext never reaches the plan: the content store holds a template with
# @@SECRET:name@@ markers, and substitution happens in the executor at write
# time, into a file created under umask 077.

: "${SPORE_AGE:=age}"

secret_path()   { printf '%s/secrets/%s.age' "$SPORE_DIR" "$1"; }
secret_exists() { [ -f "$(secret_path "$1")" ]; }

# A relative path resolves against the spore, not the working directory. The
# identity cannot live inside the spore — it is what unlocks everything the spore
# carries — but it does need to sit beside it, and a seed-booted machine mounts
# the spore at a path nobody can predict.
secret_identity() {
    if [ -n "${SPORE_IDENTITY:-}" ]; then
        si_p=$SPORE_IDENTITY
    else
        si_p=$(conf_get "$SPORE_DIR/spore.conf" SECRETS_IDENTITY /etc/spore/identity)
    fi
    case $si_p in
        /*) printf '%s' "$si_p" ;;
        *)  printf '%s/%s' "$SPORE_DIR" "$si_p" ;;
    esac
}

secret_can_decrypt() {
    command -v "$SPORE_AGE" >/dev/null 2>&1 && [ -f "$(secret_identity)" ]
}

secret_decrypt() {
    sd_name=$1
    sd_file=$(secret_path "$sd_name")
    sd_id=$(secret_identity)
    [ -f "$sd_file" ] || die "no such secret in this spore: $sd_name"
    command -v "$SPORE_AGE" >/dev/null 2>&1 || die "age is not installed; cannot decrypt '$sd_name'"
    [ -f "$sd_id" ] || die "secret '$sd_name' needs the identity at $sd_id (set SECRETS_IDENTITY in spore.conf, or SPORE_IDENTITY)"
    "$SPORE_AGE" --decrypt -i "$sd_id" "$sd_file" || die "failed to decrypt secret: $sd_name"
}

# Secret names referenced by a template, read from stdin.
secret_markers() {
    grep -o '@@SECRET:[A-Za-z0-9_.-]\{1,\}@@' 2>/dev/null | sed 's/^@@SECRET://; s/@@$//' | sort -u
}

# Is this template nothing but a single marker? Then the secret IS the file, and
# it is written byte for byte — which is what an ssh host key needs.
secret_is_whole_file() {
    siwf_n=$(tr -d '\n' < "$1")
    case $siwf_n in
        @@SECRET:*@@) [ "$(printf '%s\n' "$siwf_n" | secret_markers | wc -l)" = 1 ] ;;
        *) return 1 ;;
    esac
}

# Render a template to stdout with every marker replaced. Substitution is
# literal (index/substr, never a regex), so a secret containing &, \ or / is
# inserted exactly as stored.
secret_render() {
    sr_tpl=$1
    if secret_is_whole_file "$sr_tpl"; then
        secret_decrypt "$(tr -d '\n' < "$sr_tpl" | secret_markers)"
        return 0
    fi

    cp "$sr_tpl" "$SPORE_WORK/render.in"
    secret_markers < "$sr_tpl" > "$SPORE_WORK/render.names"
    while read -r sr_name; do
        [ -n "$sr_name" ] || continue
        (umask 077; secret_decrypt "$sr_name" > "$SPORE_WORK/render.val")
        awk -v marker="@@SECRET:$sr_name@@" -v vf="$SPORE_WORK/render.val" '
            BEGIN { getline val < vf; close(vf) }
            {
                line = $0; out = ""
                while ((p = index(line, marker)) > 0) {
                    out = out substr(line, 1, p - 1) val
                    line = substr(line, p + length(marker))
                }
                print out line
            }
        ' "$SPORE_WORK/render.in" > "$SPORE_WORK/render.out"
        mv -f "$SPORE_WORK/render.out" "$SPORE_WORK/render.in"
        rm -f "$SPORE_WORK/render.val"
    done < "$SPORE_WORK/render.names"

    cat "$SPORE_WORK/render.in"
    rm -f "$SPORE_WORK/render.in" "$SPORE_WORK/render.names"
}

secret_list() {
    [ -d "$SPORE_DIR/secrets" ] || return 0
    find "$SPORE_DIR/secrets" -maxdepth 1 -name '*.age' -type f -exec basename {} .age \; | sort
}
