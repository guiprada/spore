# modules/ssh.sh — OpenSSH server.

ssh_meta() {
    MOD_DESC='OpenSSH server'
    MOD_REQUIRES='init.openrc'
    if mconf_bool SSH_ENABLED yes; then
        MOD_PORTS="$(mconf SSH_PORT 22)/tcp"
    fi
}

ssh_plan() {
    ssh_port=$(mconf SSH_PORT 22)
    ssh_root=$(mconf SSH_PERMIT_ROOT_LOGIN prohibit-password)
    ssh_pw=$(mconf SSH_PASSWORD_AUTH no)
    ssh_keys=$(mconf SSH_AUTHORIZED_KEYS '')

    plan_pkg openssh

    ssh_conf="Port $ssh_port
PermitRootLogin $ssh_root
PasswordAuthentication $ssh_pw
PermitEmptyPasswords no"

    # Drop-in if the stock config pulls one in, an owned block if not.
    if sshd_include_supported; then
        plan_file /etc/ssh/sshd_config.d/10-spore.conf 0644 "$ssh_conf"
    else
        plan_file /etc/ssh/sshd_config 0644 \
            "$(render_marked_block /etc/ssh/sshd_config sshd "$ssh_conf")"
    fi

    if [ -n "$ssh_keys" ]; then
        if [ -f "$SPORE_DIR/$ssh_keys" ]; then
            plan_dir /root/.ssh 0700
            plan_file_from /root/.ssh/authorized_keys 0600 "$SPORE_DIR/$ssh_keys"
        else
            plan_note "ssh: SSH_AUTHORIZED_KEYS points at $ssh_keys, which is not in the spore"
        fi
    fi

    # Host keys are secrets. Sealed into the spore they travel with it, so a
    # rebuilt box keeps its identity and clients do not see the
    # REMOTE HOST IDENTIFICATION HAS CHANGED warning. ssh-keygen -A afterwards
    # only fills in key types that are missing, so it leaves ours alone.
    ssh_key_secrets=$(mconf SSH_HOST_KEY_SECRETS '')
    ssh_restored=''
    for ssh_k in $ssh_key_secrets; do
        if secret_exists "$ssh_k"; then
            plan_secret "/etc/ssh/$ssh_k" 0600 "$ssh_k"
            ssh_restored="$ssh_restored /etc/ssh/$ssh_k"
        else
            plan_note "ssh: SSH_HOST_KEY_SECRETS names '$ssh_k', which this spore does not carry"
        fi
    done

    if [ -n "$ssh_restored" ]; then
        # Public halves are derived, never stored.
        plan_firstboot ssh-hostkeys "set -e
for k in$ssh_restored; do
    [ -f \"\$k\" ] || continue
    ssh-keygen -y -f \"\$k\" > \"\$k.pub\"
    chmod 644 \"\$k.pub\"
done
ssh-keygen -A"
    else
        plan_firstboot ssh-hostkeys 'ssh-keygen -A'
    fi

    if mconf_bool SSH_ENABLED yes; then
        plan_svc sshd default on
    else
        plan_svc sshd default off
    fi
}
