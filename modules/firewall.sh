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
    fw_iface=$(mconf FW_IFACE eth0)

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

    plan_file /etc/awall/optional/spore.json 0644 "{
  \"description\": \"managed by spore\",

  \"variable\": { \"spore_if\": \"$fw_iface\" },

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

    plan_firstboot awall-enable 'awall enable spore'
    plan_svc iptables default on

    if mconf_bool FW_ACTIVATE no; then
        plan_firstboot awall-activate 'awall activate --force'
    else
        # shellcheck disable=SC2016  # backticks are literal prose here
        plan_note 'firewall: policy written and enabled but NOT activated (FW_ACTIVATE=no).
         Run `awall activate` on the host once you are sure the rules are right.'
    fi
}
