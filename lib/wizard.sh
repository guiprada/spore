# lib/wizard.sh — the guided path.
#
# `spore new` collapses the mechanical part of preparing a machine, but it still
# leaves you to find out which keys exist, in which file, and which of them the
# ssh module will refuse to build without. That is a lot of reading for the
# first machine, and the failures land at boot rather than at the keyboard.
#
# So this asks. Nothing here is privileged and nothing is destructive: it writes
# a machine directory and tells you the two commands that follow. Writing the
# disk is `spore media`, kept separate because it erases one.
#
# The spore it writes is minimal on purpose — the modules you answered questions
# about, and no others. An example full of volumes and a file server you did not
# ask for is a worse starting point than a short file you understand.

wz_ask() {
    # wz_ask <prompt> <default>
    if [ -n "${2-}" ]; then
        printf '%s%s%s [%s]: ' "$_c_bold" "$1" "$_c_reset" "$2" >&2
    else
        printf '%s%s%s: ' "$_c_bold" "$1" "$_c_reset" >&2
    fi
    if IFS= read -r wz_a; then :; else wz_a=''; fi
    [ -n "$wz_a" ] || wz_a=${2-}
    printf '%s' "$wz_a"
}

wz_yn() {
    # wz_yn <prompt> <yes|no default>
    wz_d=$2
    while :; do
        wz_r=$(wz_ask "$1 (y/n)" "$wz_d")
        case $wz_r in
            y|Y|yes|YES|Yes) printf 'yes'; return 0 ;;
            n|N|no|NO|No)    printf 'no';  return 0 ;;
            *) printf '  answer y or n\n' >&2 ;;
        esac
    done
}

wz_say()  { printf '%s\n' "$*" >&2; }
wz_head() { printf '\n%s%s%s\n' "$_c_bold" "$*" "$_c_reset" >&2; }

# Seal a password, twice-confirmed, without it ever reaching the terminal or a
# file. openssl hashes it and spore encrypts the hash, so what lands in the
# spore is already useless to anyone without the identity.
wz_seal_password() {
    wz_who=$1
    command -v openssl >/dev/null 2>&1 || {
        warn "openssl is not installed, so no password could be set for $wz_who."
        return 0
    }
    wz_hash=$(openssl passwd -6 2>/dev/null) || {
        warn "no password set for $wz_who."
        return 0
    }
    [ -n "$wz_hash" ] || { warn "no password set for $wz_who."; return 0; }
    printf '%s' "$wz_hash" | "$SPORE_AGE" --encrypt -R "$SPORE_DIR/secrets/recipients" \
        -o "$SPORE_DIR/secrets/$wz_who.password.age" ||
        die "could not seal the password for $wz_who"
    wz_say "  sealed secrets/$wz_who.password.age"
}

