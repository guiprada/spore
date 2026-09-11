# modules/users.sh — user accounts and doas.
#
# Passwords are secrets and never travel in a spore: an account is created
# locked, and you set its password on the host. doas with `persist` then covers
# day-to-day escalation.

users_meta() {
    MOD_DESC='user accounts and doas'
    MOD_REQUIRES='root'
    # An account is only a way in if it has a key: adduser -D leaves no password.
    for um_u in $(mconf USERS ''); do
        if [ -f "$SPORE_DIR/keys/$um_u.authorized_keys" ]; then
            MOD_LOGINS="$MOD_LOGINS $um_u"
        fi
    done
    # A root password the spore sets itself. Declared here, in the metadata pass,
    # so the ssh module can see it before it decides whether enabling sshd would
    # expose a password-less root — and it is honest to look at it that way,
    # because every firstboot action runs before any service is started. The
    # password is in place by the time sshd exists.
    if secret_exists root.password; then
        MOD_ROOT_PASSWORD=yes
    fi
    # A trailing conditional would make this function's status that of its last
    # test, and under `set -e` a false one kills the run with no message.
    return 0
}

# A sealed password completes unattended provisioning: no console visit to run
# passwd. The hash is decrypted on the target at first boot, so it never enters
# the plan — only the path to the ciphertext does.
#
# The stamp for a firstboot action is the hash of its script, so the ciphertext's
# own checksum is embedded: rotate the sealed password and the script changes,
# and the action runs again. Without that, a rotated secret would be silently
# ignored.
users_plan_password() {
    upp_who=$1
    secret_exists "$upp_who.password" || return 0
    plan_age
    upp_ct=$(secret_path "$upp_who.password")
    plan_firstboot "user-$upp_who-password" "# secret: $(sha256_file "$upp_ct")
set -e
hash=\$(age --decrypt -i '$(secret_identity)' '$upp_ct') || {
    echo 'spore: could not decrypt the password for $upp_who' >&2
    exit 1
}
printf '%s:%s\\n' '$upp_who' \"\$hash\" | chpasswd -e
unset hash"
}

users_plan() {
    users_list=$(mconf USERS '')

    # root already exists, so it is never in USERS — but it is the one account
    # that always does, and giving it a password is what makes ssh with password
    # auth safe to turn on at all.
    users_plan_password root

    [ -n "$users_list" ] || return 0

    for users_u in $users_list; do
        # The key is installed by the same action that creates the account.
        # Writing it as an ordinary file action would run in the file pass,
        # before the user exists, and land owned by root in a home directory
        # that is not there yet.
        users_key=$SPORE_DIR/keys/$users_u.authorized_keys
        if [ -f "$users_key" ]; then
            plan_firstboot "user-$users_u" "set -e
id '$users_u' >/dev/null 2>&1 || adduser -D '$users_u'
install -d -m 700 -o '$users_u' -g '$users_u' '/home/$users_u/.ssh'
cat > '/home/$users_u/.ssh/authorized_keys' <<'SPORE_KEY_EOF'
$(cat "$users_key")
SPORE_KEY_EOF
chown '$users_u:$users_u' '/home/$users_u/.ssh/authorized_keys'
chmod 600 '/home/$users_u/.ssh/authorized_keys'"
        else
            plan_firstboot "user-$users_u" \
                "id '$users_u' >/dev/null 2>&1 || adduser -D '$users_u'"
            plan_note "users: no keys/$users_u.authorized_keys in this spore, so
         '$users_u' has no way to log in over ssh. With root login disabled and
         password auth off, nobody can."
        fi
    done

    for users_p in $users_list; do
        users_plan_password "$users_p"
    done

    users_admins=$(mconf USERS_DOAS '')
    if [ -n "$users_admins" ]; then
        plan_pkg doas
        for users_a in $users_admins; do
            case " $users_list " in
                *" $users_a "*) ;;
                *) plan_note "users: '$users_a' is in USERS_DOAS but not in USERS"; continue ;;
            esac
            # An account created with adduser -D has no password, so `persist`
            # (which prompts for one) can never succeed. nopass is the usable
            # choice for an unattended build; it means anything running as this
            # user can become root without a password, which is a real trade and
            # should be a deliberate one.
            if mconf_bool USERS_DOAS_NOPASS no; then
                plan_note "users: '$users_a' gets doas without a password.
         Anything running as this account becomes root without authenticating.
         Set USERS_DOAS_NOPASS=no and give the account a password instead, if
         this box is not single-purpose."
                users_rule="permit nopass $users_a as root"
            else
                users_rule="permit persist $users_a as root"
            fi
            # doas refuses a config that is group- or world-writable.
            plan_file "/etc/doas.d/$users_a.conf" 0600 "$users_rule"
        done
    fi

    # Home directories live outside /etc, so on a diskless box they are lost
    # unless declared.
    plan_persist /home
}
