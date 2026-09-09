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

    dufs_auth=$(mconf DUFS_AUTH '')
    if [ -n "$dufs_auth" ]; then
        dufs_yaml="$dufs_yaml
auth:
  - $dufs_auth"
    fi

    if [ -n "$dufs_cert" ] && [ -n "$dufs_key" ]; then
        dufs_yaml="$dufs_yaml
tls-cert: $dufs_cert
tls-key: $dufs_key"

        # A certificate is a secret: generated on the host, never carried in the
        # spore. Self-signed with the box's own address as CN.
        if mconf_bool DUFS_TLS_SELFSIGNED no; then
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

    plan_file /etc/dufs/config.yaml 0644 "$dufs_yaml"

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
