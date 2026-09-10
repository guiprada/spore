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
    [ -n "$wz_dir" ] || wz_dir=$(wz_ask 'Directory to create' "./$wz_host")
    [ ! -e "$wz_dir" ] || die "$wz_dir already exists"

    # --- console -------------------------------------------------------------
    wz_head 'Console'
    wz_say 'Keyboard layout, as setup-keymap takes it: "us us", "br br-abnt2",'
    wz_say '"de de-nodeadkeys". Empty leaves the layout alone.'
    wz_keymap=$(wz_ask 'Keyboard' 'us us')
    wz_say ''
    wz_say 'Timezone as a zone name — America/Sao_Paulo, Europe/Lisbon, UTC.'
    wz_tz=$(wz_ask 'Timezone' 'UTC')

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
    mkdir -p "$wz_dir/spore/modules" "$wz_dir/spore/keys" \
             "$wz_dir/spore/secrets" "$wz_dir/spore/files" ||
        die "cannot create $wz_dir"
    SPORE_DIR=$wz_dir/spore

    cat > "$SPORE_DIR/spore.conf" <<CONF
FORMAT=1
HOST=$wz_host
MODULES="repos system net users ssh apkovl"
# The private key that decrypts this spore's secrets. Relative, so it resolves
# against the spore itself — the same line is correct here and on the target.
SECRETS_IDENTITY=../identity
CONF

    printf 'REPOS_COMMUNITY=yes\n' > "$SPORE_DIR/modules/repos.conf"

    {
        printf '# As setup-keymap takes them: "<layout> <variant>".\n'
        printf 'SYSTEM_KEYMAP=%s\n' "\"$wz_keymap\""
        printf 'SYSTEM_TIMEZONE=%s\n' "$wz_tz"
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
        (umask 077; age-keygen -o "$wz_dir/identity" 2>/dev/null) &&
            age-keygen -y "$wz_dir/identity" > "$SPORE_DIR/secrets/recipients" 2>/dev/null &&
            wz_keyed=yes
        chmod 600 "$wz_dir/identity" 2>/dev/null || true
        [ "$wz_keyed" = yes ] || rm -f "$SPORE_DIR/secrets/recipients" "$wz_dir/identity"
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
         passwords were set. Install age, then:
             age-keygen -o $wz_dir/identity
             age-keygen -y $wz_dir/identity > $SPORE_DIR/secrets/recipients"
    fi

    # --- what now ------------------------------------------------------------
    wz_head "Created $wz_dir"
    printf '\n' >&2
    cat >&2 <<SUMMARY
  $wz_host, $wz_mode on $wz_iface$([ "$wz_mode" = static ] && printf ' (%s)' "$wz_addr")
  account $wz_user$([ "$wz_doas" = yes ] && printf ' with doas')$([ -n "$wz_key" ] && printf ', key installed' || printf ', %sno key%s' "$_c_yellow" "$_c_reset")
  ssh $wz_ssh$([ "$wz_ssh" = yes ] && printf ' on port %s' "$wz_port")
  keymap $wz_keymap, timezone $wz_tz

Next, make the boot medium — this erases the disk you name:

  spore media /dev/sdX alpine-standard-*.iso

then write this machine to it:

  sudo mkdir -p /mnt/data /mnt/esp
  sudo mount /dev/sdX2 /mnt/data
  sudo mount /dev/sdX1 /mnt/esp
  spore install $wz_dir /mnt/data /mnt/esp
  sudo umount /mnt/data /mnt/esp

Anything you change in $wz_dir/spore afterwards needs another
\`spore install\` to reach the disk. That is the whole loop.
SUMMARY

    if [ -z "$wz_key" ]; then
        warn "no key was installed, so ssh is off and this machine will only be
         reachable at its console. Put a public key at
         $SPORE_DIR/keys/$wz_user.authorized_keys and set SSH_ENABLED=yes."
    fi
}
