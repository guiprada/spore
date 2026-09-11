#!/bin/sh
# tests/run.sh — the whole apply path, exercised without Alpine.
#
# Two properties make this possible: the planner is pure (so plans can be
# asserted directly), and a synthetic root means the executor writes the state
# apk/rc-update/lbu would have produced instead of running them.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SPORE=$ROOT/bin/spore
EX=$ROOT/examples/example.spore

PASS=0
FAIL=0
export SPORE_COLOR=never

t_ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
t_fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ $# -ge 2 ] && printf '        %s\n' "$2"; return 0; }
t_skip() { printf '  skip  %s\n' "$1"; }

check()      { if [ "$2" = "$3" ];                    then t_ok "$1"; else t_fail "$1" "expected [$3] got [$2]"; fi; }
has()        { if printf '%s\n' "$2" | grep -qF -- "$3"; then t_ok "$1"; else t_fail "$1" "missing: $3"; fi; }
hasnt()      { if printf '%s\n' "$2" | grep -qF -- "$3"; then t_fail "$1" "unexpected: $3"; else t_ok "$1"; fi; }
file_mode()  { stat -c '%a' "$1" 2>/dev/null || echo missing; }

# A diskless x86_64 Alpine box with NET_ADMIN.
alpine() {
    env SPORE_FACT_INIT=openrc SPORE_FACT_NETADMIN=yes SPORE_FACT_PERSIST=lbu \
        SPORE_FACT_ARCH=x86_64 SPORE_FACT_ROOT=yes SPORE_FACT_ALPINE=3.20.0 "$@"
}

section() { printf '\n%s\n' "$1"; }

# ---------------------------------------------------------------- syntax -----
# Prefer the real target shell. On Alpine that is busybox ash; elsewhere dash is
# the closest POSIX stand-in. Hardcoding dash meant this section failed on every
# file on the one platform it exists to check.
for POSIX_SH in ash dash sh; do
    command -v "$POSIX_SH" >/dev/null 2>&1 && break
done
section "syntax ($POSIX_SH -n)"
for f in "$ROOT"/bin/spore "$ROOT"/lib/*.sh "$ROOT"/modules/*.sh "$ROOT"/tests/*.sh; do
    if "$POSIX_SH" -n "$f" 2>/dev/null; then t_ok "parses $(basename "$f")"
    else t_fail "parses $(basename "$f")"; fi
done

if command -v shellcheck >/dev/null 2>&1; then
    section 'shellcheck -s sh'
    for f in "$ROOT"/bin/spore "$ROOT"/lib/*.sh "$ROOT"/modules/*.sh; do
        if shellcheck -s sh -e SC1090,SC1091,SC2034,SC2154,SC2153 "$f" >/dev/null 2>&1
        then t_ok "shellcheck $(basename "$f")"
        else t_fail "shellcheck $(basename "$f")"; fi
    done
else
    printf '\nshellcheck not installed — syntax covered by dash -n only\n'
fi

# ------------------------------------------------------------------ plan -----
section 'plan (pure: no root, no target, no side effects)'
PLAN=$(alpine "$SPORE" --spore "$EX" plan 2>&1)
has  'plans openssh package'          "$PLAN" 'pkg        openssh'
has  'installs dufs from a package'   "$PLAN" 'pkg        dufs'
has  'configures dufs via config.yaml' "$PLAN" 'file       /etc/dufs/config.yaml'
has  'declares its own init script'   "$PLAN" 'file       /etc/init.d/dufs (0755'
has  'creates the account it runs as' "$PLAN" 'firstboot  dufs-user'
hasnt 'does not fetch dufs as a blob'  "$PLAN" 'blob       dufs'
has  'plans sshd in default runlevel' "$PLAN" 'svc        sshd -> default [on]'
has  'plans host keys as firstboot'   "$PLAN" 'firstboot  ssh-hostkeys'
has  'enables community before installing' "$PLAN" 'bootstrap  repos-community'
has  'declares where the apkovl goes' "$PLAN" 'file       /etc/lbu/lbu.conf'
has  'persists /home for user accounts' "$PLAN" 'persist    /home'
has  'warns firewall not activated'   "$PLAN" 'NOT activated'
hasnt 'carries no private key material' "$PLAN" 'ssh_host_'

# ------------------------------------------------------------- fake root -----
section 'apply into a synthetic root'
R=$(mktemp -d /tmp/spore-test.XXXXXX)
LOG=$(mktemp /tmp/spore-log.XXXXXX)
export SPORE_RUN_LOG="$LOG"
OUT=$(alpine "$SPORE" --spore "$EX" --root "$R" apply 2>&1)
unset SPORE_RUN_LOG

has 'first apply creates the configs' "$OUT" '+ file /etc/dufs/config.yaml'
has 'first apply enables the services' "$OUT" '+ service sshd (default)'
check 'doas.d conf is 0600'     "$(file_mode "$R/etc/doas.d/gui.conf")"       600
check 'doas.d conf is 0600'     "$(file_mode "$R/etc/doas.d/gui.conf")"       600

has 'sshd config carries owned block' "$(cat "$R/etc/ssh/sshd_config")" '# BEGIN spore:sshd'
has 'sshd port set'                   "$(cat "$R/etc/ssh/sshd_config")" 'Port 22'
has 'empty passwords always refused'  "$(cat "$R/etc/ssh/sshd_config")" 'PermitEmptyPasswords no'
has 'dufs serve-path rendered'        "$(cat "$R/etc/dufs/config.yaml")" "serve-path: '/media/storage'"
has 'dufs port rendered'              "$(cat "$R/etc/dufs/config.yaml")" 'port: 443'
has 'dufs TLS wired up'               "$(cat "$R/etc/dufs/config.yaml")" 'tls-cert: /etc/dufs/tls/server.crt'

DI=$(cat "$R/etc/init.d/dufs")
has   'init script is openrc'           "$DI" '#!/sbin/openrc-run'
has   'init script supervises'          "$DI" 'supervisor="supervise-daemon"'
has   'init script reads the config'    "$DI" 'command_args="-c /etc/dufs/config.yaml"'
has   'init script drops privilege'     "$DI" 'command_user="dufs:dufs"'
has   'init script waits for mounts'    "$DI" 'need net localmount'
# shellcheck disable=SC2016  # matching literal text in the generated unit
has   'init script prepares its log'    "$DI" 'checkpath -f -m 0644 -o "$command_user" "$output_log"'
check 'init script is executable'       "$(file_mode "$R/etc/init.d/dufs")" 755
has 'doas rule uses persist'          "$(cat "$R/etc/doas.d/gui.conf")" 'permit persist gui as root'

section 'a user with no key cannot log in, and is told so'
UK=$(mktemp -d)/s; cp -r "$EX" "$UK"
rm -f "$UK/keys/gui.authorized_keys"
# ssh must refuse outright when nothing could log in.
if UKP=$(alpine "$SPORE" --spore "$UK" plan 2>&1); then
    t_fail 'ssh refuses when nothing could log in' 'plan succeeded'
else
    has 'ssh refuses when nothing could log in' "$UKP" 'Nothing could log in'
fi

# The other refusal: a password-less root exposed to the network.
UKD=$(mktemp -d)/s; cp -r "$EX" "$UKD"
sed -i 's/^SSH_PERMIT_ROOT_LOGIN=.*/SSH_PERMIT_ROOT_LOGIN=yes/; s/^SSH_PASSWORD_AUTH=.*/SSH_PASSWORD_AUTH=yes/' \
    "$UKD/modules/ssh.conf"
export SPORE_FACT_ROOT_PASSWORD=empty
if UKDP=$(alpine "$SPORE" --spore "$UKD" plan 2>&1); then
    t_fail 'ssh refuses a password-less root on the network' 'plan succeeded'
else
    has 'ssh refuses a password-less root on the network' "$UKDP" 'unauthenticated root shell'
fi
# ...and allows it once root has a password.
SPORE_FACT_ROOT_PASSWORD='set'
if alpine "$SPORE" --spore "$UKD" plan >/dev/null 2>&1; then
    t_ok 'and allows it once root has a password'
else
    t_fail 'and allows it once root has a password'
fi
unset SPORE_FACT_ROOT_PASSWORD
rm -rf "$UKD"

section 'the apkovl has somewhere to go, or the machine forgets everything'
# `lbu commit` writes wherever /etc/lbu/lbu.conf points, and a stock Alpine
# points nowhere — setup-lbu is a console step a seed-booted machine never gets.
# Committing into the void is the one loss nothing reports: apply succeeds, the
# hook stamps itself done, and the machine comes back blank.
AV=$(mktemp -d /tmp/spore-apkovl.XXXXXX)/s; cp -r "$EX" "$AV"
export SPORE_FACT_LBU_DEST=unset
AVP=$(alpine "$SPORE" --spore "$AV" plan 2>&1)
has 'the destination is written to lbu.conf' "$AVP" 'file       /etc/lbu/lbu.conf'
AVR=$(mktemp -d /tmp/spore-apkovlroot.XXXXXX)
alpine "$SPORE" --spore "$AV" --root "$AVR" apply >/dev/null 2>&1
has 'as an owned block, not a rewrite' "$(cat "$AVR/etc/lbu/lbu.conf")" \
    'LBU_BACKUPDIR=/media/storage/data'
has 'and the block is delimited'       "$(cat "$AVR/etc/lbu/lbu.conf")" '# BEGIN spore:lbu'

# Named nothing: the apkovl goes beside the spore. That partition is the one we
# know is mounted and writable, because the spore was just read off it.
printf 'APKOVL_BACKUPDIR=\n' > "$AV/modules/apkovl.conf"
AVD=$(alpine "$SPORE" --spore "$AV" plan 2>&1)
has 'unnamed, it commits beside the spore' "$AVD" "at $(dirname "$AV")"
AVR2=$(mktemp -d /tmp/spore-apkovlbeside.XXXXXX)
alpine "$SPORE" --spore "$AV" --root "$AVR2" apply >/dev/null 2>&1
has 'and that is what lbu.conf says' "$(cat "$AVR2/etc/lbu/lbu.conf")" \
    "LBU_BACKUPDIR=$(dirname "$AV")"
rm -rf "$AVR2"

# With nowhere beside it either — the spore exported to the rootfs path on a
# diskless box — committing would write nowhere at all, and that must not plan
# quietly. Skipped rather than disturbing a real /var/lib/spore.
if [ -e /var/lib/spore ]; then
    t_skip '/var/lib/spore exists here — nowhere-to-commit assertions'
else
    mkdir -p /var/lib/spore && cp -r "$AV" /var/lib/spore/spore
    if AVN=$(alpine "$SPORE" --spore /var/lib/spore/spore plan 2>&1); then
        t_fail 'refuses to commit into the void' 'plan succeeded'
    else
        has 'refuses to commit into the void' "$AVN" 'converges on every boot and keeps'
    fi
    # ...but a host already configured by hand is deferred to, not overridden.
    SPORE_FACT_LBU_DEST=/media/data
    AVH=$(alpine "$SPORE" --spore /var/lib/spore/spore plan 2>&1)
    has 'a hand-configured host is kept' "$AVH" "kept (/media/data)"
    SPORE_FACT_LBU_DEST=unset
    rm -rf /var/lib/spore
