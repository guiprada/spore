# modules/dufs.sh — dufs static file server.
#
# dufs is not in the Alpine repositories, so it arrives as a blob: a musl static
# release pinned by url + sha256 in blobs.conf. The service is generated rather
# than shipped, using OpenRC's supervise-daemon for restart-on-failure.

dufs_meta() {
    MOD_DESC='dufs static file server'
    MOD_REQUIRES='init.openrc'
    MOD_DATA=$(mconf DUFS_SERVE /srv/dufs)
    if mconf_bool DUFS_ENABLED yes; then
        MOD_PORTS="$(mconf DUFS_PORT 5000)/tcp"
    fi
}

dufs_plan() {
    dufs_serve=$(mconf DUFS_SERVE /srv/dufs)
    dufs_bind=$(mconf DUFS_BIND 0.0.0.0)
    dufs_port=$(mconf DUFS_PORT 5000)
    dufs_user=$(mconf DUFS_USER dufs)

    plan_blob dufs

    # Payload, not settings: declared as MOD_DATA and never carried in the spore.
    plan_dir "$dufs_serve" 0755

    dufs_opts="--bind $dufs_bind --port $dufs_port"
    if mconf_bool DUFS_ALLOW_UPLOAD no; then
        dufs_opts="$dufs_opts --allow-upload"
    fi
    dufs_auth=$(mconf DUFS_AUTH '')
    if [ -n "$dufs_auth" ]; then
        dufs_opts="$dufs_opts --auth $dufs_auth"
    fi
    dufs_opts="$dufs_opts $dufs_serve"

    plan_file /etc/conf.d/dufs 0644 "# Managed by spore.
DUFS_OPTS=\"$dufs_opts\"
DUFS_USER=\"$dufs_user\"
DUFS_GROUP=\"$dufs_user\""

    # Single-quoted on purpose: $DUFS_OPTS and $DUFS_USER must reach the init
    # script literally, for OpenRC to expand from /etc/conf.d/dufs at boot.
    # shellcheck disable=SC2016
    plan_file /etc/init.d/dufs 0755 '#!/sbin/openrc-run
# Managed by spore.

name="dufs"
description="dufs static file server"

supervisor="supervise-daemon"
command="/usr/local/bin/dufs"
command_args="$DUFS_OPTS"
command_user="${DUFS_USER:-dufs}:${DUFS_GROUP:-dufs}"

output_log="/var/log/dufs.log"
error_log="/var/log/dufs.log"

depend() {
    need net
    after firewall
}'

    plan_firstboot dufs-user "adduser -S -D -H -s /sbin/nologin $dufs_user 2>/dev/null || true"

    if mconf_bool DUFS_ENABLED yes; then
        plan_svc dufs default on
    else
        plan_svc dufs default off
    fi
}
