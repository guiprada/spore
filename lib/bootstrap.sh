# lib/bootstrap.sh — creating and installing a machine, in two commands.
#
# The workstation side is where this project is most error-prone. Preparing a
# machine by hand means: copy the example, rename it in three files, generate a
# keypair, derive a recipients file, get the permissions on the identity right,
# remember your own public key or nothing can log in, build the seed overlay,
# and copy the result onto a removable disk whose mount point nobody can
# predict. Every one of those has its own way to fail quietly, and most of them
# only announce themselves as a machine that boots and cannot be reached.
#
# So: `spore new` makes the directory, `spore install` writes it to a disk. Both
# refuse rather than guess.

# bootstrap_set <file> <key> <value> — replace an assignment, or append one.
bootstrap_set() {
    bs_f=$1 bs_k=$2 bs_v=$3
    if conf_has "$bs_f" "$bs_k"; then
        if sed "s|^[[:space:]]*${bs_k}[[:space:]]*=.*|${bs_k}=${bs_v}|" "$bs_f" > "$bs_f.new"; then
            mv "$bs_f.new" "$bs_f" || die "could not rewrite $bs_k in $bs_f"
        else
            rm -f "$bs_f.new"
            die "could not rewrite $bs_k in $bs_f"
        fi
    else
        printf '%s=%s\n' "$bs_k" "$bs_v" >> "$bs_f"
    fi
}

# The account the spore should create. Under sudo, $USER is root — and `root` is
# not an account this spore creates, so fall back rather than emit nonsense.
bootstrap_user() {
    bu_n=${SUDO_USER:-${USER:-}}
    [ -n "$bu_n" ] || bu_n=$(id -un 2>/dev/null || true)
    case $bu_n in
        ''|root|*[!a-z0-9_-]*) bu_n='admin' ;;
    esac
    printf '%s' "$bu_n"
}

# The home directory to look in for a public key — the invoking human's, not
# root's, when this was run through sudo.
bootstrap_home() {
    if [ -n "${SUDO_USER:-}" ]; then
        bh_d=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
        if [ -n "${bh_d:-}" ]; then printf '%s' "$bh_d"; return 0; fi
    fi
    printf '%s' "${HOME:-}"
}

# The single most consequential thing to get wrong: with root login and password
# auth both off — the defaults — a machine with no authorized key is a machine
# nobody can reach. Find the caller's key and install it, rather than leave a
# placeholder that looks like a login and is nobody's.
bootstrap_pubkey() {
    if [ -n "${SPORE_PUBKEY:-}" ]; then
        [ -f "$SPORE_PUBKEY" ] || die "SPORE_PUBKEY is set but $SPORE_PUBKEY does not exist"
        printf '%s' "$SPORE_PUBKEY"
        return 0
    fi
    bp_home=$(bootstrap_home)
    [ -n "$bp_home" ] || return 0
    for bp_k in id_ed25519 id_ecdsa id_rsa; do
        if [ -f "$bp_home/.ssh/$bp_k.pub" ]; then
            printf '%s' "$bp_home/.ssh/$bp_k.pub"
            return 0
        fi
    done
    return 0
}

# A directory is a mount point when its device differs from its parent's. That
# beats matching a path against /proc/mounts, which sees only absolute paths and
# escapes spaces in them as \040 — so `spore install m ./DATA`, or a mount under
# a username with a space in it, would be told the disk is not mounted when it
# plainly is.
bootstrap_mountpoint() {
    bm_p=$1
    [ -d "$bm_p" ] || return 1
    bm_a=$(stat -c '%d' "$bm_p" 2>/dev/null || true)
    bm_b=$(stat -c '%d' "$bm_p/.." 2>/dev/null || true)
    if [ -n "$bm_a" ] && [ -n "$bm_b" ]; then
        [ "$bm_a" != "$bm_b" ]
        return
    fi
    bm_abs=$(CDPATH='' cd -- "$bm_p" 2>/dev/null && pwd) || return 1
    awk -v t="$bm_abs" '{ gsub(/\\040/, " ", $2) } $2 == t { f = 1 } END { exit !f }' \
        /proc/mounts 2>/dev/null
}