fi
# Both keys at once is refused: LBU_BACKUPDIR wins in lbu, so the other would
# read as configured and never be written to.
printf 'APKOVL_BACKUPDIR=/media/storage/data\nAPKOVL_MEDIA=data\n' > "$AV/modules/apkovl.conf"
if AVB=$(alpine "$SPORE" --spore "$AV" plan 2>&1); then
    t_fail 'refuses both keys at once' 'plan succeeded'
else has 'refuses both keys at once' "$AVB" 'not both'; fi
# APKOVL_MEDIA is a name under /media; a path there yields /media//media/data.
printf 'APKOVL_MEDIA=/media/data\n' > "$AV/modules/apkovl.conf"
if AVM=$(alpine "$SPORE" --spore "$AV" plan 2>&1); then
    t_fail 'refuses a path in APKOVL_MEDIA' 'plan succeeded'
else has 'refuses a path in APKOVL_MEDIA' "$AVM" 'a name under /media, not a path'; fi
unset SPORE_FACT_LBU_DEST
rm -rf "$AV" "$AVR"

section 'the destination is created last, after volumes are mounted'
# lbu writes into its destination but never creates it, and that directory
# usually sits on a partition a firstboot action mounted a moment ago. Creating
# it any earlier makes a directory that the mount then hides.
AD=$(mktemp -d /tmp/spore-apkovldir.XXXXXX)
ADLOG=$(mktemp /tmp/spore-apkovllog.XXXXXX)
export SPORE_FACT_LBU_DEST=/media/storage/data SPORE_RUN_LOG="$ADLOG"
alpine "$SPORE" --spore "$EX" --root "$AD" persist >/dev/null 2>&1
unset SPORE_RUN_LOG SPORE_FACT_LBU_DEST
has 'the destination is created' "$(cat "$ADLOG")" 'mkdir -p'
AD_MK=$(grep -n 'mkdir -p' "$ADLOG" | tail -1 | cut -d: -f1)
AD_CM=$(grep -n 'lbu commit' "$ADLOG" | head -1 | cut -d: -f1)
if [ -n "$AD_MK" ] && [ -n "$AD_CM" ] && [ "$AD_MK" -lt "$AD_CM" ]; then
    t_ok 'and created before the commit, not after'
else
    t_fail 'and created before the commit, not after' "mkdir [$AD_MK], commit [$AD_CM]"
fi
rm -rf "$AD" "$ADLOG"

section 'a root password the spore sets itself counts, and lands before sshd'
# Booting with no root password is normal; being reachable in that state is not.
# So the question ssh has to answer is not "does root have a password" but "will
# it have one by the time sshd starts" — and a spore that seals one sets it in
# the firstboot pass, which runs before any service is enabled.
#
# Planning never decrypts, so an empty ciphertext is enough to assert this.
RP=$(mktemp -d /tmp/spore-rootpw.XXXXXX)/s; cp -r "$EX" "$RP"
sed -i 's/^SSH_PERMIT_ROOT_LOGIN=.*/SSH_PERMIT_ROOT_LOGIN=yes/; s/^SSH_PASSWORD_AUTH=.*/SSH_PASSWORD_AUTH=yes/' \
    "$RP/modules/ssh.conf"
mkdir -p "$RP/secrets"; : > "$RP/secrets/root.password.age"
export SPORE_FACT_ROOT_PASSWORD=empty
if RPP=$(alpine "$SPORE" --spore "$RP" plan 2>&1); then
    t_ok 'root login is no longer refused'
else
    t_fail 'root login is no longer refused' "$RPP"
fi
has 'the sealed root password is planned' "$RPP" 'firstboot  user-root-password'
# The ordering is the whole argument, so assert it on the commands that would
# actually run, not on the plan listing (which groups by module, not by phase).
RPR=$(mktemp -d /tmp/spore-rootpwroot.XXXXXX)
RPLOG=$(mktemp /tmp/spore-rootpwlog.XXXXXX)
export SPORE_RUN_LOG="$RPLOG"
alpine "$SPORE" --spore "$RP" --root "$RPR" apply >/dev/null 2>&1 || true
unset SPORE_RUN_LOG
RP_LASTSH=$(grep -n '^sh ' "$RPLOG" | tail -1 | cut -d: -f1)
RP_SSHD=$(grep -n 'rc-update add sshd' "$RPLOG" | head -1 | cut -d: -f1)
if [ -n "$RP_LASTSH" ] && [ -n "$RP_SSHD" ] && [ "$RP_LASTSH" -lt "$RP_SSHD" ]; then
    t_ok 'and every firstboot script runs before sshd is enabled'
else
    t_fail 'and every firstboot script runs before sshd is enabled' \
        "last script [$RP_LASTSH], sshd [$RP_SSHD]"
fi
rm -rf "$RPR" "$RPLOG"

# Take the secret away and the refusal must come back: it is the sealed password
# doing the work, not a weakened check.
rm -f "$RP/secrets/root.password.age"
if RPN=$(alpine "$SPORE" --spore "$RP" plan 2>&1); then
    t_fail 'without it the refusal returns' 'plan succeeded'
else
    t_ok 'without it the refusal returns'
    has 'and the refusal names the fix' "$RPN" 'seal root.password'
fi
unset SPORE_FACT_ROOT_PASSWORD
rm -rf "$RP"
sed -i 's/^USERS=.*/USERS=""/' "$UK/modules/users.conf"
sed -i 's/^USERS_DOAS=.*/USERS_DOAS=""/' "$UK/modules/users.conf"
sed -i 's/^SSH_ENABLED=.*/SSH_ENABLED=no/' "$UK/modules/ssh.conf"
UKP=$(alpine "$SPORE" --spore "$UK" plan 2>&1)
has 'ssh disabled plans it off' "$UKP" 'svc        sshd -> default [off]'
# With a key present, account creation and key install are one action.
mkdir -p "$UK/keys"
sed -i 's/^USERS=.*/USERS="gui"/' "$UK/modules/users.conf"
printf 'ssh-ed25519 AAAATEST tester\n' > "$UK/keys/gui.authorized_keys"
UKR=$(mktemp -d)
alpine "$SPORE" --spore "$UK" --root "$UKR" apply >/dev/null 2>&1
UKW=$(mktemp -d)
SPORE_WORK=$UKW alpine "$SPORE" --spore "$UK" plan >/dev/null 2>&1
UKS=$(cat "$UKW"/content/* 2>/dev/null | grep -A6 'adduser -D')
has 'installs the key with the account' "$UKS" '/home/gui/.ssh'
has 'and the key content itself'        "$UKS" 'ssh-ed25519 AAAATEST'
has 'a keyed account is a usable login' "$(alpine "$SPORE" --spore "$UK" plan 2>&1)" 'firstboot  user-gui'
rm -rf "$UK" "$UKR" "$UKW"
has 'hostname written'                "$(cat "$R/etc/hostname")"        'changeme'

section 'a machine brings its own network up before it fetches anything'
# The first thing apply does on a fresh box is `apk update`, and a stock
# diskless Alpine has no /etc/network/interfaces at all. Writing it only in the
# file pass is four phases too late: the run is already dead, at a failure that
# reads like a broken mirror rather than like a machine with no address.
has 'the interface is configured first of all' "$PLAN" 'netup      net-up'
NS=$(mktemp -d /tmp/spore-netstatic.XXXXXX)/s; cp -r "$EX" "$NS"
cat > "$NS/modules/net.conf" <<'NETC'
NET_HOSTNAME=coisas
NET_IFACE=eth0
NET_MODE=static
NET_ADDRESS=192.168.1.50
NET_NETMASK=255.255.255.0
NET_GATEWAY=192.168.1.1
NET_DNS="192.168.1.1 1.1.1.1"
NETC
NSR=$(mktemp -d /tmp/spore-netstaticroot.XXXXXX)
alpine "$SPORE" --spore "$NS" --root "$NSR" apply >/dev/null 2>&1
NSI=$(cat "$NSR/etc/network/interfaces")
has 'a static address is written'  "$NSI" 'address 192.168.1.50'
has 'with its gateway'             "$NSI" 'gateway 192.168.1.1'
has 'and resolvers'                "$(cat "$NSR/etc/resolv.conf")" 'nameserver 1.1.1.1'
# An unset address would otherwise produce an interfaces file that claims static
# and names nowhere, which fails at boot rather than here.
sed -i 's/^NET_ADDRESS=.*/NET_ADDRESS=/' "$NS/modules/net.conf"
has 'static with no address is refused, not written' \
    "$(alpine "$SPORE" --spore "$NS" plan 2>&1)" 'NET_ADDRESS is unset'
rm -rf "$NS" "$NSR"

section 'external commands the executor would have run'
CMDS=$(cat "$LOG")
has 'apk add openssh'          "$CMDS" 'apk add --no-progress openssh'
has 'apk add awall'            "$CMDS" 'apk add --no-progress awall'
has 'rc-update add sshd'       "$CMDS" 'rc-update add sshd default'
has 'rc-update add dufs'       "$CMDS" 'rc-update add dufs default'
has 'apk add dufs'             "$CMDS" 'apk add --no-progress dufs'
has 'apk add libcap for :443'  "$CMDS" 'apk add --no-progress libcap'

# The network has to be up before ANY of that: bootstrap actions run in the
# order modules were listed, so `repos` ahead of `net` in MODULES put apk update
# before the machine had an address. That failed as a DNS error, which reads as a
# bad mirror rather than a machine with no network — and it made reachability
# depend on the order of a line in a config file.
PHASES=$(cd "$ROOT" && sh -c '. ./lib/plan.sh 2>/dev/null; printf "%s" "$SPORE_ACTION_ORDER"')
case $PHASES in
    'netup bootstrap pkg'*) t_ok 'the network is brought up before every other phase' ;;
    *) t_fail 'the network is brought up before every other phase' "order is [$PHASES]" ;;
esac

# The ordering invariant: enabling community must precede every apk add, or
# `apk add dufs` fails on a stock Alpine.
FIRST_APK=$(grep -n 'apk add' "$LOG" | head -1 | cut -d: -f1)
FIRST_SH=$(grep -n '^sh ' "$LOG" | head -1 | cut -d: -f1)
if [ -n "$FIRST_SH" ] && [ -n "$FIRST_APK" ] && [ "$FIRST_SH" -lt "$FIRST_APK" ]; then
    t_ok 'bootstrap scripts run before any apk add'
else
    t_fail 'bootstrap scripts run before any apk add' "first sh=$FIRST_SH first apk=$FIRST_APK"
fi

