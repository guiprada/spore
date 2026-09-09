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
        plan_firstboot "user-$users_u" \
            "id '$users_u' >/dev/null 2>&1 || adduser -D '$users_u'"
    done

    users_admins=$(mconf USERS_DOAS '')
    if [ -n "$users_admins" ]; then
        plan_pkg doas
        for users_a in $users_admins; do
            case " $users_list " in
                *" $users_a "*) ;;
                *) plan_note "users: '$users_a' is in USERS_DOAS but not in USERS"; continue ;;
            esac
            # doas refuses a config that is group- or world-writable.
            plan_file "/etc/doas.d/$users_a.conf" 0600 "permit persist $users_a as root"
        done
    fi

    # Home directories live outside /etc, so on a diskless box they are lost
    # unless declared.
    plan_persist /home
}
