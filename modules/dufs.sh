# modules/dufs.sh — dufs file server.
#
# dufs is packaged in Alpine community (arch=all, binary /usr/bin/dufs), and the
# package ships its own OpenRC service — already supervise-daemon, already
# running as dufs:dufs, already depending on net+localmount. So this module
# installs the package and configures it; it does not generate a service.
#
# Configuration is /etc/dufs/config.yaml, which is what the packaged init script
# passes via -c. Flags in conf.d would be ignored.

dufs_meta() {
    MOD_DESC='dufs file server (community package)'
    MOD_REQUIRES='init.openrc'
    MOD_DATA=$(mconf DUFS_SERVE /var/lib/dufs)
    if mconf_bool DUFS_ENABLED yes; then
        MOD_PORTS="$(mconf DUFS_PORT 5000)/tcp"
    fi
}

dufs_plan() {
    dufs_serve=$(mconf DUFS_SERVE /var/lib/dufs)
    dufs_bind=$(mconf DUFS_BIND 127.0.0.1)
    dufs_port=$(mconf DUFS_PORT 5000)
    dufs_cert=$(mconf DUFS_TLS_CERT '')
    dufs_key=$(mconf DUFS_TLS_KEY '')

    plan_pkg dufs
    plan_dir "$dufs_serve" 0755

    dufs_yaml="# Managed by spore. Consumed by the packaged init script via -c.
serve-path: '$dufs_serve'
bind: $dufs_bind
port: $dufs_port"

    # Read-only unless asked otherwise, matching the package default rather than
    # the more permissive -A.
    if mconf_bool DUFS_ALLOW_ALL no; then
        dufs_yaml="$dufs_yaml
allow-all: true"
    else
        if mconf_bool DUFS_ALLOW_UPLOAD no; then
            dufs_yaml="$dufs_yaml
allow-upload: true"
        fi
        if mconf_bool DUFS_ALLOW_DELETE no; then
            dufs_yaml="$dufs_yaml
allow-delete: true"
        fi
    fi

    # An auth rule carries a password, so it comes from a sealed secret. Naming
    # it here puts a marker in the template; the value is substituted on the host
    # at write time and the whole config.yaml becomes a secret action.
    dufs_auth_secret=$(mconf DUFS_AUTH_SECRET '')
    dufs_auth=$(mconf DUFS_AUTH '')
    dufs_sensitive=no
    if [ -n "$dufs_auth_secret" ]; then
        if secret_exists "$dufs_auth_secret"; then
            dufs_yaml="$dufs_yaml
auth:
  - @@SECRET:$dufs_auth_secret@@"
            dufs_sensitive=yes
        else
            plan_note "dufs: DUFS_AUTH_SECRET names '$dufs_auth_secret', which this spore does not carry"
        fi
    elif [ -n "$dufs_auth" ]; then
        plan_note "dufs: DUFS_AUTH holds a password in cleartext — seal it instead:
         spore seal dufs-auth, then set DUFS_AUTH_SECRET=dufs-auth"
        dufs_yaml="$dufs_yaml
auth:
  - $dufs_auth"
    fi

    if [ -n "$dufs_cert" ] && [ -n "$dufs_key" ]; then
        dufs_yaml="$dufs_yaml
tls-cert: $dufs_cert
tls-key: $dufs_key"

        # Preferred: the key travels sealed, so the same host identity survives a
        # rebuild instead of changing under every client.
        dufs_key_secret=$(mconf DUFS_TLS_KEY_SECRET '')
        dufs_cert_secret=$(mconf DUFS_TLS_CERT_SECRET '')
        if [ -n "$dufs_key_secret" ] && secret_exists "$dufs_key_secret"; then
            plan_secret "$dufs_key" 0600 "$dufs_key_secret" dufs:dufs
            if [ -n "$dufs_cert_secret" ] && secret_exists "$dufs_cert_secret"; then
                plan_secret "$dufs_cert" 0644 "$dufs_cert_secret" dufs:dufs
            else
                plan_note "dufs: TLS key is sealed but the certificate is not (DUFS_TLS_CERT_SECRET)"
            fi
        elif mconf_bool DUFS_TLS_SELFSIGNED no; then
            plan_pkg openssl
            plan_firstboot dufs-tls "set -e
if [ ! -f '$dufs_cert' ] || [ ! -f '$dufs_key' ]; then
    mkdir -p \"\$(dirname '$dufs_cert')\" \"\$(dirname '$dufs_key')\"
    cn=\$(ip route get 1 2>/dev/null | awk '{print \$NF; exit}')
    [ -n \"\$cn\" ] || cn=localhost
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \\
        -keyout '$dufs_key' -out '$dufs_cert' \\
        -subj \"/CN=\$cn\" -addext \"subjectAltName=IP:\$cn\"
fi
chown dufs:dufs '$dufs_key' '$dufs_cert' 2>/dev/null || true
chmod 600 '$dufs_key' 2>/dev/null || true"
        fi
    fi

    if [ "$dufs_sensitive" = yes ]; then
        plan_secret_file /etc/dufs/config.yaml 0640 "$dufs_yaml" dufs:dufs
    else
        plan_file /etc/dufs/config.yaml 0644 "$dufs_yaml"
    fi

    # Binding below 1024 as a non-root user needs the capability, or the service
    # starts and immediately fails.
    if [ "$dufs_port" -lt 1024 ] 2>/dev/null; then
        plan_pkg libcap
        plan_firstboot dufs-setcap "setcap 'cap_net_bind_service=+ep' /usr/bin/dufs"
    fi

    # The packaged init checkpaths /var/lib/dufs itself; anywhere else is ours.
    # chown is tolerant because vfat/exfat/ntfs cannot carry Unix ownership.
    if [ "$dufs_serve" != /var/lib/dufs ]; then
        plan_firstboot dufs-serve-owner \
            "chown -R dufs:dufs '$dufs_serve' 2>/dev/null || true"
    fi

    if mconf_bool DUFS_ENABLED yes; then
        plan_svc dufs default on
    else
        plan_svc dufs default off
    fi
}