# Services start last. The accounts they run as, the capabilities they need and
# the volumes they serve are all firstboot work; starting first fails in ways
# that look like the service itself is broken.
LAST_SH=$(grep -n '^sh ' "$LOG" | tail -1 | cut -d: -f1)
FIRST_RC=$(grep -n '^rc-update' "$LOG" | head -1 | cut -d: -f1)
if [ -n "$LAST_SH" ] && [ -n "$FIRST_RC" ] && [ "$LAST_SH" -lt "$FIRST_RC" ]; then
    t_ok 'every firstboot script runs before any service is touched'
else
    t_fail 'every firstboot script runs before any service is touched' \
        "last sh=$LAST_SH first rc-update=$FIRST_RC"
fi

section 'firewall policy is generated from other modules ports'
AW=$(cat "$R/etc/awall/optional/spore.json")
has 'opens ssh port'  "$AW" '"spore-tcp-22": { "proto": "tcp", "port": [22] }'
has 'opens dufs port' "$AW" '"spore-tcp-443": { "proto": "tcp", "port": [443] }'
if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import json,sys; json.load(open('$R/etc/awall/optional/spore.json'))" 2>/dev/null
    then t_ok 'awall policy is valid JSON'; else t_fail 'awall policy is valid JSON'; fi
fi

# ---------------------------------------------------------- idempotence -----
section 'idempotence'
LOG2=$(mktemp /tmp/spore-log2.XXXXXX)
export SPORE_RUN_LOG="$LOG2"
OUT2=$(alpine "$SPORE" --spore "$EX" --root "$R" apply 2>&1)
unset SPORE_RUN_LOG
has   'second apply changes nothing'      "$OUT2" '0 changed,'
check 'second apply runs no commands'     "$(wc -l < "$LOG2" | tr -d ' ')" 0

# -------------------------------------------------------------- dry run -----
section 'dry run'
R2=$(mktemp -d /tmp/spore-dry.XXXXXX)
DRY=$(alpine "$SPORE" --spore "$EX" --root "$R2" --dry-run apply 2>&1)
has   'announces writes'          "$DRY" 'would write file /etc/dufs/config.yaml'
has   'announces package install' "$DRY" 'would install package openssh'
check 'writes nothing at all'     "$(find "$R2" -mindepth 1 | wc -l | tr -d ' ')" 0

# --------------------------------------------------------------- status -----
section 'status and diff'
ST=$(alpine "$SPORE" --spore "$EX" --root "$R" status 2>&1)
has 'status clean after apply' "$ST" 'ssh        ok'
printf '# tampered\n' >> "$R/etc/dufs/config.yaml"
ST2=$(alpine "$SPORE" --spore "$EX" --root "$R" status 2>&1)
has 'status detects drift'     "$ST2" 'dufs       1 of'
DF=$(alpine "$SPORE" --spore "$EX" --root "$R" diff 2>&1)
has 'diff shows the tampering' "$DF" 'tampered'

# --------------------------------------------------------- facts matrix -----
section 'facts matrix: same spore, different hosts'
R3=$(mktemp -d /tmp/spore-lxc.XXXXXX)
LXC=$(env SPORE_FACT_INIT=openrc SPORE_FACT_NETADMIN=no SPORE_FACT_PERSIST=rootfs \
          SPORE_FACT_ARCH=x86_64 SPORE_FACT_ROOT=yes \
          "$SPORE" --spore "$EX" --root "$R3" apply 2>&1)
has   'unprivileged LXC: firewall n/a'     "$LXC" 'firewall: n/a here (no NET_ADMIN)'
has   'unprivileged LXC: hostname applied' "$LXC" 'file /etc/hostname'
has   'unprivileged LXC: dufs still fine'  "$LXC" 'file /etc/dufs/config.yaml'
has   'unprivileged LXC: interfaces skipped' "$LXC" 'interfaces and DNS skipped'
check 'unprivileged LXC: no awall policy'  "$([ -f "$R3/etc/awall/optional/spore.json" ] && echo yes || echo no)" no
hasnt 'unprivileged LXC: no diskless warning' "$LXC" 'nothing here survives a reboot'

R4=$(mktemp -d /tmp/spore-noinit.XXXXXX)
NOINIT=$(env SPORE_FACT_INIT=none SPORE_FACT_NETADMIN=no SPORE_FACT_PERSIST=rootfs \
             SPORE_FACT_ARCH=x86_64 SPORE_FACT_ROOT=yes \
             "$SPORE" --spore "$EX" --root "$R4" apply 2>&1)
has 'no OpenRC: ssh n/a'  "$NOINIT" 'ssh: n/a here (no OpenRC)'
has 'no OpenRC: dufs n/a' "$NOINIT" 'dufs: n/a here (no OpenRC)'

section 'arch handling'
# dufs is arch=all in Alpine community, so nothing in the example spore is
# arch-specific any more; the spore must still plan cleanly on aarch64.
A64=$(env SPORE_FACT_INIT=openrc SPORE_FACT_NETADMIN=yes SPORE_FACT_PERSIST=lbu \
          SPORE_FACT_ARCH=aarch64 SPORE_FACT_ROOT=yes "$SPORE" --spore "$EX" plan 2>&1)
has 'aarch64 plans the same package' "$A64" 'pkg        dufs'

# The blob path is still there for genuinely unpackaged things, so its per-arch
# resolution is tested directly.
BS=$(mktemp -d /tmp/spore-blobs.XXXXXX)
cat > "$BS/blobs.conf" <<'BLOBS'
# name arch url sha256 dest mode member
tool  x86_64   https://example.invalid/tool-amd64.tgz  aaaa  /usr/local/bin/tool  0755  tool
tool  aarch64  https://example.invalid/tool-arm64.tgz  bbbb  /usr/local/bin/tool  0755  tool
BLOBS
lookup() {
    env SPORE_DIR="$BS" sh -c '
        . '"$ROOT"'/lib/core.sh; . '"$ROOT"'/lib/blob.sh
        SPORE_DIR='"$BS"'
        blob_lookup tool '"$1"'
    ' 2>/dev/null
}
has   'blob lookup picks x86_64'   "$(lookup x86_64)"  'tool-amd64.tgz'
has   'blob lookup picks aarch64'  "$(lookup aarch64)" 'tool-arm64.tgz'
check 'blob lookup fails on unknown arch' "$(lookup riscv64 >/dev/null 2>&1 && echo found || echo absent)" absent
rm -rf "$BS"

# --------------------------------------------------- marked block append -----
section 'owned block appends to a stock config and stays idempotent'
R5=$(mktemp -d /tmp/spore-stock.XXXXXX)
mkdir -p "$R5/etc/ssh"
printf '# stock alpine sshd_config\nAcceptEnv LANG\n' > "$R5/etc/ssh/sshd_config"
alpine "$SPORE" --spore "$EX" --root "$R5" apply >/dev/null 2>&1
SC=$(cat "$R5/etc/ssh/sshd_config")
has   'stock content preserved'    "$SC" 'AcceptEnv LANG'
has   'owned block appended'       "$SC" '# BEGIN spore:sshd'
check 'original kept as .spore-orig' "$([ -f "$R5/etc/ssh/sshd_config.spore-orig" ] && echo yes || echo no)" yes
alpine "$SPORE" --spore "$EX" --root "$R5" apply >/dev/null 2>&1
check 'block not duplicated on re-apply' "$(grep -c '# BEGIN spore:sshd' "$R5/etc/ssh/sshd_config")" 1

# ------------------------------------------------------------- conflicts -----
section 'conflicting claims are refused, not resolved by emit order'
CS=$(mktemp -d /tmp/spore-conflict.XXXXXX)/s
mkdir -p "$CS/modules" "$CS/files/etc"
printf 'FORMAT=1\nHOST=x\nMODULES="net"\n' > "$CS/spore.conf"
printf 'NET_HOSTNAME=x\n' > "$CS/modules/net.conf"
printf 'clash\n' > "$CS/files/etc/hostname"
if CONF=$(alpine "$SPORE" --spore "$CS" plan 2>&1); then
    t_fail 'planner refuses conflicting claims' 'plan succeeded'
else
    has 'planner refuses conflicting claims' "$CONF" 'written by both'
fi

# ----------------------------------------------------------------- blob -----
section 'blob verification (hermetic, file:// — no network)'
BD=$(mktemp -d /tmp/spore-blob.XXXXXX)
mkdir -p "$BD/src"; printf '#!/bin/sh\necho hi\n' > "$BD/src/tool"
tar -czf "$BD/tool.tar.gz" -C "$BD/src" tool
GOOD=$(sha256sum "$BD/tool.tar.gz" | cut -d' ' -f1)

# shellcheck disable=SC2016  # deliberate quote-splicing to inject paths
blob_probe() {
    env SPORE_ROOT=/ SPORE_WORK="$BD" sh -c '
        SPORE_LIB='"$ROOT"'/lib
        . "$SPORE_LIB/core.sh"; . "$SPORE_LIB/blob.sh"
        SPORE_ROOT=/; SPORE_WORK='"$BD"'
        blob_install probe "file://'"$BD"'/tool.tar.gz" "'"$1"'" "'"$BD"'/out/tool" 0755 tool
    ' 2>&1
}
if blob_probe "$GOOD" >/dev/null 2>&1 && [ -x "$BD/out/tool" ]; then
    t_ok 'correct checksum installs and extracts'
else
    t_fail 'correct checksum installs and extracts' "$(blob_probe "$GOOD")"
fi
rm -rf "$BD/out"
BAD=$(blob_probe 0000000000000000000000000000000000000000000000000000000000000000 || true)
has   'wrong checksum is rejected'  "$BAD" 'checksum mismatch'
check 'nothing installed on mismatch' "$([ -e "$BD/out/tool" ] && echo yes || echo no)" no

# ---------------------------------------------------------------- repos -----
section 'enabling community survives every shape of /etc/apk/repositories'
RW=$(mktemp -d /tmp/spore-repos.XXXXXX)
SPORE_WORK=$RW alpine "$SPORE" --spore "$EX" plan >/dev/null 2>&1
RSHA=$(awk -F'\t' '$2 == "bootstrap" && $3 == "repos-community" { print $4 }' "$RW/plan.tsv")
RSCRIPT=$RW/content/$RSHA

repos_case() {
    rc_d=$(mktemp -d); mkdir -p "$rc_d/etc/apk"
    printf '%s\n' "$2" > "$rc_d/etc/apk/repositories"
    sed "s|/etc/apk/repositories|$rc_d/etc/apk/repositories|g; s|^apk update|true|" "$RSCRIPT" > "$rc_d/run.sh"
    sh "$rc_d/run.sh" >/dev/null 2>&1 || true
    rc_n=$(grep -cE '^[^#]*/community' "$rc_d/etc/apk/repositories" 2>/dev/null || echo 0)
    rc_keep=$(grep -c . "$rc_d/etc/apk/repositories")
    printf '%s %s' "$rc_n" "$rc_keep"
    rm -rf "$rc_d"
}