wizard() {
    wz_dir=${1:-}

    cat >&2 <<'INTRO'

spore setup — prepare one machine.

Answers go into a directory you keep and edit; nothing here touches a disk.
Press Enter to take the default in brackets.
INTRO

    # --- identity ------------------------------------------------------------
    wz_head 'The machine'
    while :; do
        wz_host=$(wz_ask 'Hostname' 'alpine')
        case $wz_host in
            ''|*[!A-Za-z0-9_-]*) wz_say '  letters, digits, - and _ only' ;;
            *) break ;;
        esac
    done
    # Not asked. The hostname already determines it, and a path typed at a
    # prompt is one more thing to get wrong for no decision gained — pass one as
    # A directory named on the command line is a destination, so it is checked
    # now rather than after fifteen questions. Without one the machine goes onto
    # the disk, and there is nothing on this workstation to collide with.
    [ -z "$wz_dir" ] || wz_claim_dir "$wz_dir"

    # --- console -------------------------------------------------------------
    wz_head 'Console'
    wz_say 'Keyboard layout, as setup-keymap takes it: "us us", "br br-abnt2",'
    wz_say '"de de-nodeadkeys". Empty leaves the layout alone.'
    wz_keymap=$(wz_ask 'Keyboard' 'us us')
    wz_say ''
    wz_say 'Timezone as a zone name — America/Sao_Paulo, Europe/Lisbon, UTC.'
    wz_tz=$(wz_ask 'Timezone' 'UTC')
    wz_say ''
    wz_say 'Time sync. A machine with no battery-backed clock boots in 1970, and'
    wz_say 'a clock that far out makes every certificate look not-yet-valid.'
    wz_ntp=$(wz_ask 'NTP client: chrony, busybox, openntpd or none' 'chrony')

    # --- network -------------------------------------------------------------
    wz_head 'Network'
    wz_iface=$(wz_ask 'Interface' 'eth0')
    wz_mode=$(wz_ask 'Address: dhcp or static' 'dhcp')
    wz_addr='' wz_mask='' wz_gw='' wz_dns=''
    case $wz_mode in
        static)
            while [ -z "$wz_addr" ]; do wz_addr=$(wz_ask 'IP address' ''); done
            wz_mask=$(wz_ask 'Netmask' '255.255.255.0')
            wz_gw=$(wz_ask 'Gateway' '')
            wz_dns=$(wz_ask 'DNS servers, space separated' "${wz_gw:-1.1.1.1}")
            ;;
        *) wz_mode=dhcp ;;
    esac
    wz_say ''
    wz_say 'Package mirror. Blank keeps whatever the image came with, which is'
    wz_say 'the global CDN — a nearer one is usually much faster.'
    wz_say 'For example: https://mirror.ufpr.br/alpine'
    wz_mirror=$(wz_ask 'Mirror URL' '')

    # --- account -------------------------------------------------------------
    wz_head 'Account'
    wz_say 'root already exists and is not created here. This is the account you'
    wz_say 'log in as.'
    while :; do
        wz_user=$(wz_ask 'Username' "$(bootstrap_user)")
        case $wz_user in
            ''|root|*[!a-z0-9_-]*) wz_say '  lowercase letters, digits, - and _; not root' ;;
            *) break ;;
        esac
    done
    wz_doas=$(wz_yn "May $wz_user use doas to become root?" y)

    wz_key=$(bootstrap_pubkey)
    if [ -n "$wz_key" ]; then
        wz_key=$(wz_ask 'Public key to install' "$wz_key")
    else
        wz_say ''
        wz_say 'No public key found in your ~/.ssh. Without one, and with root'
        wz_say 'login and password auth off, nothing can reach this machine over'
        wz_say 'the network. Make one with: ssh-keygen -t ed25519'
        wz_key=$(wz_ask 'Public key to install (blank to skip)' '')
    fi
    if [ -n "$wz_key" ] && [ ! -f "$wz_key" ]; then
        die "no such file: $wz_key"
    fi

    # --- ssh -----------------------------------------------------------------
    wz_head 'Remote access'
    if [ -n "$wz_key" ]; then
        wz_ssh=$(wz_yn 'Enable ssh?' y)
    else
        wz_say 'ssh cannot be enabled without a key for the account: nothing'
        wz_say 'would be able to log in, and spore refuses to build that.'
        wz_ssh=no
    fi
    wz_port=22
    [ "$wz_ssh" = yes ] && wz_port=$(wz_ask 'ssh port' 22)

    # --- write ---------------------------------------------------------------
    # Built in a staging area first, so where it ends up is still an open
    # question at this point: onto a disk, or into a directory if there is no
    # disk to hand. Answering fifteen questions and then losing them to a
    # failed mount would be its own kind of insult.
    wz_stage=$SPORE_WORK/machine
    mkdir -p "$wz_stage/spore/modules" "$wz_stage/spore/keys" \
             "$wz_stage/spore/secrets" "$wz_stage/spore/files" ||
        die "cannot create $wz_stage"
    SPORE_DIR=$wz_stage/spore

    cat > "$SPORE_DIR/spore.conf" <<CONF
