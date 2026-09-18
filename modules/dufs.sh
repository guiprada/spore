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

    # `DUFS_TLS_SELFSIGNED=yes` on its own did nothing whatsoever. The entire TLS
    # block is gated on the certificate paths, and those default to empty — so
    # asking for a self-signed certificate got you plain http and no word about
    # it. Nobody means that, so the paths come with it.
    if [ -z "$dufs_cert" ] && [ -z "$dufs_key" ] &&
       { mconf_bool DUFS_TLS_SELFSIGNED no || [ -n "$(mconf DUFS_TLS_KEY_SECRET '')" ]; }; then
        dufs_cert=/etc/dufs/tls/server.crt
        dufs_key=/etc/dufs/tls/server.key
        plan_note "dufs: TLS was asked for without DUFS_TLS_CERT or DUFS_TLS_KEY,
         so the certificate goes to $dufs_cert and the key to $dufs_key.
         Set them to put it somewhere else."
    fi

    # A port that means https, serving http, is the one combination a browser
    # will not let you past: plain bytes where it expected a handshake is
    # SSL_ERROR_RX_RECORD_TOO_LONG, and Firefox offers no "continue anyway" for
    # it the way it does for a self-signed certificate. The service is up, the
    # port is open, the page never loads.
    if [ -z "$dufs_cert" ] && mconf_bool DUFS_ENABLED yes; then
        case $dufs_port in
            443|8443)
                plan_note "dufs: port $dufs_port with no TLS configured. Every browser
         treats that port as https, and plain http there gives
         SSL_ERROR_RX_RECORD_TOO_LONG — which Firefox will not let you click
         past, unlike a self-signed certificate.
         Set DUFS_TLS_SELFSIGNED=yes, or serve http on a port that does not
         mean https." ;;
        esac
    fi

    # Loopback is the default on purpose — a file server that turns itself on to
    # the whole network because somebody enabled the module is not a default
    # worth having. But it is also indistinguishable from a broken one: the
    # service starts, `rc-service dufs status` says started, the port is open on
    # the machine, and nothing off it can connect. Nothing failed, so nothing
    # said anything.
    if mconf_bool DUFS_ENABLED yes; then
        case $dufs_bind in
            127.*|::1|localhost)
                plan_note "dufs: DUFS_BIND is $dufs_bind, which is the loopback address,
         so this serves only the machine it runs on. It will start, it will
         listen, and nothing on the network will reach it.
         Set DUFS_BIND=0.0.0.0 to serve the network — with DUFS_ALLOW_ALL that
         is every attached disk, writable, to anyone who can reach port
         $dufs_port, so TLS and a sealed DUFS_AUTH_SECRET belong with it." ;;
        esac
    fi

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
            # The address goes in the SAN, and getting it wrong writes no
            # certificate at all rather than a wrong one:
            #
            #     openssl req ... -addext "subjectAltName=IP:localhost"
            #     error:11000076:X509 V3 routines:a2i_GENERAL_NAME:bad ip address
            #
            # Two ways that used to happen. `ip route get 1` prints
            #     1.0.0.0 via 172.16.100.1 dev eth0 src 172.16.100.100 uid 0
            # on iproute2 and the same line without the uid on busybox, so the
            # last field is an address on one and `0` on the other — and `IP:0`
            # is refused too. And the fallback was the literal word `localhost`,
            # which is a name, not an address, so the path meant to rescue the
            # other one could never work either.
            #
            # So: the word after `src`, an address off the interface if there is
            # no route, and a SAN that says DNS: for a name and IP: for an
            # address. The hostname goes in as well, because a machine reached
            # by name and a machine reached by address are the same machine.
            plan_firstboot dufs-tls "set -e
if [ ! -f '$dufs_cert' ] || [ ! -f '$dufs_key' ]; then
    mkdir -p \"\$(dirname '$dufs_cert')\" \"\$(dirname '$dufs_key')\"
    addr=\$(ip route get 1 2>/dev/null |
           awk '{ for (i = 1; i < NF; i++) if (\$i == \"src\") { print \$(i+1); exit } }')
    [ -n \"\$addr\" ] || addr=\$(ip -4 addr show 2>/dev/null |
        awk '/inet /{ split(\$2, a, \"/\"); if (a[1] != \"127.0.0.1\") { print a[1]; exit } }')
    host=\$(hostname 2>/dev/null) || host=''
    [ -n \"\$host\" ] || host=alpine
    san=\"DNS:\$host\"
    cn=\$host
    case \$addr in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*) san=\"IP:\$addr,DNS:\$host\"; cn=\$addr ;;
    esac
    if ! openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \\
        -keyout '$dufs_key' -out '$dufs_cert' \\
        -subj \"/CN=\$cn\" -addext \"subjectAltName=\$san\" 2>/tmp/dufs-tls.err
    then
        echo 'spore: could not generate a certificate for dufs:' >&2
        sed 's/^/spore:   /' /tmp/dufs-tls.err >&2
        echo 'spore: dufs is configured for TLS, so it will not serve until this' >&2
        echo 'spore: works. Set DUFS_TLS_SELFSIGNED=no to serve plain http, or' >&2
        echo 'spore: seal a certificate with DUFS_TLS_CERT_SECRET.' >&2
        exit 1
    fi
    echo \"spore: self-signed certificate for \$cn (\$san)\"
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
    #
    # Applied at every start, not once. It was a firstboot action, which is the
    # wrong shape twice over on the machines this is for: a diskless Alpine
    # installs its world packages into a RAM root at every boot, so /usr/bin/dufs
    # is a new file each time with no xattrs on it; and a machine booted from its
    # committed overlay stops at /etc/spore/.seeded and runs no firstboot action
    # at all. Port 443 would have worked on the boot that configured the machine
    # and failed on every boot after it — the same trap the automount service
    # exists to avoid, in code I had already read.
    dufs_setcap=''
    if [ "$dufs_port" -lt 1024 ] 2>/dev/null; then
        plan_pkg libcap
        dufs_setcap="
    # $dufs_port is privileged and \$command_user is not root, so the binary
    # needs the capability — and it is a fresh binary on every diskless boot.
    if ! setcap 'cap_net_bind_service=+ep' /usr/bin/dufs 2>/dev/null; then
        eerror \"could not give dufs permission to bind port $dufs_port\"
        eerror 'a port below 1024 needs cap_net_bind_service; is libcap installed?'
        return 1
    fi"
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
    checkpath -f -m 0644 -o \"\$command_user\" \"\$output_log\"$dufs_setcap
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

# Shown under `spore status`, because "is it actually reachable" is not something
# the plan can answer — and the gap between "the service started" and "you can
# open it" is where a loopback bind lives.
dufs_status_extra() {
    dse_port=$(mconf DUFS_PORT 5000)
    dse_want=$(mconf DUFS_BIND 127.0.0.1)
    dse_on=$( { netstat -lnt 2>/dev/null || ss -lnt 2>/dev/null; } |
              awk '{ print $4 }' | grep -E "[:.]${dse_port}\$" | tr '\n' ' ')
    if [ -z "$dse_on" ]; then
        printf 'nothing is listening on port %s\n' "$dse_port"
        return 0
    fi
    printf 'listening on %s\n' "${dse_on% }"
    case $dse_on in
        127.*|'::1'*|*' 127.'*)
            printf 'which is loopback only — set DUFS_BIND=0.0.0.0 to serve the network\n' ;;
    esac
}
