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

# The prompts assign into a variable you name rather than printing their answer.
# That is not a style preference. Read through `$( )` they ran in a subshell, and
# a subshell cannot stop the wizard — `die` there exits only itself — so when
# stdin ended every prompt went on silently handing back its default, for ever.
# Any loop that rejects its own default then spins until the terminal is killed,
# which is exactly what `while [ -z "$wz_addr" ]` with an empty default did.
wz_ask() {
    # wz_ask <var> <prompt> [default]
    if [ -n "${3-}" ]; then
        printf '%s%s%s [%s]: ' "$_c_bold" "$2" "$_c_reset" "$3" >&2
    else
        printf '%s%s%s: ' "$_c_bold" "$2" "$_c_reset" >&2
    fi
    if IFS= read -r wz_a; then :; else
        printf '\n' >&2
        die "input ended at \"$2\", so nothing was written.
             Answer at a terminal, or feed every answer on stdin."
    fi
    [ -n "$wz_a" ] || wz_a=${3-}
    eval "$1=\$wz_a"
}

wz_yn() {
    # wz_yn <var> <prompt> <y|n default>
    wz_d=$3
    while :; do
        wz_ask wz_r "$2 (y/n)" "$wz_d"
        case $wz_r in
            y|Y|yes|YES|Yes) eval "$1=yes"; return 0 ;;
            n|N|no|NO|No)    eval "$1=no";  return 0 ;;
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
        wz_ask wz_host 'Hostname' 'alpine'
        case $wz_host in
            ''|*[!A-Za-z0-9_-]*) wz_say '  letters, digits, - and _ only' ;;
            *) break ;;
        esac
    done
    # Where it goes is not asked. A directory named on the command line is a
    # destination, so it is checked now rather than after fifteen questions;
    # without one the machine goes straight onto the disk, and there is nothing
    # on this workstation for it to collide with.
    [ -z "$wz_dir" ] || wz_claim_dir "$wz_dir"

    # --- console -------------------------------------------------------------
    wz_head 'Console'
    wz_say 'Keyboard layout and variant, as setup-keymap takes them: "us us",'
    wz_say '"br br-abnt2", "de de-nodeadkeys". A layout on its own is used as'
    wz_say 'its own variant. A dash leaves the layout alone.'
    # Asked once. This was a loop that re-asked until it got two words, which is
    # a worse thing to be caught in than the problem it was avoiding — a prompt
    # you cannot get past is not validation. A layout alone is a fine answer and
    # system.sh doubles it; anything genuinely unusable is caught there, once,
    # with a message instead of another question.
    wz_ask wz_keymap 'Keyboard' 'us us'
    [ "$wz_keymap" = - ] && wz_keymap=''
    wz_say ''
    wz_say 'Timezone as a zone name — America/Sao_Paulo, Europe/Lisbon, UTC.'
    wz_ask wz_tz 'Timezone' 'UTC'
    wz_say ''
    wz_say 'Time sync. A machine with no battery-backed clock boots in 1970, and'
    wz_say 'a clock that far out makes every certificate look not-yet-valid.'
    wz_ask wz_ntp 'NTP client: chrony, busybox, openntpd or none' 'chrony'

    # --- network -------------------------------------------------------------
    wz_head 'Network'
    wz_say 'Interface name. auto takes whichever card the machine turns out to'
    wz_say 'have, which is almost always right from here: predictable naming gives'
    wz_say 'eth0 on one box and enp3s0 on the next, and a name that does not exist'
    wz_say 'means no network at all on a machine nobody is standing in front of.'
    wz_ask wz_iface 'Interface' 'auto'
    wz_ask wz_mode 'Address: dhcp or static' 'dhcp'
    wz_addr='' wz_mask='' wz_gw='' wz_dns=''
    case $wz_mode in
        static)
            while [ -z "$wz_addr" ]; do wz_ask wz_addr 'IP address' ''; done
            wz_ask wz_mask 'Netmask' '255.255.255.0'
            wz_ask wz_gw 'Gateway' ''
            wz_ask wz_dns 'DNS servers, space separated' "${wz_gw:-1.1.1.1}"
            ;;
        *) wz_mode=dhcp ;;
    esac
    wz_say ''
    wz_say 'Package mirror. Blank keeps whatever the image came with, which is'
    wz_say 'the global CDN — a nearer one is usually much faster.'
    wz_say 'For example: https://mirror.ufpr.br/alpine'
    wz_ask wz_mirror 'Mirror URL' ''

    # --- account -------------------------------------------------------------
    wz_head 'Account'
    wz_say 'root already exists and is not created here. This is the account you'
    wz_say 'log in as.'
    # Whoever is running this, unless that is root or something a username
    # cannot be — offering back a default the next line will reject is how a
    # prompt becomes unanswerable.
    wz_sug=$(bootstrap_user)
    case $wz_sug in ''|root|*[!a-z0-9_-]*) wz_sug='' ;; esac
    while :; do
        wz_ask wz_user 'Username' "$wz_sug"
        case $wz_user in
            ''|root|*[!a-z0-9_-]*) wz_say '  lowercase letters, digits, - and _; not root' ;;
            *) break ;;
        esac
    done
    wz_yn wz_doas "May $wz_user use doas to become root?" y

    wz_key=$(bootstrap_pubkey)
    if [ -n "$wz_key" ]; then
        wz_ask wz_key 'Public key to install' "$wz_key"
    else
        wz_say ''
        wz_say 'No public key found in your ~/.ssh. Without one, and with root'
        wz_say 'login and password auth off, nothing can reach this machine over'
        wz_say 'the network. Make one with: ssh-keygen -t ed25519'
        wz_ask wz_key 'Public key to install (blank to skip)' ''
    fi
    if [ -n "$wz_key" ] && [ ! -f "$wz_key" ]; then
        die "no such file: $wz_key"
    fi

    # --- ssh -----------------------------------------------------------------
    wz_head 'Remote access'
    if [ -n "$wz_key" ]; then
        wz_yn wz_ssh 'Enable ssh?' y
    else
        wz_say 'ssh cannot be enabled without a key for the account: nothing'
        wz_say 'would be able to log in, and spore refuses to build that.'
        wz_ssh=no
    fi
    wz_port=22
    [ "$wz_ssh" = yes ] && wz_ask wz_port 'ssh port' 22

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
        # Absent, not empty: "leave the layout alone" should read that way in
        # the file too, rather than as a setting someone forgot to fill in.
        if [ -n "$wz_keymap" ]; then
            printf 'SYSTEM_KEYMAP=%s\n' "\"$wz_keymap\""
        else
            printf '# SYSTEM_KEYMAP="br br-abnt2"\n'
        fi
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

    # ~/spores, not ~/machines: a directory in someone's home should say which
    # program put it there, and these are spores.
    if [ -z "$wz_dir" ]; then
        wl_home=$(bootstrap_home)
        wz_dir=${wl_home:+$wl_home/spores}
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
    wz_yn wc_go 'Replace it?' n
    [ "$wc_go" = yes ] ||
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
    wz_yn wd_go 'Write a USB stick now?' y
    [ "$wd_go" = yes ] || return 1

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
    # Asked again on a typo rather than abandoning the step. Getting a device
    # path slightly wrong is the most ordinary mistake here, and it should cost
    # a retry, not the answers to fifteen questions.
    while :; do
        wz_ask wd_dev 'Device (blank to skip)' ''
        [ -n "$wd_dev" ] || return 1
        if [ ! -b "$wd_dev" ]; then
            warn "$wd_dev is not a block device — pick one from the list above."
            continue
        fi
        # A partition where a disk belongs would be repartitioned as if it were
        # one, which is not what anybody means by it.
        if [ "$(lsblk -dno TYPE "$wd_dev" 2>/dev/null)" = part ]; then
            warn "$wd_dev is a partition. Name the whole disk instead — the one
         without the trailing number."
            continue
        fi
        if ! media_has_medium "$wd_dev"; then
            warn "$wd_dev has nothing in it — the node exists but reports size 0.
         An empty card-reader slot looks exactly like this. The real one has a
         size in the list above."
            continue
        fi
        break
    done

    wz_say ''
    wd_found=$(wz_find_iso)
    while :; do
        wz_ask wd_iso 'Alpine ISO (blank to skip)' "$wd_found"
        [ -n "$wd_iso" ] || return 1
        [ -f "$wd_iso" ] && break
        warn "no such file: $wd_iso"
        # Never offer back a default that was just rejected: pressing Enter on
        # it would ask the same unanswerable question for ever.
        wd_found=''
    done

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

Or boot it here first, in a VM, without touching the medium:

  sudo spore try $wd_dev

To change it later, mount the data partition and edit the files there —
the spore on the disk is the machine, there is no other copy:

  sudo mount ${wd_dev}2 /mnt
  \$EDITOR /mnt/spore/modules/net.conf

then on the machine itself:  spore apply --persist
DONE
    return 0
}
