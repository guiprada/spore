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

# --- setting a password ------------------------------------------------------
#
# Three steps spread across three places. The wizard hashed, encrypted and wrote
# in one function; `spore seal` did only the last and would happily take the
# plaintext for a hash; and the documented way to set a password on a spore that
# already existed was
#
#     openssl passwd -6 | spore -s <spore> seal root.password
#
# — a pipeline, a flag to remember, and a silent lockout if you forget it. That
# is the shape of thing this project exists to delete, so it is one command.

# secret_hash_password — plaintext on stdin, crypt hash on stdout.
#
# openssl is on every workstation that is not Alpine, and busybox's cryptpw is
# on every one that is; between them there is no machine that can write a spore
# and cannot hash a password.
secret_hash_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl passwd -6 -stdin
    elif command -v cryptpw >/dev/null 2>&1; then
        cryptpw -m sha512
    else
        return 127
    fi
}

# secret_ask_password <who> — sets SPORE_PW, or returns 1 having said why.
#
# Twice, with the echo off, and never through a file or an argument: the
# plaintext lives in a shell variable and goes when the process does. A pipe is
# read as one line instead, so this is scriptable without becoming a command
# line anyone can see in ps.
secret_ask_password() {
    sap_who=$1
    SPORE_PW=''
    if [ ! -t 0 ]; then
        IFS= read -r SPORE_PW || return 1
        [ -n "$SPORE_PW" ] || { warn "nothing on stdin, so nothing was set."; return 1; }
        return 0
    fi

    sap_tty=$(stty -g 2>/dev/null || true)
    sap_restore() { [ -n "$sap_tty" ] && stty "$sap_tty" 2>/dev/null; printf '\n' >&2; }
    printf 'Password for %s: ' "$sap_who" >&2
    stty -echo 2>/dev/null || true
    if ! IFS= read -r SPORE_PW; then sap_restore; SPORE_PW=''; return 1; fi
    printf '\nAgain: ' >&2
    if ! IFS= read -r sap_again; then sap_restore; SPORE_PW=''; return 1; fi
    sap_restore

    if [ -z "$SPORE_PW" ]; then
        sap_again=''
        warn "an empty password is not a password. Nothing was changed."
        return 1
    fi
    if [ "$SPORE_PW" != "$sap_again" ]; then
        sap_again='' SPORE_PW=''
        warn "they do not match. Nothing was changed."
        return 1
    fi
    sap_again=''
    return 0
}

# secret_seal_password <who> — ask, hash, seal. 1 if nothing was sealed.
secret_seal_password() {
    ssp_who=$1
    ssp_rcpt=$SPORE_DIR/secrets/recipients
    [ -f "$ssp_rcpt" ] ||
        die "no secrets/recipients in this spore, so nothing can be sealed into
         it. \`spore new\` writes one; otherwise put an age public key there."
    command -v "$SPORE_AGE" >/dev/null 2>&1 ||
        die "age is not installed, so nothing can be sealed."

    secret_ask_password "$ssp_who" || return 1

    if ! ssp_hash=$(printf '%s\n' "$SPORE_PW" | secret_hash_password); then
        SPORE_PW=''
        warn "no way to hash a password here — install openssl, or busybox's
         cryptpw. The hash is what travels; the password itself never does."
        return 1
    fi
    SPORE_PW=''

    # What comes back is what `chpasswd -e` will write into /etc/shadow, so a
    # hasher that returned something else would produce an account no password
    # matches, with nothing said.
    case $ssp_hash in
        '$'*'$'*) : ;;
        *) ssp_hash=''
           warn "the hasher did not return a crypt hash. Nothing was sealed."
           return 1 ;;
    esac

    mkdir -p "$SPORE_DIR/secrets"
    printf '%s\n' "$ssp_hash" |
        "$SPORE_AGE" --encrypt -R "$ssp_rcpt" \
            -o "$SPORE_DIR/secrets/$ssp_who.password.age" ||
        die "could not seal the password for $ssp_who"
    ssp_hash=''
    say "sealed secrets/$ssp_who.password.age"
}