# A configured box: community present but commented out.
check 'uncomments a commented community' \
    "$(repos_case x "$(printf 'https://x/alpine/v3.20/main\n#https://x/alpine/v3.20/community')")" '1 2'
# A freshly booted box: no community line exists at all to uncomment.
check 'derives community when absent' \
    "$(repos_case x 'https://x/alpine/v3.20/main')" '1 2'
# Already correct: must not add a duplicate.
check 'leaves an enabled community alone' \
    "$(repos_case x "$(printf 'https://x/alpine/v3.20/main\nhttps://x/alpine/v3.20/community')")" '1 2'
# A booted ISO: a local apks repo alongside the network mirror, which must survive.
check 'keeps a local ISO repo and still adds community' \
    "$(repos_case x "$(printf '/media/usb/apks\nhttps://x/alpine/v3.20/main')")" '1 3'

# A freshly booted ISO before setup-apkrepos: only its own local repository, no
# mirror to derive community from. Refusing is right; refusing silently is not.
repos_err() {
    re_d=$(mktemp -d); mkdir -p "$re_d/etc/apk"
    printf '%s\n' "$1" > "$re_d/etc/apk/repositories"
    sed "s|/etc/apk/repositories|$re_d/etc/apk/repositories|g; s|^apk update|true|" "$RSCRIPT" > "$re_d/run.sh"
    { sh "$re_d/run.sh" >/dev/null; } 2>&1 || true
    rm -rf "$re_d"
}
RERR=$(repos_err '/media/sr0/apks')
has 'booted ISO with no mirror is a clear error' "$RERR" 'no active /main repository'
has 'and says how to fix it'                     "$RERR" 'setup-apkrepos -1'
rm -rf "$RW"

# -------------------------------------------------------------- storage -----
section 'storage: declared volumes, fstab as an owned block'
ST=$(mktemp -d /tmp/spore-stor.XXXXXX)
mkdir -p "$ST/etc"
cat > "$ST/etc/fstab" <<'FSTAB'
# /etc/fstab: static file system information
UUID=root-uuid  /      ext4  rw,relatime  0 1
tmpfs           /tmp   tmpfs defaults     0 0
FSTAB
alpine "$SPORE" --spore "$EX" --root "$ST" apply >/dev/null 2>&1
FS=$(cat "$ST/etc/fstab")

has 'existing root entry survives'  "$FS" 'UUID=root-uuid  /      ext4'
has 'existing tmpfs entry survives' "$FS" 'tmpfs           /tmp'
has 'block is owned and delimited'  "$FS" '# BEGIN spore:storage'
check 'original fstab kept as .spore-orig' \
    "$([ -f "$ST/etc/fstab.spore-orig" ] && echo yes || echo no)" yes

has 'ext4 volume mounted by LABEL' "$FS" 'LABEL=archive	/media/storage/archive	ext4	noatime,nofail'
has 'exfat gets umask, not chown'  "$FS" 'UUID=A1B2-C3D4	/media/storage/photos	exfat	noatime,nofail,umask=000'
has 'boot medium is a bind mount'  "$FS" '/media/usb	/media/storage/bootusb	none	bind,nofail'

# nofail on every generated entry: an absent disk must never block boot.
NOFAIL_MISSING=$(awk '/BEGIN spore:storage/,/END spore:storage/' "$ST/etc/fstab" \
                 | grep -v '^#' | grep -c -v 'nofail' || true)
check 'every entry carries nofail' "$NOFAIL_MISSING" 0

has 'filesystem tools installed per type' "$(alpine "$SPORE" --spore "$EX" plan 2>&1)" 'pkg        exfatprogs'
check 'mountpoints created' \
    "$([ -d "$ST/media/storage/archive" ] && [ -d "$ST/media/storage/photos" ] && echo yes || echo no)" yes

alpine "$SPORE" --spore "$EX" --root "$ST" apply >/dev/null 2>&1
check 'block not duplicated on re-apply' "$(grep -c 'BEGIN spore:storage' "$ST/etc/fstab")" 1

SST=$(alpine "$SPORE" --spore "$EX" --root "$ST" status 2>&1)
has 'status reports live mount state' "$SST" '/media/storage/archive NOT mounted'
rm -rf "$ST"

section 'storage refuses what it cannot make safe'
BADS=$(mktemp -d /tmp/spore-badstor.XXXXXX)/s
cp -r "$EX" "$BADS"
cat > "$BADS/volumes.conf" <<'BADV'
../escape  LABEL=x        ext4  -
weird      notaspec       ext4  -
risky      LABEL=y        ext4  noatime
BADV
BADP=$(alpine "$SPORE" --spore "$BADS" plan 2>&1)
has 'rejects a name that escapes the root'  "$BADP" "name must be alphanumeric"
has 'rejects an unrecognised spec'          "$BADP" "is not UUID=, LABEL="
has 'warns when custom options omit nofail' "$BADP" 'without nofail'
rm -rf "$BADS"

section 'directory claims: agreement is not conflict'
# storage and dufs both want /media/storage to exist. Same mode, so that is
# agreement, not a conflict.
has 'shared dir at the same mode is allowed' "$(alpine "$SPORE" --spore "$EX" plan 2>&1)" 'dir        /media/storage (0755)'

CD=$(mktemp -d /tmp/spore-dirclash.XXXXXX)/s
cp -r "$EX" "$CD"
printf 'STORAGE_ROOT=/srv/shared\n' > "$CD/modules/storage.conf"
printf 'DUFS_SERVE=/srv/shared\n' >> "$CD/modules/dufs.conf"
sed -i 's|^archive .*|archive  LABEL=archive  ext4  -|' "$CD/volumes.conf"
if CDP=$(alpine "$SPORE" --spore "$CD" plan 2>&1); then
    t_ok 'same dir at the same mode from two modules plans fine'
else
    t_fail 'same dir at the same mode from two modules plans fine' "$CDP"
fi
rm -rf "$CD"

# ------------------------------------------------------------- lbu dest -----
section 'where the apkovl actually goes is reported, and its absence warned'
export SPORE_FACT_LBU_DEST=/media/data
LD=$(alpine "$SPORE" --spore "$EX" doctor 2>&1)
has   'doctor names the apkovl destination' "$LD" 'apkovl to /media/data'
hasnt 'and does not warn when it is set'    "$LD" 'names no destination'
SPORE_FACT_LBU_DEST='unset'
LDU=$(alpine "$SPORE" --spore "$EX" doctor 2>&1)
has 'unset destination is warned'                  "$LDU" 'names no destination'
has 'and explains a read-only boot medium is fine' "$LDU" 'boot medium can stay read-only'
unset SPORE_FACT_LBU_DEST
# Not mentioned at all on a host with no lbu.
LDR=$(env SPORE_FACT_INIT=openrc SPORE_FACT_NETADMIN=no SPORE_FACT_PERSIST=rootfs \
          SPORE_FACT_ROOT=yes "$SPORE" --spore "$EX" doctor 2>&1)
hasnt 'not mentioned on a non-diskless host' "$LDR" 'apkovl to'

# ------------------------------------------------------------- ca store -----
section 'a broken CA trust store is reported, not left silent'
export SPORE_FACT_CA_STORE=ok
CAOK=$(alpine "$SPORE" --spore "$EX" doctor 2>&1)
has   'doctor reports the store'      "$CAOK" 'ca store  ok'
hasnt 'and says nothing when it is fine' "$CAOK" 'CA trust store'
SPORE_FACT_CA_STORE=missing
CAMISS=$(alpine "$SPORE" --spore "$EX" doctor 2>&1)
has 'missing store is explained'      "$CAMISS" 'unable to get local issuer certificate'
has 'and names the fix'               "$CAMISS" 'apk add ca-certificates-bundle'
SPORE_FACT_CA_STORE=empty
CAEMPTY=$(alpine "$SPORE" --spore "$EX" doctor 2>&1)
has 'empty store is distinguished'    "$CAEMPTY" 'holds no certificates'
has 'and warns update-ca-certificates can cause it' "$CAEMPTY" 'can leave it empty'
has 'and warns that s_client will mislead'          "$CAEMPTY" 'does not mean this is fine'
unset SPORE_FACT_CA_STORE

# ----------------------------------------------------------------- blob -----
section 'a planned blob brings its own CA trust store'
# A freshly booted Alpine often has no CA store. apk carries its own, so package
# installs succeed and the first HTTPS blob fetch fails with "unable to get local
# issuer certificate" — which reads like a network fault, not a missing package.
BT=$(mktemp -d /tmp/spore-blobplan.XXXXXX)/s
cp -r "$EX" "$BT"
cat > "$BT/blobs.conf" <<'BLOBC'
tool  x86_64   https://example.invalid/t.tgz  aaaa  /usr/local/bin/tool  0755  tool
tool  aarch64  https://example.invalid/t.tgz  bbbb  /usr/local/bin/tool  0755  tool
BLOBC
cat > "$ROOT/modules/zz-blobprobe.sh" <<'PROBE'
zz-blobprobe_meta() { MOD_DESC='test-only'; MOD_REQUIRES=''; }
PROBE
# module names are shell function prefixes, so use a valid identifier
rm -f "$ROOT/modules/zz-blobprobe.sh"
cat > "$ROOT/modules/blobprobe.sh" <<'PROBE'
blobprobe_meta() { MOD_DESC='test-only blob probe'; MOD_REQUIRES=''; }
blobprobe_plan() { plan_blob tool; }
PROBE
sed -i 's/^MODULES=.*/MODULES="blobprobe"/' "$BT/spore.conf"
BTP=$(alpine "$SPORE" --spore "$BT" plan 2>&1)
has 'blob is planned'                  "$BTP" 'blob       tool -> /usr/local/bin/tool'
has 'the trust bundle comes with it'   "$BTP" 'pkg        ca-certificates-bundle'
# and is not dragged in when nothing fetches over HTTPS
hasnt 'not added when no blob is planned' "$(alpine "$SPORE" --spore "$EX" plan 2>&1)" 'pkg        ca-certificates-bundle'
rm -f "$ROOT/modules/blobprobe.sh"; rm -rf "$BT"

# -------------------------------------------------------------- secrets -----
section 'secrets travel sealed, never in cleartext'
if ! command -v age >/dev/null 2>&1; then
    printf '  skip  age not installed\n'
