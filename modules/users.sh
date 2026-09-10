# modules/users.sh — user accounts and doas.
#
# Passwords are secrets and never travel in a spore: an account is created
# locked, and you set its password on the host. doas with `persist` then covers
# day-to-day escalation.

users_meta() {
    MOD_DESC='user accounts and doas'
    MOD_REQUIRES='root'
}

users_plan() {
    users_list=$(mconf USERS '')
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