# Plan the spore the way the target will, not the way this workstation would.
# On a workstation `ssh` and `dufs` are skipped for want of OpenRC and `users`
# for want of root — which is precisely the set whose plan-time refusals are
# worth hearing here, while the disk is still in your hand. Root is assumed to
# have no password because on a stock Alpine it has none, which is the
# assumption that makes the ssh module strictest.
bootstrap_check() {
    bc_spore=$1
    bc_out=$SPORE_WORK/check.out
    if (
        SPORE_FACT_ROOT=yes
        SPORE_FACT_INIT=openrc
        SPORE_FACT_NETADMIN=yes
        SPORE_FACT_PERSIST=lbu
        SPORE_FACT_ROOT_PASSWORD=empty
        export SPORE_PREFIX SPORE_FACT_ROOT SPORE_FACT_INIT SPORE_FACT_NETADMIN \
               SPORE_FACT_PERSIST SPORE_FACT_ROOT_PASSWORD
        unset SPORE_DIR SPORE_WORK SPORE_WORK_OWNED SPORE_ROOT
        exec "$SPORE_PREFIX/bin/spore" -s "$bc_spore" plan
    ) > "$bc_out" 2>&1; then
        rm -f "$bc_out"
        return 0
    fi

    printf '%sthis spore does not plan for an Alpine target:%s\n\n' "$_c_red" "$_c_reset" >&2
    sed 's/^/    /' "$bc_out" >&2
    printf '\n' >&2
    rm -f "$bc_out"
    return 1
}