else
    SD=$(mktemp -d /tmp/spore-sec.XXXXXX)
    cp -r "$EX" "$SD/s"
    mkdir -p "$SD/s/secrets"
    age-keygen -o "$SD/identity" 2>"$SD/pub"
    grep -o 'age1[a-z0-9]*' "$SD/pub" > "$SD/s/secrets/recipients"
    sed -i "s|^SECRETS_IDENTITY=.*|SECRETS_IDENTITY=$SD/identity|" "$SD/s/spore.conf"

    # a single-line field secret, and a multi-line whole-file secret
    printf 'admin:hunter2@/:rw' | "$SPORE" --spore "$SD/s" seal dufs-auth >/dev/null
    openssl genpkey -algorithm ed25519 -out "$SD/hostkey" 2>/dev/null
    KEY_SHA=$(sha256sum "$SD/hostkey" | cut -d' ' -f1)
    "$SPORE" --spore "$SD/s" seal ssh_host_ed25519_key "$SD/hostkey" >/dev/null
    printf 'DUFS_AUTH_SECRET=dufs-auth\n' >> "$SD/s/modules/dufs.conf"
    printf 'SSH_HOST_KEY_SECRETS="ssh_host_ed25519_key"\n' >> "$SD/s/modules/ssh.conf"

    check 'sealed file is age ciphertext' \
        "$(head -c 14 "$SD/s/secrets/dufs-auth.age")" 'age-encryption'
    hasnt 'ciphertext does not contain the password' \
        "$(cat "$SD/s/secrets/dufs-auth.age")" 'hunter2'

    SP=$(alpine "$SPORE" --spore "$SD/s" plan 2>&1)
    has 'config carrying a password becomes a secret action' "$SP" 'secret     /etc/dufs/config.yaml'
    has 'host key is a secret action'                        "$SP" 'secret     /etc/ssh/ssh_host_ed25519_key'
    has 'age is installed before secrets are written'        "$SP" 'pkg        age'
    hasnt 'plan never shows the password'                    "$SP" 'hunter2'

    SR=$(mktemp -d /tmp/spore-secroot.XXXXXX)
    SW=$(mktemp -d /tmp/spore-secwork.XXXXXX)
    SPORE_WORK=$SW alpine "$SPORE" --spore "$SD/s" --root "$SR" apply >/dev/null 2>&1

    # The property that matters: plaintext never enters the plan.
    if grep -rq -e hunter2 -e 'PRIVATE KEY' "$SW" 2>/dev/null
    then t_fail 'plaintext never enters the plan workspace' "found under $SW"
    else t_ok 'plaintext never enters the plan workspace'; fi
    has 'content store holds only a marker' \
        "$(cat "$SW"/content/* 2>/dev/null)" '@@SECRET:dufs-auth@@'

    check 'whole-file secret round-trips byte for byte' \
        "$(sha256sum "$SR/etc/ssh/ssh_host_ed25519_key" | cut -d' ' -f1)" "$KEY_SHA"
    check 'host key is 0600' "$(file_mode "$SR/etc/ssh/ssh_host_ed25519_key")" 600
    check 'secret-bearing config is 0640' "$(file_mode "$SR/etc/dufs/config.yaml")" 640
    has 'field secret substituted on the host' \
        "$(cat "$SR/etc/dufs/config.yaml")" 'admin:hunter2@/:rw'

    # diff must compare without ever printing the value
    printf '# drift\n' >> "$SR/etc/dufs/config.yaml"
    SDF=$(alpine "$SPORE" --spore "$SD/s" --root "$SR" diff 2>&1)
    has   'diff reports a drifted secret'    "$SDF" 'differs from the spore; content withheld'
    hasnt 'diff never prints the password'   "$SDF" 'hunter2'

    SEC2=$(alpine "$SPORE" --spore "$SD/s" --root "$SR" apply 2>&1)
    has 'secrets are idempotent once correct' "$SEC2" '. secret /etc/ssh/ssh_host_ed25519_key'

    # dry run must not require the identity at all
    SDRY=$(env SPORE_IDENTITY=/nonexistent SPORE_FACT_INIT=openrc SPORE_FACT_NETADMIN=yes \
               SPORE_FACT_PERSIST=lbu SPORE_FACT_ROOT=yes \
               "$SPORE" --spore "$SD/s" --root "$(mktemp -d)" --dry-run apply 2>&1)
    has 'dry run needs no identity' "$SDRY" 'would write secret /etc/dufs/config.yaml'

    # a missing identity must fail loudly, not silently write a marker
    SBAD=$(env SPORE_IDENTITY=/nonexistent SPORE_FACT_INIT=openrc SPORE_FACT_NETADMIN=yes \
                SPORE_FACT_PERSIST=lbu SPORE_FACT_ROOT=yes \
                "$SPORE" --spore "$SD/s" --root "$(mktemp -d)" apply 2>&1 || true)
    has 'missing identity is a clear error' "$SBAD" 'needs the identity at'

    # A sealed password: provisioned unattended, decrypted on the target.
    openssl passwd -6 hunter2 > "$SD/pwhash" 2>/dev/null
    "$SPORE" --spore "$SD/s" seal gui.password "$SD/pwhash" >/dev/null
    PWW=$(mktemp -d)
    SPORE_WORK=$PWW alpine "$SPORE" --spore "$SD/s" plan >/dev/null 2>&1
    PWP=$(alpine "$SPORE" --spore "$SD/s" plan 2>&1)
    has 'a sealed password is planned'  "$PWP" 'firstboot  user-gui-password'
    has 'and brings age with it'        "$PWP" 'pkg        age'
    PWS=$(grep -rl chpasswd "$PWW/content" 2>/dev/null | head -1)
    has 'decrypts on the target'        "$(cat "$PWS")" 'age --decrypt'
    has 'applies the hash encrypted'    "$(cat "$PWS")" 'chpasswd -e'
    if grep -rq '[$]6[$]' "$PWW" 2>/dev/null
    then t_fail 'the hash never enters the plan' "found under $PWW"
    else t_ok 'the hash never enters the plan'; fi
    # Rotating the secret must re-run the action; the stamp follows the script,
    # so the ciphertext's checksum is embedded in it.
    PWSHA1=$(grep '^# secret:' "$PWS")
    openssl passwd -6 different > "$SD/pwhash2" 2>/dev/null
    "$SPORE" --spore "$SD/s" seal gui.password "$SD/pwhash2" >/dev/null
    PWW2=$(mktemp -d)
    SPORE_WORK=$PWW2 alpine "$SPORE" --spore "$SD/s" plan >/dev/null 2>&1
    PWSHA2=$(grep -h '^# secret:' "$(grep -rl chpasswd "$PWW2/content" | head -1)")
    if [ "$PWSHA1" != "$PWSHA2" ]
    then t_ok 'rotating the password changes the action'
    else t_fail 'rotating the password changes the action' "both: $PWSHA1"; fi
    rm -rf "$PWW" "$PWW2"

    # A relative identity resolves against the spore, so it can sit beside one
    # mounted at a path nothing could have hardcoded.
    RD=$(mktemp -d)
    cp -r "$SD/s" "$RD/spore"
    cp "$SD/identity" "$RD/identity"
    sed -i 's|^SECRETS_IDENTITY=.*|SECRETS_IDENTITY=../identity|' "$RD/spore/spore.conf"
    RR=$(mktemp -d)
    if alpine "$SPORE" --spore "$RD/spore" --root "$RR" apply >/dev/null 2>&1
    then t_ok 'a relative identity resolves against the spore'
    else t_fail 'a relative identity resolves against the spore'; fi
    has 'and its secrets still decrypt' \
        "$(cat "$RR/etc/dufs/config.yaml" 2>/dev/null)" 'admin:hunter2@/:rw'
    rm -rf "$RD" "$RR"

    # naming a secret the spore does not carry is reported, not ignored
    printf 'SSH_HOST_KEY_SECRETS="ssh_host_rsa_key"\n' >> "$SD/s/modules/ssh.conf"
    SMISS=$(alpine "$SPORE" --spore "$SD/s" plan 2>&1)
    has 'missing secret is reported' "$SMISS" "does not carry"

    rm -rf "$SD" "$SR" "$SW"
fi

# ----------------------------------------------------------------- seed -----
section 'seed: a generic overlay that carries no configuration'
SEEDD=$(mktemp -d /tmp/spore-seed.XXXXXX)
SEEDF=$SEEDD/spore-seed.apkovl.tar.gz
# Deliberately no --spore: the overlay is host-independent.
SEEDOUT=$("$SPORE" seed "$SEEDF" 2>&1)
has   'builds without a spore'     "$SEEDOUT" 'wrote'
check 'the overlay exists'         "$([ -s "$SEEDF" ] && echo yes || echo no)" yes

SEEDLIST=$(tar -tzf "$SEEDF" | sed 's|^\./||')
has 'carries the first-boot hook'  "$SEEDLIST" 'usr/local/lib/spore/seed-run'
# Its own service rather than a local.d hook: local.d runs only if the `local`
# service happens to be present and enabled, and when it is not, nothing runs
# and nothing is written — not even a log to say so.
has 'as a service of its own'      "$SEEDLIST" 'etc/init.d/spore-seed'
has 'enabled in the default runlevel' "$SEEDLIST" 'etc/runlevels/default/spore-seed'
has 'carries the tool'             "$SEEDLIST" 'usr/local/bin/spore'
has 'keeps /usr/local across lbu'  "$SEEDLIST" 'etc/apk/protected_paths.d/spore.list'
# The point of the rework: no configuration inside the overlay.
hasnt 'carries no spore'           "$SEEDLIST" 'etc/spore/spore'
hasnt 'bakes no repository list'   "$SEEDLIST" 'etc/apk/repositories'

# The initramfs restores whatever ownership the archive records, and the overlay
# is normally built by an ordinary user on a workstation.
SEEDOWN=$(tar -tvzf "$SEEDF" | awk '{ print $2 }' | sort -u | tr '\n' ' ')
check 'everything is owned by root' "$SEEDOWN" '0/0 '

SEEDSTART=$(tar -xzOf "$SEEDF" ./usr/local/lib/spore/seed-run)
SEEDUNIT=$(tar -xzOf "$SEEDF" ./etc/init.d/spore-seed)
has 'the unit is an openrc script'    "$SEEDUNIT" '#!/sbin/openrc-run'
has 'and runs the seed'               "$SEEDUNIT" '/usr/local/lib/spore/seed-run'
# after, not need: a machine with no network still has a spore worth applying as
# far as it can get, and a hard dependency would stop it before it tried.
has 'ordered after mounts and network' "$SEEDUNIT" 'after localmount net'
hasnt 'without depending on them'      "$SEEDUNIT" 'need localmount'
has 'hook discovers a spore on media' "$SEEDSTART" '/media/*/spore'
has 'hook scans block devices too'    "$SEEDSTART" '/dev/sd'
# A VM guest is one of the two things this is for, and every hypervisor hands it
# a virtio disk. Scanning only sd/nvme/mmcblk found nothing there and called it
# "no spore on any attached filesystem" — true, and useless.
has 'including virtio disks'          "$SEEDSTART" '/dev/vd'
has 'and xen ones'                    "$SEEDSTART" '/dev/xvd'
has 'hook applies and persists'       "$SEEDSTART" 'apply --persist'
has 'hook is idempotent'              "$SEEDSTART" '/etc/spore/.seeded'
has 'hook retries after failure'      "$SEEDSTART" 'will retry on next boot'
has 'hook says what is missing'       "$SEEDSTART" 'no spore found'
# /var/log is on the RAM root, so a reboot takes the log — and rebooting is
# exactly what you do when the machine did not come up right. The evidence has
# to outlive the boot that produced it.
has 'the log is saved beside the spore' "$SEEDSTART" 'trap save_log EXIT'
has 'on every exit path, not just success' "$SEEDSTART" 'cp /var/log/spore-seed.log'
# Writing it only beside a found spore meant the one failure worth reporting —
# no spore found — could never report itself. Any filesystem carrying the seed
# is ours, and the FAT one needs no module to mount.
has 'and even when no spore was found'     "$SEEDSTART" 'spore-seed.apkovl.tar.gz'
has 'by scanning for the seed itself'      "$SEEDSTART" '/mnt/spore-log'

