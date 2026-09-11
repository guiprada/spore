# modules/firewall.sh — awall.
#
# The policy is generated from the ports every other enabled module declared, so
# opening a port is a consequence of enabling a service rather than a separate
# thing to remember.
#
# Activation is deliberately opt-in (FW_ACTIVATE): applying a firewall to a
# remote box is exactly the operation that can lock you out of it.

firewall_meta() {
    MOD_DESC='awall firewall'
    MOD_REQUIRES='net.admin init.openrc'
}

firewall_plan() {
    # Defaults to whatever net was told, so the two cannot silently disagree: a
    # zone naming an interface this machine does not have matches nothing, the
    # drop rule never applies, the catch-all accept does, and the box believes
    # it is firewalled while it is wide open.
    fw_iface=$(mconf FW_IFACE "$(conf_get "$SPORE_DIR/modules/net.conf" NET_IFACE auto)")
    fw_auto=no
    [ "$fw_iface" = auto ] && fw_auto=yes

    plan_pkg awall
    plan_pkg iptables

    fw_defs=''
    fw_names=''
    for fw_p in $SPORE_ALL_PORTS; do
        fw_num=${fw_p%%/*}
        fw_proto=${fw_p##*/}
        if [ "$fw_num" = "$fw_p" ]; then fw_proto=tcp; fi
        fw_nm="spore-$fw_proto-$fw_num"
        if [ -n "$fw_defs" ]; then fw_defs="$fw_defs,"; fi
        fw_defs="$fw_defs
    \"$fw_nm\": { \"proto\": \"$fw_proto\", \"port\": [$fw_num] }"
        if [ -n "$fw_names" ]; then fw_names="$fw_names, "; fi
        fw_names="$fw_names\"$fw_nm\""
    done

    if [ -n "$fw_names" ]; then
        fw_accept="
    { \"in\": \"world\", \"out\": \"_fw\", \"service\": [ $fw_names ], \"action\": \"accept\" },"
    else
        fw_accept=''
        plan_note 'firewall: no module declared any ports — policy drops all inbound'
    fi

    fw_zone_if=$fw_iface
    [ "$fw_auto" = yes ] && fw_zone_if=__SPORE_IFACE__
    fw_json="{
  \"description\": \"managed by spore\",

  \"variable\": { \"spore_if\": \"$fw_zone_if\" },

  \"zone\": {
    \"world\": { \"iface\": \"\$spore_if\" }
  },

  \"service\": {$fw_defs
  },

  \"policy\": [
    { \"in\": \"world\", \"action\": \"drop\" },
    { \"action\": \"accept\" }
  ],

  \"filter\": [$fw_accept
    { \"in\": \"world\", \"service\": \"ping\", \"action\": \"accept\",
      \"flow-limit\": { \"count\": 10, \"interval\": 6 } }
  ]
}"

    # A named interface is a fact about the machine, so the policy can be written
    # now and compared later. `auto` cannot be: its zone depends on hardware this
    # planner has never seen, so the file is written on the target instead — a
    # file action would report drift for ever.
    if [ "$fw_auto" = no ]; then
        plan_file /etc/awall/optional/spore.json 0644 "$fw_json"
        fw_enable='awall enable spore'
    else
        plan_note "firewall: FW_IFACE=auto, so the zone is filled in on the machine
         from whatever interface it turns out to have, and the policy is not
         compared against the spore."
        fw_enable="mkdir -p /etc/awall/optional
$(render_iface_resolve "$fw_iface" 'FW_IFACE in modules/firewall.conf')
if [ -z \"\$iface\" ]; then
    echo 'spore: refusing to write a zone that names no interface — it would' >&2
    echo 'spore: match nothing, drop nothing, and still read as protection.' >&2
    exit 1
fi
cat > /etc/awall/optional/spore.json <<'SPORE_FW_EOF'
$fw_json
SPORE_FW_EOF
sed -i \"s/__SPORE_IFACE__/\$iface/g\" /etc/awall/optional/spore.json
awall enable spore"
    fi
    plan_firstboot awall-enable "$fw_enable"
    plan_svc iptables default on

    if mconf_bool FW_ACTIVATE no; then
        plan_firstboot awall-activate 'awall activate --force'
    else
        # shellcheck disable=SC2016  # backticks are literal prose here
        plan_note 'firewall: policy written and enabled but NOT activated (FW_ACTIVATE=no).
         Run `awall activate` on the host once you are sure the rules are right.'
    fi
}