FORMAT=1
HOST=$wz_host
MODULES="repos system net users ssh apkovl"
# The private key that decrypts this spore's secrets. Relative, so it resolves
# against the spore itself — the same line is correct here and on the target.
SECRETS_IDENTITY=../identity
CONF

    {
        printf 'REPOS_COMMUNITY=yes\n'
        if [ -n "$wz_mirror" ]; then
            printf 'REPOS_MIRROR=%s\n' "$wz_mirror"
        else
            printf '# REPOS_MIRROR=https://mirror.ufpr.br/alpine\n'
        fi
    } > "$SPORE_DIR/modules/repos.conf"

    {
        printf '# As setup-keymap takes them: "<layout> <variant>".\n'
        printf 'SYSTEM_KEYMAP=%s\n' "\"$wz_keymap\""
        printf 'SYSTEM_TIMEZONE=%s\n' "$wz_tz"
        printf 'SYSTEM_NTP=%s\n' "$wz_ntp"
    } > "$SPORE_DIR/modules/system.conf"

    {
        printf 'NET_HOSTNAME=%s\n' "$wz_host"
        printf 'NET_IFACE=%s\n'    "$wz_iface"
        printf 'NET_MODE=%s\n'     "$wz_mode"
        if [ "$wz_mode" = static ]; then
            printf 'NET_ADDRESS=%s\n' "$wz_addr"
            printf 'NET_NETMASK=%s\n' "$wz_mask"
            [ -n "$wz_gw" ]  && printf 'NET_GATEWAY=%s\n' "$wz_gw"
            [ -n "$wz_dns" ] && printf 'NET_DNS=%s\n' "\"$wz_dns\""
        fi
    } > "$SPORE_DIR/modules/net.conf"

    {
        printf '# An account is only reachable over ssh if keys/<user>.authorized_keys\n'
        printf '# exists here. spore checks, and refuses to enable ssh if nothing could\n'
        printf '# log in.\n'
        printf 'USERS=%s\n' "\"$wz_user\""
        printf 'USERS_DOAS=%s\n' "$([ "$wz_doas" = yes ] && printf '"%s"' "$wz_user" || printf '""')"
        printf '\n'
        printf '# Passwords travel sealed, never in cleartext:\n'
        printf '#   openssl passwd -6 | spore -s <spore> seal %s.password\n' "$wz_user"
        printf '#   openssl passwd -6 | spore -s <spore> seal root.password\n'
    } > "$SPORE_DIR/modules/users.conf"

    {
        printf 'SSH_ENABLED=%s\n' "$wz_ssh"
        printf 'SSH_PORT=%s\n' "$wz_port"
        printf 'SSH_PERMIT_ROOT_LOGIN=no\n'
        printf 'SSH_PASSWORD_AUTH=no\n'
    } > "$SPORE_DIR/modules/ssh.conf"

    {
        printf '# Where lbu commits the apkovl — the only thing that makes a\n'
        printf '# diskless machine remember anything. Unset means beside the spore,\n'
        printf '# on the partition it was found on, which is what you want here.\n'
        printf '# APKOVL_BACKUPDIR=/media/storage/data\n'
    } > "$SPORE_DIR/modules/apkovl.conf"

    : > "$SPORE_DIR/packages"

    [ -n "$wz_key" ] && cp "$wz_key" "$SPORE_DIR/keys/$wz_user.authorized_keys"

    # --- keys and passwords --------------------------------------------------
    wz_keyed=no
    if command -v age-keygen >/dev/null 2>&1 && command -v "$SPORE_AGE" >/dev/null 2>&1; then
        (umask 077; age-keygen -o "$wz_stage/identity" 2>/dev/null) &&
            age-keygen -y "$wz_stage/identity" > "$SPORE_DIR/secrets/recipients" 2>/dev/null &&
            wz_keyed=yes
        chmod 600 "$wz_stage/identity" 2>/dev/null || true
        [ "$wz_keyed" = yes ] || rm -f "$SPORE_DIR/secrets/recipients" "$wz_stage/identity"
    fi

    if [ "$wz_keyed" = yes ] && [ -t 0 ]; then
        wz_head 'Passwords'
        wz_say 'Sealed into the spore and applied at first boot, so nothing has to'
        wz_say 'be typed at the machine. Empty skips.'
        wz_say ''
        if [ "$wz_doas" = yes ]; then
            wz_say "doas prompts for $wz_user's own password, so without one it cannot work."
        fi
        wz_say "Password for $wz_user:"
        wz_seal_password "$wz_user"
        wz_say ''
        wz_say 'Password for root (console rescue; ssh will not accept it):'
        wz_seal_password root
    elif [ "$wz_keyed" = no ]; then
        warn "age is not installed, so this spore cannot carry secrets and no
         passwords were set. Install age and start again."
    fi

    # --- what now ------------------------------------------------------------
    wz_head "$wz_host is ready"
    printf '\n' >&2
    cat >&2 <<SUMMARY
  $wz_mode on $wz_iface$([ "$wz_mode" = static ] && printf ' (%s)' "$wz_addr")
  account $wz_user$([ "$wz_doas" = yes ] && printf ' with doas')$([ -n "$wz_key" ] && printf ', key installed' || printf ', %sno key%s' "$_c_yellow" "$_c_reset")
  ssh $wz_ssh$([ "$wz_ssh" = yes ] && printf ' on port %s' "$wz_port")
  keymap $wz_keymap, timezone $wz_tz, ntp $wz_ntp
  mirror ${wz_mirror:-whatever the image came with}
SUMMARY

    # A machine goes on a disk. Keeping a second copy on the workstation only
    # raises the question of which one is real — the spore is the portable thing,
    # so it lives where it runs from. A directory is the fallback for when there
    # is no disk in your hand yet, and for anyone who asked for one by name.
    if [ -z "$wz_dir" ] && wz_disk "$wz_stage" "$wz_host"; then
        [ -n "$wz_key" ] || warn "nothing can log in over the network: ssh is off
         because no key was installed."
        return 0
    fi

    wz_land "$wz_stage" "$wz_host"
}