# The real property: unpacked onto a blank machine, the embedded tool runs a
# spore that was never inside the overlay.
SEEDX=$(mktemp -d /tmp/spore-seedx.XXXXXX)
tar -xzf "$SEEDF" -C "$SEEDX"
cp -r "$EX" "$SEEDX/spore"
SEEDPLAN=$(env SPORE_PREFIX="$SEEDX/usr/local/lib/spore" \
    SPORE_FACT_INIT=openrc SPORE_FACT_NETADMIN=yes SPORE_FACT_PERSIST=lbu \
    SPORE_FACT_ARCH=x86_64 SPORE_FACT_ROOT=yes \
    "$SEEDX/usr/local/lib/spore/bin/spore" -s "$SEEDX/spore" plan 2>&1)
has 'the unpacked tool runs a separate spore' "$SEEDPLAN" 'pkg        dufs'
has 'and plans the same modules'              "$SEEDPLAN" 'svc        sshd -> default [on]'
rm -rf "$SEEDD" "$SEEDX"

# -------------------------------------------------------------- persist -----
section 'persist backends'
PR=$(alpine "$SPORE" --spore "$EX" --root "$R" persist 2>&1)
has 'diskless backend commits to apkovl' "$PR" 'committed to apkovl'
PLOG=$(mktemp /tmp/spore-plog.XXXXXX)
export SPORE_RUN_LOG="$PLOG"
alpine "$SPORE" --spore "$EX" --root "$R" persist >/dev/null 2>&1
unset SPORE_RUN_LOG
has 'includes paths outside /etc' "$(cat "$PLOG")" 'lbu include /home'
has 'runs lbu commit'             "$(cat "$PLOG")" 'lbu commit'
# lbu returns once the write is issued, not once it has reached the medium.
has 'syncs after committing'      "$(cat "$PLOG")" 'sync'
# lbu remounts the medium rw itself and restores ro on exit. Doing it first would
# defeat that and leave a USB stick mounted writable.
hasnt 'does not remount the medium itself' "$(cat "$PLOG")" 'mount -o remount,rw'
hasnt 'does not include /etc (already in overlay)' "$(cat "$PLOG")" 'lbu include /etc'

PR2=$(env SPORE_FACT_INIT=openrc SPORE_FACT_NETADMIN=no SPORE_FACT_PERSIST=rootfs \
          SPORE_FACT_ARCH=x86_64 SPORE_FACT_ROOT=yes \
          "$SPORE" --spore "$EX" --root "$R3" persist 2>&1)
has 'rootfs backend exports the spore' "$PR2" 'nothing to commit'
check 'exported spore is readable' "$([ -f "$R3/var/lib/spore/spore/spore.conf" ] && echo yes || echo no)" yes

# ------------------------------------------------------------ bootstrap -----
# The workstation side. Everything here exists because it used to be done by
# hand, and each step had its own way of failing quietly.
section 'spore setup: the guided path'
# The whole point is that the answers produce a spore that plans as a target —
# so it is driven here exactly as a person would, and then planned.
WZ=$(mktemp -d /tmp/spore-wiz.XXXXXX)
printf 'ssh-ed25519 AAAAC3WizardTestKey tester@workstation\n' > "$WZ/id.pub"
printf '%s\n' \
    'wizhost' 'br br-abnt2' 'America/Sao_Paulo' 'chrony' 'eth0' 'static' \
    '192.168.1.50' '255.255.255.0' '192.168.1.1' '192.168.1.1 1.1.1.1' \
    'https://mirror.ufpr.br/alpine' \
    'tester' 'y' "$WZ/id.pub" 'y' '2222' 'n' |
    SPORE_PUBKEY="$WZ/id.pub" "$SPORE" setup "$WZ/m" >"$WZ/out" 2>&1 || true
WZOUT=$(cat "$WZ/out")
WZS=$WZ/m/spore

check 'the host is what was answered' "$(grep '^HOST=' "$WZS/spore.conf")" 'HOST=wizhost'
# The directory is derived from the hostname, never asked: a path typed at a
# prompt is one more thing to get wrong for no decision gained.
hasnt 'the directory is not asked for' "$WZOUT" 'Directory to create'
has   'only the modules asked about'  "$(grep '^MODULES=' "$WZS/spore.conf")" 'repos system net users ssh apkovl'
hasnt 'no file server nobody asked for' "$(grep '^MODULES=' "$WZS/spore.conf")" 'dufs'
hasnt 'and no volumes that do not exist' "$(grep '^MODULES=' "$WZS/spore.conf")" 'storage'
check 'the static address is recorded' "$(grep '^NET_ADDRESS=' "$WZS/modules/net.conf")" \
                                       'NET_ADDRESS=192.168.1.50'
check 'the keymap, as setup-keymap takes it' "$(grep '^SYSTEM_KEYMAP=' "$WZS/modules/system.conf")" \
                                       'SYSTEM_KEYMAP="br br-abnt2"'
check 'the timezone'                  "$(grep '^SYSTEM_TIMEZONE=' "$WZS/modules/system.conf")" \
                                       'SYSTEM_TIMEZONE=America/Sao_Paulo'
check 'the account'                   "$(grep '^USERS=' "$WZS/modules/users.conf")" 'USERS="tester"'
check 'the key it was given'          "$(cat "$WZS/keys/tester.authorized_keys")" \
                                       'ssh-ed25519 AAAAC3WizardTestKey tester@workstation'
check 'ssh on the port answered'      "$(grep '^SSH_PORT=' "$WZS/modules/ssh.conf")" 'SSH_PORT=2222'

# The property that matters: what it wrote is a spore that will actually apply.
if WZP=$(env SPORE_FACT_ROOT=yes SPORE_FACT_INIT=openrc SPORE_FACT_NETADMIN=yes \
             SPORE_FACT_PERSIST=lbu SPORE_FACT_ROOT_PASSWORD=empty \
             "$SPORE" -s "$WZS" plan 2>&1); then
    t_ok 'and the result plans for an Alpine target'
else
    t_fail 'and the result plans for an Alpine target' "$WZP"
fi
has 'keymap set through setup-keymap'   "$WZP" 'firstboot  system-keymap'
has 'timezone through setup-timezone'   "$WZP" 'firstboot  system-timezone'
has 'the network comes up before apk'   "$WZP" 'netup      net-up'
# setup-alpine asks for both of these, and for good reason: the default CDN can
# be far away, and a box with no battery-backed clock boots in 1970, where every
# certificate looks not-yet-valid.
check 'the mirror is recorded'          "$(grep '^REPOS_MIRROR=' "$WZS/modules/repos.conf")" \
                                        'REPOS_MIRROR=https://mirror.ufpr.br/alpine'
has 'and set before any package'        "$WZP" 'bootstrap  repos-mirror'
check 'the ntp client'                  "$(grep '^SYSTEM_NTP=' "$WZS/modules/system.conf")" \
                                        'SYSTEM_NTP=chrony'
has 'time sync through setup-ntp'       "$WZP" 'firstboot  system-ntp'
has 'and the apkovl has a destination'  "$WZP" 'file       /etc/lbu/lbu.conf'
# An existing machine is offered up for replacement rather than refused — but
# only a machine, and only when the answer is yes. Its identity is in there.
WZE=$(mktemp -d /tmp/spore-wizexist.XXXXXX)
printf '%s\n' 'again' 'us us' 'UTC' 'none' 'eth0' 'dhcp' '' 'tester' 'n' '' 'n' |
    "$SPORE" setup "$WZE/m" >/dev/null 2>&1 || true
WZE_ID=$WZE/m/spore/spore.conf
check 'a machine was created' "$([ -f "$WZE_ID" ] && echo yes || echo no)" yes
printf 'MARKER\n' > "$WZE/m/spore/keys/marker"
# Declining leaves it exactly as it was, and says how to change one thing.
printf '%s\n' 'again' 'n' | "$SPORE" setup "$WZE/m" > "$WZE/decline" 2>&1 || true
check 'declining leaves it untouched' \
    "$([ -f "$WZE/m/spore/keys/marker" ] && echo yes || echo no)" yes
has 'and points at editing instead' "$(cat "$WZE/decline")" 'edit the file rather than'
# Accepting replaces it.
printf '%s\n' 'again' 'y' 'us us' 'UTC' 'none' 'eth0' 'dhcp' '' 'tester' 'n' '' 'n' |
    "$SPORE" setup "$WZE/m" >/dev/null 2>&1 || true
check 'accepting replaces it' \
    "$([ -f "$WZE/m/spore/keys/marker" ] && echo stale || echo fresh)" fresh
# A directory that is not a machine is never offered up for deletion.
mkdir -p "$WZE/notamachine"; printf 'important\n' > "$WZE/notamachine/data"
if WZEO=$(printf '%s\n' 'again' 'y' | "$SPORE" setup "$WZE/notamachine" 2>&1); then
    t_fail 'a non-machine directory is never replaced' 'succeeded'
else
    has 'a non-machine directory is never replaced' "$WZEO" 'is not a machine directory'
fi
check 'and its contents survive' \
    "$([ -f "$WZE/notamachine/data" ] && echo yes || echo no)" yes
rm -rf "$WZE"

# A machine belongs on the disk it boots from; the directory is the fallback for
# when there is no disk in your hand, and the answers must survive declining it.
WZH=$(mktemp -d /tmp/spore-wizhome.XXXXXX)
printf '%s\n' 'homehost' 'us us' 'UTC' 'none' 'eth0' 'dhcp' '' \
    'tester' 'n' '' 'n' |
    env HOME="$WZH" SUDO_USER= SPORE_PUBKEY= "$SPORE" setup > "$WZH/out" 2>&1 || true
has 'the disk is offered, not a directory' "$(cat "$WZH/out")" 'Write a USB stick now'
check 'declining still keeps the answers' \
    "$([ -f "$WZH/spores/homehost/spore/spore.conf" ] && echo yes || echo no)" yes
check 'and the identity with them' \
    "$([ -f "$WZH/spores/homehost/identity" ] && echo yes || echo no)" yes
has 'and it says what is left to do' "$(cat "$WZH/out")" 'not on a disk yet'
rm -rf "$WZH"

