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

    net_iface=$(mconf NET_IFACE eth0)
    net_mode=$(mconf NET_MODE dhcp)

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

auto $net_iface
iface $net_iface inet static
	address $net_addr
	netmask $net_mask"
        if [ -n "$net_gw" ]; then
            net_body="$net_body
	gateway $net_gw"
        fi
    else
        net_body="auto lo
iface lo inet loopback

auto $net_iface
iface $net_iface inet dhcp"
    fi

    plan_file /etc/network/interfaces 0644 "$net_body"

    net_dns=$(mconf NET_DNS '')
    if [ -n "$net_dns" ]; then
        net_resolv=''
        for net_s in $net_dns; do
            net_resolv="$net_resolv
nameserver $net_s"
        done
        plan_file /etc/resolv.conf 0644 "# Managed by spore.$net_resolv"
    fi
}
