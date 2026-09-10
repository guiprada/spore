# modules/dufs.sh — dufs file server.
#
# dufs is packaged in Alpine community (arch=all, binary /usr/bin/dufs), so the
# binary comes from apk rather than a blob.
#
# The service is generated here rather than taken from the package. On Alpine
# 3.24 the package ships no init script at all — `rc-update add dufs` fails with
# "service does not exist" — and whether one appears is a packaging detail that
# varies by branch. Declaring it makes the result the same on every version,
# which is the point of a spore.
#
# The generated unit reads /etc/dufs/config.yaml via -c, matching what a packaged
# unit does, so the configuration format is unaffected either way.

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

    dufs_user=$(mconf DUFS_USER dufs)

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

    plan_file /etc/init.d/dufs 0755 "#!/sbin/openrc-run
# Managed by spore.

name=\$RC_SVCNAME
description=\"dufs file server\"

supervisor=\"supervise-daemon\"
command=\"/usr/bin/dufs\"
command_args=\"-c /etc/dufs/config.yaml\"
command_user=\"$dufs_user:$dufs_user\"

output_log=\"/var/log/dufs.log\"
error_log=\"/var/log/dufs.log\"

depend() {
    need net localmount
    after firewall
}

start_pre() {
    # supervise-daemon opens the log as command_user, and /var/log is root-owned,
    # so the daemon fails to start before it ever runs. start_pre runs as root:
    # create the file with the right owner first.
    checkpath -f -m 0644 -o \"\$command_user\" \"\$output_log\"
}"

    # The package does not necessarily create the account the service runs as,
    # and busybox adduser -S does not create a matching group — the account lands
    # in nogroup and supervise-daemon then fails looking up the group, not the
    # user. Create both, and repair an account that predates this.
    plan_firstboot dufs-user "grep -q '^$dufs_user:' /etc/group || addgroup -S '$dufs_user'
id -u '$dufs_user' >/dev/null 2>&1 ||
    adduser -S -D -H -s /sbin/nologin -G '$dufs_user' -g '$dufs_user' '$dufs_user'
addgroup '$dufs_user' '$dufs_user' 2>/dev/null || true"

    # chown is tolerant because vfat/exfat/ntfs cannot carry Unix ownership.
    plan_firstboot dufs-serve-owner \
        "chown -R '$dufs_user:$dufs_user' '$dufs_serve' 2>/dev/null || true"

    if mconf_bool DUFS_ENABLED yes; then
        plan_svc dufs default on
    else
        plan_svc dufs default off
    fi
}