# A mistyped device path costs a retry, not the answers to fifteen questions.
WZR=$(mktemp -d /tmp/spore-wizretry.XXXXXX)
printf '%s\n' 'retryhost' 'us us' 'UTC' 'none' 'eth0' 'dhcp' '' 'tester' 'n' '' \
    'y' '/dev/definitely-not-here' '' |
    env HOME="$WZR" SUDO_USER= SPORE_PUBKEY= "$SPORE" setup > "$WZR/out" 2>&1 || true
has 'a bad device path is told, not fatal' "$(cat "$WZR/out")" 'is not a block device'
has 'and it asks again'                    "$(cat "$WZR/out")" 'blank to skip'
check 'the answers survive the typo' \
    "$([ -f "$WZR/spores/retryhost/spore/spore.conf" ] && echo yes || echo no)" yes
rm -rf "$WZR" "$WZ"

section 'the mirror is derived on the target, never hardcoded here'
# A spore that baked in v3.20 would quietly install the wrong release on a 3.22
# image, so the branch is read off the machine at apply time.
MR=$(mktemp -d /tmp/spore-mirror.XXXXXX)/s; cp -r "$EX" "$MR"
printf 'REPOS_COMMUNITY=yes\nREPOS_MIRROR=https://mirror.ufpr.br/alpine\n' \
    > "$MR/modules/repos.conf"
MRP=$(alpine "$SPORE" --spore "$MR" plan 2>&1)
has  'the mirror is a bootstrap action'  "$MRP" 'bootstrap  repos-mirror'
has  'alongside enabling community'      "$MRP" 'bootstrap  repos-community'
hasnt 'and no Alpine version is baked in' "$MRP" 'v3.2'
# A mirror that is not a URL is refused rather than written into apk's config.
printf 'REPOS_MIRROR=mirror.ufpr.br\n' > "$MR/modules/repos.conf"
if MRX=$(alpine "$SPORE" --spore "$MR" plan 2>&1); then
    t_fail 'refuses a mirror that is not a URL' 'plan succeeded'
else has 'refuses a mirror that is not a URL' "$MRX" 'http:// or https:// URL'; fi
rm -rf "$MR"

section 'the image boot config is made to match the medium it is on'
# Alpine's grub.cfg finds its root with the ISO9660 volume label — a string with
# spaces, longer than the eleven characters a FAT label can hold. Extracted onto
# a FAT partition it can never match, and grub says "no such device" on every
# single boot.
BPD=$(mktemp -d /tmp/spore-bootpatch.XXXXXX)
cat > "$BPD/grub.cfg" <<'BPCFG'
set timeout=1
search --no-floppy --set=root -l 'alpine-std 3.24.1 x86_64'
menuentry "Linux lts" {
	linux /boot/vmlinuz-lts modules=loop,squashfs,sd-mod,usb-storage quiet
	initrd /boot/initramfs-lts
}
BPCFG
BPOUT=$(awk -v LBL=ALPINE -f "$ROOT/lib/bootpatch.awk" "$BPD/grub.cfg")
has   'the search is pointed at our label' "$BPOUT" 'search --no-floppy --set=root --label ALPINE'
hasnt 'and the ISO label is gone'          "$BPOUT" 'alpine-std'
has   'a serial console is added'          "$BPOUT" 'console=ttyS0,115200'
has   'with tty0 still first'              "$BPOUT" 'console=tty0 console=ttyS0'
has   'the kernel options survive'         "$BPOUT" 'modules=loop,squashfs,sd-mod,usb-storage'
has   'and initrd is untouched'            "$BPOUT" 'initrd /boot/initramfs-lts'
# Running it twice must not stack consoles.
BPTWICE=$(printf '%s\n' "$BPOUT" | awk -v LBL=ALPINE -f "$ROOT/lib/bootpatch.awk")
check 'it is idempotent' \
    "$(printf '%s\n' "$BPTWICE" | grep -c 'console=ttyS0')" 1
rm -rf "$BPD"

section 'spore media refuses a disk it should not erase'
if MOUT=$("$SPORE" media /dev/null /etc/hostname 2>&1); then
    t_fail 'refuses a non-block device' 'succeeded'