# new_machine <name> [dir]
new_machine() {
    nm_name=$1
    nm_dir=${2:-./$1}

    case $nm_name in
        ''|*[!A-Za-z0-9_-]*) die "'$nm_name' is not a usable hostname (letters, digits, _ and - only)" ;;
    esac
    [ ! -e "$nm_dir" ] || die "$nm_dir already exists"

    nm_tmpl=$SPORE_PREFIX/examples/example.spore
    [ -d "$nm_tmpl" ] || die "no template at $nm_tmpl"

    nm_user=$(bootstrap_user)
    nm_key=$(bootstrap_pubkey)

    mkdir -p "$nm_dir" || die "cannot create $nm_dir"
    cp -r "$nm_tmpl" "$nm_dir/spore"
    mkdir -p "$nm_dir/spore/secrets" "$nm_dir/spore/keys" "$nm_dir/spore/files"

    bootstrap_set "$nm_dir/spore/spore.conf" HOST "$nm_name"
    # The identity sits beside the spore, so it travels with it on the data
    # partition and is still never inside it. Relative to the spore directory,
    # which is what makes the same path work here and on the target.
    bootstrap_set "$nm_dir/spore/spore.conf" SECRETS_IDENTITY '../identity'
    bootstrap_set "$nm_dir/spore/modules/net.conf" NET_HOSTNAME "$nm_name"
    bootstrap_set "$nm_dir/spore/modules/users.conf" USERS "\"$nm_user\""
    bootstrap_set "$nm_dir/spore/modules/users.conf" USERS_DOAS "\"$nm_user\""

    # The example ships a placeholder key, which reads as a usable login while
    # being nobody's.
    rm -f "$nm_dir/spore/keys"/*.authorized_keys
    if [ -n "$nm_key" ]; then
        cp "$nm_key" "$nm_dir/spore/keys/$nm_user.authorized_keys"
    fi

    nm_keyed=no
    if command -v "$SPORE_AGE" >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
        (umask 077; age-keygen -o "$nm_dir/identity" 2>/dev/null) &&
            age-keygen -y "$nm_dir/identity" > "$nm_dir/spore/secrets/recipients" 2>/dev/null &&
            nm_keyed=yes
        chmod 600 "$nm_dir/identity" 2>/dev/null || true
        # An empty recipients file is worse than none: `spore seal` would appear
        # to work and encrypt to nobody.
        [ "$nm_keyed" = yes ] || rm -f "$nm_dir/spore/secrets/recipients" "$nm_dir/identity"
    fi

    printf 'created %s\n\n' "$nm_dir"
    printf '  spore/      this machine, plain text — edit it\n'
    printf '  identity    private key, 0600, never commit it\n\n'
    printf '  host        %s\n' "$nm_name"
    printf '  account     %s%s\n' "$nm_user" \
        "$([ -n "$nm_key" ] && printf ', key from %s' "$nm_key" || printf ', %sno key yet%s' "$_c_yellow" "$_c_reset")"
    printf '  secrets     %s\n\n' \
        "$([ "$nm_keyed" = yes ] && printf 'sealed to spore/secrets/recipients' || printf 'unavailable (no age)')"

    cat <<INFO
Worth editing before you install it:

  spore/modules/net.conf      address, or leave NET_MODE=dhcp
  spore/modules/storage.conf  and volumes.conf — what to mount, and where
  spore/modules/dufs.conf     what to serve, and on which port

Then write it to a mounted data partition. \`install\` plans the spore as the
target would first, so a machine that could not be reached is refused here
rather than discovered after it boots:

  spore install $nm_dir /media/\$USER/DATA
INFO

    if [ -z "$nm_key" ]; then
        warn "no public key found in $(bootstrap_home)/.ssh, so nothing can log in yet.
         Put one at $nm_dir/spore/keys/$nm_user.authorized_keys, or set
         SPORE_PUBKEY and run this again."
    fi
    if [ "$nm_keyed" = no ]; then
        warn "age is not installed, so this spore cannot carry secrets. Install age,
         then:  age-keygen -o $nm_dir/identity
                age-keygen -y $nm_dir/identity > $nm_dir/spore/secrets/recipients"
    fi
}

# install_machine <dir> <target>
install_machine() {
    im_dir=$1
    im_target=$2

    [ -d "$im_dir" ] || die "no such directory: $im_dir"
    [ -f "$im_dir/spore/spore.conf" ] ||
        die "$im_dir does not look like a machine directory (no spore/spore.conf)"
    [ -d "$im_target" ] || die "$im_target does not exist — is the disk mounted?"

    # The spore first: what it says is wrong with it is worth hearing whether or
    # not the disk is mounted, and it is the half you can still fix from here.
    bootstrap_check "$im_dir/spore" || die "refusing to install a spore that will not apply"

    # Writing onto an unmounted directory fills this machine's root filesystem
    # instead of the disk, and is discovered at the target's first boot.
    if ! bootstrap_mountpoint "$im_target"; then
        die "$im_target is not a mount point.
        Copying there would write to this machine's disk, not the removable one,
        and you would only find out when the target failed to boot."
    fi

    if [ "$SPORE_DRYRUN" = 1 ]; then
        printf 'dry run — %s would be written to %s\n\n' "$im_dir" "$im_target"
    fi

    if [ -e "$im_target/spore" ]; then
        [ -d "$im_target/spore" ] || die "$im_target/spore exists and is not a directory"
        [ -f "$im_target/spore/spore.conf" ] ||
            die "$im_target/spore exists but is not a spore — refusing to replace it"
        say "replacing the spore already on $im_target"
        run rm -rf "$im_target/spore"
    fi
    run cp -r "$im_dir/spore" "$im_target/spore"

    if [ -f "$im_dir/identity" ]; then
        run cp "$im_dir/identity" "$im_target/identity"
        # This one key decrypts every secret the spore carries. On a filesystem
        # with real ownership it must not be readable by the accounts the spore
        # creates; on vfat that silently cannot be enforced, which is worth
        # knowing before you rely on it.
        chmod 600 "$im_target/identity" 2>/dev/null || true
        if [ "$SPORE_DRYRUN" != 1 ] &&
           [ "$(stat -c '%a' "$im_target/identity" 2>/dev/null || echo 600)" != 600 ]
        then
            warn "could not restrict $im_target/identity to 0600.
         A vfat partition cannot hold permissions at all, and this is the key
         that decrypts every secret in the spore."
        fi
    fi

    # Built here, now, rather than copied: the overlay carries the tool itself,
    # so a stale one silently boots the target on an older spore than the one
    # you just edited.
    im_seed=$im_target/spore-seed.apkovl.tar.gz
    if [ "$SPORE_DRYRUN" = 1 ]; then
        say "would build $im_seed"
    else
        seed_build "$im_seed"
    fi
    run sync

    if [ "$SPORE_DRYRUN" = 1 ]; then
        printf '\ndry run — nothing was written to %s\n' "$im_target"
        return 0
    fi

    printf '\ninstalled to %s\n\n' "$im_target"
    printf '  spore/                      %s\n' "$(conf_get "$im_dir/spore/spore.conf" HOST '?')"
    printf '  identity                    %s\n' \
        "$([ -f "$im_dir/identity" ] && printf 'copied' || printf 'none in %s' "$im_dir")"
    printf '  spore-seed.apkovl.tar.gz    built from this tool\n\n'
    printf 'Unmount the disk, attach it to a stock Alpine, and boot. The first boot\n'
    printf 'finds the spore, applies it and commits; progress goes to\n'
    printf '/var/log/spore-seed.log on the target.\n'
}