# Move the staged machine into a directory and say what is left to do.
wz_land() {
    wl_stage=$1
    wl_host=$2

    if [ -z "$wz_dir" ]; then
        wl_home=$(bootstrap_home)
        wz_dir=${wl_home:+$wl_home/machines}
        wz_dir=${wz_dir:-.}/$wl_host
        wz_claim_dir "$wz_dir"
    fi
    mkdir -p "$(dirname "$wz_dir")" || die "cannot create $(dirname "$wz_dir")"
    mv "$wl_stage" "$wz_dir" || die "cannot write $wz_dir"
    wz_dir=$(CDPATH='' cd -- "$wz_dir" && pwd)

    cat >&2 <<SUMMARY

Saved to $wz_dir — it is not on a disk yet.

  sudo spore media /dev/sdX alpine-standard-*.iso
  sudo spore install $wz_dir /dev/sdX
SUMMARY

    if [ -z "$wz_key" ]; then
        warn "no key was installed, so ssh is off and this machine will only be
         reachable at its console. Put a public key at
         $wz_dir/spore/keys/$wz_user.authorized_keys and set SSH_ENABLED=yes."
    fi
}

# Claim a directory as the destination, replacing a machine already there only
# when told to. Answering yes to a prompt is not consent to delete an arbitrary
# path, so anything that is not already a machine is refused outright.
wz_claim_dir() {
    wc_d=$1
    [ -e "$wc_d" ] || return 0

    [ -f "$wc_d/spore/spore.conf" ] ||
        die "$wc_d already exists and is not a machine directory.
        Name somewhere else:  spore setup <directory>"

    wz_say ''
    wz_say "There is already a machine at $wc_d. Starting again replaces it —"
    if [ -f "$wc_d/identity" ]; then
        wz_say 'including its identity, so every password and host key sealed'
        wz_say 'into it becomes undecryptable.'
    fi
    [ "$(wz_yn 'Replace it?' n)" = yes ] ||
        die "left $wc_d alone.
        To change one thing, edit the file rather than starting again:
            \$EDITOR $wc_d/spore/modules/<module>.conf
            sudo spore install $wc_d /dev/sdX"
    rm -rf "$wc_d"
}

# The newest Alpine ISO lying around, so the common case is one Enter.
wz_find_iso() {
    wf_best=''
    for wf_d in "$(bootstrap_home)/Downloads" "$(bootstrap_home)" .; do
        [ -d "$wf_d" ] || continue
        for wf_i in "$wf_d"/alpine-*.iso; do
            [ -f "$wf_i" ] || continue
            if [ -z "$wf_best" ] || [ "$wf_i" -nt "$wf_best" ]; then
                wf_best=$wf_i
            fi
        done
        if [ -n "$wf_best" ]; then
            printf '%s' "$wf_best"
            return 0
        fi
    done
    return 0
}

# Everything from here needs root. The answers were gathered and the directory
# written as the ordinary user on purpose — a machine directory owned by root is
# one you cannot edit afterwards, and editing it afterwards is the whole loop.
wz_disk() {
    wd_dir=$1
    wd_host=$2

    wz_head 'The disk'
    wz_say 'A machine lives on the disk it boots from — that is where this one'
    wz_say 'goes. Answer no and it is saved here instead, to write later.'
    [ "$(wz_yn 'Write a USB stick now?' y)" = yes ] || return 1

    wd_sudo=''
    if [ "$(id -u)" != 0 ]; then
        command -v sudo >/dev/null 2>&1 ||
            { warn "sudo is not installed, so the disk cannot be written from here."; return 1; }
        wd_sudo=sudo
    fi

    wz_say ''
    lsblk -dno PATH,SIZE,TRAN,MODEL 2>/dev/null | sed 's/^/  /' >&2 ||
        wz_say '  (lsblk is not installed — you will have to know the path)'
    wz_say ''
    wz_say 'The removable one. Everything on it is destroyed.'
    wd_dev=$(wz_ask 'Device' '')
    [ -n "$wd_dev" ] || { wz_say 'nothing named; skipping'; return 1; }
    [ -b "$wd_dev" ] || { warn "$wd_dev is not a block device"; return 1; }

    wz_say ''
    wd_iso=$(wz_ask 'Alpine ISO' "$(wz_find_iso)")
    [ -f "$wd_iso" ] || { warn "no such file: $wd_iso"; return 1; }

    # media does its own listing and makes the path be typed back, so the
    # confirmation lives there rather than being asked twice.
    wz_say ''
    "$wd_sudo" "$SPORE_PREFIX/bin/spore" media "$wd_dev" "$wd_iso" ||
        { warn 'the medium was not written; nothing else was done'; return 1; }

    wz_say ''
    "$wd_sudo" "$SPORE_PREFIX/bin/spore" install "$wd_dir" "$wd_dev" ||
        { warn 'the medium is made, but this machine is not on it yet.'; return 1; }

    cat >&2 <<DONE

$wd_host is on $wd_dev. Boot it.

To change it later, mount the data partition and edit the files there —
the spore on the disk is the machine, there is no other copy:

  sudo mount ${wd_dev}2 /mnt
  \$EDITOR /mnt/spore/modules/net.conf

then on the machine itself:  spore apply --persist
DONE
    return 0
}