else has 'refuses a non-block device' "$MOUT" 'not a block device'; fi
# The device backing / must never be offered up, whatever was typed.
MROOT=$(awk '$2 == "/" { print $1; exit }' /proc/mounts 2>/dev/null)
case $MROOT in
    /dev/*)
        MDISK=$(printf '%s' "$MROOT" | sed 's/p\{0,1\}[0-9]*$//')
        if MRO=$(printf '%s\n' "$MDISK" | "$SPORE" media "$MDISK" /etc/hostname 2>&1); then
            t_fail 'refuses the disk this machine runs from' 'succeeded'
        else
            has 'refuses the disk this machine runs from' "$MRO" 'in use'
        fi ;;
    *) t_skip 'no /dev-backed root here — in-use assertion' ;;
esac

section 'install takes the device, so nobody types mount and umount'
# Three commands by hand is three chances to name the wrong path, and forgetting
# the umount is how a stick gets pulled while the write is still in page cache.
MDEV=$(awk '$1 ~ /^\/dev\// { print $1; exit }' /proc/mounts 2>/dev/null)
DEVB=''
for d in /dev/vdb /dev/vdc /dev/sdb /dev/loop0; do
    [ -b "$d" ] && [ "$d" != "$MDEV" ] && { DEVB=$d; break; }
done
if [ -z "$DEVB" ]; then
    t_skip 'no spare block device here — device-form assertions'
else
    NBD=$(mktemp -d /tmp/spore-devform.XXXXXX)
    printf 'ssh-ed25519 AAAADeviceFormTest t@t\n' > "$NBD/id.pub"
    SPORE_PUBKEY="$NBD/id.pub" USER=tester "$SPORE" new devhost "$NBD/m" >/dev/null 2>&1
    # A device that was never prepared says so, and names the command that would.
    if IOUT=$("$SPORE" install "$NBD/m" "$DEVB" 2>&1); then
        t_fail 'an unprepared device is refused' 'succeeded'
    else
        has 'an unprepared device is refused' "$IOUT" 'not a spore medium yet'
        has 'and names how to make one'       "$IOUT" 'spore media'
    fi
    # Its boot partition is on it; a third argument would be a contradiction.
    if IOUT=$("$SPORE" install "$NBD/m" "$DEVB" /tmp 2>&1); then
        t_fail 'a device plus a boot argument is refused' 'succeeded'
    else has 'a device plus a boot argument is refused' "$IOUT" 'no third argument'; fi
    rm -rf "$NBD"
fi

section 'try: boot it before carrying it anywhere'
# The loop this project went without for too long. A VM cannot speak for the
# target's hardware, but it answers the expensive question — does the seed run,
# and does the spore apply — in seconds instead of a round trip.
if TOUT=$("$SPORE" try 2>&1); then
    t_fail 'try needs something to boot' 'succeeded'
else has 'try needs something to boot' "$TOUT" 'usage: spore try'; fi
if TOUT=$("$SPORE" try /nonexistent-device 2>&1); then
    t_fail 'and it must exist' 'succeeded'
else has 'and it must exist' "$TOUT" 'no such device or image'; fi
if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    t_skip 'qemu is installed here — missing-qemu assertion'
else
    if TOUT=$("$SPORE" try /etc/hostname 2>&1); then
        t_fail 'a missing qemu names its package' 'succeeded'
    else has 'a missing qemu names its package' "$TOUT" 'apt install qemu-system-x86'; fi
fi
# The medium is attached over USB, not virtio: a stick arrives as /dev/sda and a
# virtio disk as /dev/vda, and the boot path scans device names. Rehearsing over
# virtio would exercise a route the hardware never takes.
TSTUB=$(mktemp -d /tmp/spore-trystub.XXXXXX)
printf '#!/bin/sh\nexit 0\n' > "$TSTUB/qemu-system-x86_64"
chmod 755 "$TSTUB/qemu-system-x86_64"
: > "$TSTUB/CODE.fd"; : > "$TSTUB/VARS.fd"
TCMD=$(PATH="$TSTUB:$PATH" SPORE_TRY_PRINT=1 SPORE_OVMF="$TSTUB/CODE.fd:$TSTUB/VARS.fd" \
       "$SPORE" try /etc/hostname 2>/dev/null || true)
has   'the medium is attached over USB' "$TCMD" 'usb-storage'
hasnt 'not as a virtio disk'            "$TCMD" 'if=virtio'
has   'writes go to a snapshot'         "$TCMD" '-snapshot'
has   'and firmware is EFI, not BIOS'   "$TCMD" 'if=pflash'
# A console you can only photograph is a console you cannot paste, which is most
# of why this project spent so long guessing at what the machine was saying the
# whole time.
has   'the boot console is captured'    "$TCMD" '-serial file:'
# An image file has no partitions to take a kernel off, so it falls back to the
# medium's own bootloader — which is also what `bootloader` asks for explicitly.
TCMDB=$(PATH="$TSTUB:$PATH" SPORE_TRY_PRINT=1 SPORE_OVMF="$TSTUB/CODE.fd:$TSTUB/VARS.fd" \
       "$SPORE" try /etc/hostname bootloader 2>/dev/null || true)
hasnt 'bootloader mode boots no kernel directly' "$TCMDB" '-kernel'
if TCMDX=$("$SPORE" try /etc/hostname nonsense 2>&1); then
    t_fail 'an unknown try option is refused' 'succeeded'
else has 'an unknown try option is refused' "$TCMDX" "unknown option 'nonsense'"; fi
# `write` is the deliberate opposite, and must not silently keep the snapshot.
TCMDW=$(PATH="$TSTUB:$PATH" SPORE_TRY_PRINT=1 SPORE_OVMF="$TSTUB/CODE.fd:$TSTUB/VARS.fd" \
       "$SPORE" try /etc/hostname write 2>/dev/null || true)
hasnt 'write really writes'             "$TCMDW" '-snapshot'
rm -rf "$TSTUB"

# An EFI-only medium in a BIOS guest finds nothing bootable and reads as a bad
# stick, so OVMF is required rather than merely preferred.
TFW=$(cd "$ROOT" && sh -c 'SPORE_COLOR=never . ./lib/core.sh; . ./lib/try.sh
    if try_ovmf >/dev/null; then echo found; else echo absent; fi')
case $TFW in
    found|absent) t_ok 'firmware discovery answers either way' ;;
    *)            t_fail 'firmware discovery answers either way' "$TFW" ;;
esac

section 'inspect: read the evidence instead of inferring from symptoms'
# Everything needed after a failed boot is on the data partition, and getting at
# it meant mount, cat, umount by hand — so it did not get looked at.
IN=$(mktemp -d /tmp/spore-inspect.XXXXXX)
printf 'ssh-ed25519 AAAAInspectTest t@t\n' > "$IN/id.pub"
SPORE_PUBKEY="$IN/id.pub" USER=tester "$SPORE" new inspecthost "$IN/m" >/dev/null 2>&1
"$SPORE" seed "$IN/m/spore-seed.apkovl.tar.gz" >/dev/null 2>&1
INO=$("$SPORE" inspect "$IN/m" 2>&1)
has 'it names the host'              "$INO" 'inspecthost'
has 'and whether the identity is there' "$INO" 'identity  present'
# The one fact that distinguishes "the fix did not work" from "the fix never
# reached the machine".
has 'and whether the seed matches this tool' "$INO" 'matches this tool'
has 'it says nothing was ever committed'     "$INO" 'never finished an apply'
has 'and that there is no log to read'       "$INO" 'no spore-seed.log'

# A seed built from a different tool is the difference between a fix that failed
# and a fix that was never installed — which four rounds of this could not tell
# apart.
printf 'tampered\n' >> "$IN/m/spore/spore.conf"
mkdir -p "$IN/fake/usr/local/lib/spore/lib" "$IN/fake/usr/local/lib/spore/bin"
printf 'different\n' > "$IN/fake/usr/local/lib/spore/lib/seed.sh"
(cd "$IN/fake" && tar -czf "$IN/m/spore-seed.apkovl.tar.gz" .)
INS=$("$SPORE" inspect "$IN/m" 2>&1)
has 'a mismatched seed is called out' "$INS" 'built from a different version'

# A log present is printed verbatim — it is the thing being looked for.
printf '=== spore seed ===\nno spore found on any attached filesystem.\n' \
    > "$IN/m/spore-seed.log"
INL=$("$SPORE" inspect "$IN/m" 2>&1)
has 'a log that exists is printed' "$INL" 'no spore found on any attached filesystem'
if INE=$("$SPORE" inspect /nonexistent 2>&1); then
    t_fail 'a missing target is refused' 'succeeded'
else has 'a missing target is refused' "$INE" 'no such device or directory'; fi
rm -rf "$IN"

section 'a device node with no medium is named as such'
# An empty card-reader slot opens fine and reports size 0. sgdisk then fails
# with "Error is 123", which is ENOMEDIUM and tells the reader nothing.
if MEO=$("$SPORE" media /dev/null /etc/hostname 2>&1); then
    t_fail 'a non-block device is still refused first' 'succeeded'
else has 'a non-block device is still refused first' "$MEO" 'not a block device'; fi
# media_has_medium is the check; drive it directly, since a real empty slot
# cannot be conjured here.
MEDCHK=$(cd "$ROOT" && sh -c '
    SPORE_COLOR=never . ./lib/core.sh; . ./lib/media.sh
    if media_has_medium /dev/definitely-not-a-device; then echo permissive; else echo blocked; fi')
check 'an unknowable device is not blocked' "$MEDCHK" permissive
MEDREAL=$(cd "$ROOT" && sh -c '
    SPORE_COLOR=never . ./lib/core.sh; . ./lib/media.sh
    d=$(awk "\$1 ~ /^\/dev\// { print \$1; exit }" /proc/mounts)
    case $d in /dev/*) ;; *) echo skip; exit 0 ;; esac
    if media_has_medium "$d"; then echo present; else echo absent; fi')
case $MEDREAL in
    skip) t_skip 'no /dev-backed mount here — medium-present assertion' ;;
    *)    check 'a device with a medium passes' "$MEDREAL" present ;;
esac

section 'spore new: a machine directory, ready to edit'
NB=$(mktemp -d /tmp/spore-boot.XXXXXX)
printf 'ssh-ed25519 AAAAC3TestKeyForBootstrap tester@workstation\n' > "$NB/id.pub"
NEWOUT=$(SPORE_PUBKEY="$NB/id.pub" USER=tester SUDO_USER='' "$SPORE" new galadriel "$NB/m" 2>&1)
NBS=$NB/m/spore

check 'spore.conf names the host'      "$(grep '^HOST=' "$NBS/spore.conf")" 'HOST=galadriel'
check 'net.conf agrees with it'        "$(grep '^NET_HOSTNAME=' "$NBS/modules/net.conf")" \
                                       'NET_HOSTNAME=galadriel'
# The identity travels beside the spore, not inside it — and the relative path
# is what makes one spore.conf correct both here and on the target.
check 'identity is beside the spore'   "$(grep '^SECRETS_IDENTITY=' "$NBS/spore.conf")" \
                                       'SECRETS_IDENTITY=../identity'
check 'the account is the caller'      "$(grep '^USERS=' "$NBS/modules/users.conf")" 'USERS="tester"'
check 'and may use doas'               "$(grep '^USERS_DOAS=' "$NBS/modules/users.conf")" \
                                       'USERS_DOAS="tester"'
# Without a real key here nothing can reach the machine, so the caller's own is
# installed rather than the example's placeholder left in place.
check 'the caller key is installed' \
    "$(cat "$NBS/keys/tester.authorized_keys" 2>/dev/null)" \
    'ssh-ed25519 AAAAC3TestKeyForBootstrap tester@workstation'
hasnt 'the placeholder key is gone' \
    "$(ls "$NBS/keys")" 'gui.authorized_keys'
has 'it says which key it took'        "$NEWOUT" "key from $NB/id.pub"

if command -v age-keygen >/dev/null 2>&1; then
    check 'an identity is generated'   "$([ -s "$NB/m/identity" ] && echo yes || echo no)" yes
    check 'and is not world-readable'  "$(file_mode "$NB/m/identity")" 600
    check 'with recipients to seal to' \
        "$([ -s "$NBS/secrets/recipients" ] && echo yes || echo no)" yes
else
    t_skip 'age not installed — no keypair assertions'
fi

section 'spore new refuses rather than guesses'
if NOUT=$("$SPORE" new galadriel "$NB/m" 2>&1); then
    t_fail 'refuses an existing directory' "succeeded: $NOUT"
else has 'refuses an existing directory' "$NOUT" 'already exists'; fi
if NOUT=$("$SPORE" new 'bad name' "$NB/x" 2>&1); then
    t_fail 'refuses an unusable hostname' "succeeded: $NOUT"
else has 'refuses an unusable hostname' "$NOUT" 'not a usable hostname'; fi

section 'spore install: checked here, not discovered after it boots'
# A machine with no key is a machine nobody can reach. That has to surface on
# the workstation, where the disk is still in your hand — and it only does if
# the spore is planned the way the target will plan it, since on a workstation
# ssh is skipped for want of OpenRC and never gets to refuse.
NK=$NB/nokey; cp -r "$NB/m" "$NK"; rm -f "$NK/spore/keys"/*.authorized_keys
if IOUT=$("$SPORE" install "$NK" "$NB/m" 2>&1); then
    t_fail 'refuses a spore nothing could log into' "succeeded: $IOUT"
else
    has 'refuses a spore nothing could log into' "$IOUT" 'Nothing could log in'
    has 'and does not install it anyway'         "$IOUT" 'refusing to install'
fi

# Copying onto a directory that is not a mount point fills this machine's disk
# instead of the removable one, and is discovered when the target fails to boot.
mkdir -p "$NB/notmounted"
if IOUT=$("$SPORE" install "$NB/m" "$NB/notmounted" 2>&1); then
    t_fail 'refuses a target that is not mounted' "succeeded: $IOUT"
else has 'refuses a target that is not mounted' "$IOUT" 'is not a mount point'; fi
if IOUT=$("$SPORE" install "$NB/m" "$NB/absent" 2>&1); then
    t_fail 'refuses a target that does not exist' "succeeded: $IOUT"
else has 'refuses a target that does not exist' "$IOUT" 'is the disk mounted?'; fi
if IOUT=$("$SPORE" install "$NB" "$NB/notmounted" 2>&1); then
    t_fail 'refuses a directory that is not a machine' "succeeded: $IOUT"
else has 'refuses a directory that is not a machine' "$IOUT" 'no spore/spore.conf'; fi

section 'spore install: onto a real filesystem'
MP=$NB/disk; mkdir -p "$MP"
if mount -t tmpfs tmpfs "$MP" 2>/dev/null; then MP_MOUNTED=1; else MP_MOUNTED=0; fi
if [ "$MP_MOUNTED" = 0 ]; then
    t_skip 'cannot mount a tmpfs here — install target assertions'
else
    DRY=$("$SPORE" -n install "$NB/m" "$MP" 2>&1)
    has   'dry run says so'            "$DRY" 'dry run'
    check 'and writes nothing'         "$(ls -A "$MP")" ''

    IOUT=$("$SPORE" install "$NB/m" "$MP" 2>&1)
    has   'reports the host installed' "$IOUT" 'galadriel'
    check 'the spore is there'         "$([ -f "$MP/spore/spore.conf" ] && echo yes || echo no)" yes
    if [ -f "$NB/m/identity" ]; then
        check 'the identity travels with it' \
            "$([ -f "$MP/identity" ] && echo yes || echo no)" yes
        check 'and stays unreadable there' "$(file_mode "$MP/identity")" 600
    else
        t_skip 'no identity to install (age not present)'
    fi
    # Built here, from this tool: a copied one silently boots the target on an
    # older spore than the one just edited.
    check 'a seed is built for it' \
        "$([ -s "$MP/spore-seed.apkovl.tar.gz" ] && echo yes || echo no)" yes
    has 'and the seed carries the tool' \
        "$(tar -tzf "$MP/spore-seed.apkovl.tar.gz")" './usr/local/bin/spore'

    # Re-installing must replace the spore, not nest a copy inside it.
    "$SPORE" install "$NB/m" "$MP" >/dev/null 2>&1
    check 'a second install replaces, not nests' \
        "$([ -e "$MP/spore/spore" ] && echo nested || echo clean)" clean

    # A named boot partition gets the same seed. The initramfs has to mount a
    # filesystem before it can find an apkovl on it, and a FAT boot partition is
    # the one it can certainly read.
    BP=$NB/boot; mkdir -p "$BP"
    if mount -t tmpfs tmpfs "$BP" 2>/dev/null; then
        "$SPORE" install "$NB/m" "$MP" "$BP" >/dev/null 2>&1
        check 'the seed also lands on the boot partition' \
            "$([ -s "$BP/spore-seed.apkovl.tar.gz" ] && echo yes || echo no)" yes
        check 'and both copies are the same build' \
            "$(cmp -s "$BP/spore-seed.apkovl.tar.gz" "$MP/spore-seed.apkovl.tar.gz" \
               && echo same || echo differ)" same
        umount "$BP" 2>/dev/null || true
    else
        t_skip 'cannot mount a second tmpfs — boot-partition seed assertions'
    fi
    # An unmounted boot directory is the same mistake as an unmounted target.
    mkdir -p "$NB/notaboot"
    if IOUT=$("$SPORE" install "$NB/m" "$MP" "$NB/notaboot" 2>&1); then
        t_fail 'refuses a boot partition that is not mounted' 'succeeded'
    else has 'refuses a boot partition that is not mounted' "$IOUT" 'not a mount point'; fi
    umount "$MP" 2>/dev/null || true
fi
rm -rf "$NB"

rm -rf "$R" "$R2" "$R3" "$R4" "$R5" "$BD" "$LOG" "$LOG2" "$PLOG" 2>/dev/null || true

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
