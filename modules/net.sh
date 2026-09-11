# modules/net.sh — hostname, interfaces, DNS.
#
# Hostname works on any host. Interface and DNS configuration needs NET_ADMIN,
# which an unprivileged container does not have — so that part is gated
# separately rather than failing the whole module.

net_meta() {
    MOD_DESC='hostname, interfaces and DNS'
    MOD_REQUIRES=''
}

net_plan() {
    net_host=$(mconf NET_HOSTNAME '')
    if [ -n "$net_host" ]; then
        plan_file /etc/hostname 0644 "$net_host"
        plan_file /etc/hosts 0644 "127.0.0.1	localhost localhost.localdomain
::1		localhost localhost.localdomain
127.0.1.1	$net_host"
    fi

    if [ "$(fact_netadmin)" != yes ]; then
        plan_note "net: interfaces and DNS skipped (no NET_ADMIN) — hostname still applied"
        return 0
    fi

    net_iface=$(mconf NET_IFACE auto)
    net_mode=$(mconf NET_MODE dhcp)

    # The default is `auto` — whatever this machine's card turns out to be called
    # — because a spore is written on a workstation for a machine that is not in
    # front of you, and the name is the one piece of it that cannot be known from
    # here. See render_iface_resolve for how it is settled on the target.
    net_auto=no
    [ "$net_iface" = auto ] && net_auto=yes

    if [ "$net_mode" = static ]; then
        net_addr=$(mconf NET_ADDRESS '')
        net_mask=$(mconf NET_NETMASK 255.255.255.0)
        net_gw=$(mconf NET_GATEWAY '')
        if [ -z "$net_addr" ]; then
            plan_note "net: NET_MODE=static but NET_ADDRESS is unset — interfaces not written"
            return 0
        fi
        net_body="auto lo
iface lo inet loopback

auto __SPORE_IFACE__
iface __SPORE_IFACE__ inet static
	address $net_addr
	netmask $net_mask"
        if [ -n "$net_gw" ]; then
            net_body="$net_body
	gateway $net_gw"
        fi
    else
        net_body="auto lo
iface lo inet loopback

auto __SPORE_IFACE__
iface __SPORE_IFACE__ inet dhcp"
    fi
    net_body=$(printf '%s' "$net_body" | sed 's/\\t/	/g')

    # A named interface is a fact about the machine, so the file can be written
    # now and compared later. `auto` cannot be: its content depends on hardware
    # this planner has never seen, and a file action would report drift forever.
    if [ "$net_auto" = no ]; then
        net_body=$(printf '%s' "$net_body" | sed "s/__SPORE_IFACE__/$net_iface/g")
        plan_file /etc/network/interfaces 0644 "$net_body"
    else
        plan_note "net: NET_IFACE=auto, so /etc/network/interfaces is written on the
         machine from whatever interface it turns out to have, and is not
         compared against the spore."
    fi

    net_dns=$(mconf NET_DNS '')
    net_resolv=''
    if [ -n "$net_dns" ]; then
        for net_s in $net_dns; do
            net_resolv="$net_resolv
nameserver $net_s"
        done
        net_resolv="# Managed by spore.$net_resolv"
        plan_file /etc/resolv.conf 0644 "$net_resolv"
    fi

    # And again, early. The file pass is four phases too late to be the only
    # place this happens: the first thing apply does on a fresh box is
    # `apk update`, and a stock diskless Alpine has no /etc/network/interfaces
    # at all — so there is no network to do it over, and the run dies in the
    # bootstrap pass at something that reads like a broken mirror rather than
    # like a machine with no address. Anything that provisions itself has to
    # bring its own network up before it can fetch a single package.
    #
    # Byte-identical to the file actions above, so those find it already
    # correct and `status` stays honest.
    net_early="mkdir -p /etc/network
$(render_iface_resolve "$net_iface")
cat > /etc/network/interfaces <<'SPORE_IFACE_EOF'
$net_body
SPORE_IFACE_EOF
sed -i \"s/__SPORE_IFACE__/\$iface/g\" /etc/network/interfaces"
    if [ -n "$net_resolv" ]; then
        net_early="$net_early
cat > /etc/resolv.conf <<'SPORE_RESOLV_EOF'
$net_resolv
SPORE_RESOLV_EOF"
    fi
    # ifup, not `rc-service networking`. Asking OpenRC to start the service
    # drags in its whole dependency graph — which wants fsck, which will not
    # start this early — and the whole thing fails with "cannot start networking
    # as fsck would not start". The interface then never comes up and the first
    # apk update dies of DNS, three layers away from the cause.
    plan_netup net-up "$net_early
if command -v ifup >/dev/null 2>&1; then
    ifdown -a 2>/dev/null || true
    ifup -a || true
elif [ -x /etc/init.d/networking ]; then
    rc-service networking restart || rc-service networking start || true
fi"
}
