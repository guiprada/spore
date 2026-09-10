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

# A spore that names no destination, on a host that names none either, is the
# case that must not plan quietly.
printf 'APKOVL_BACKUPDIR=\n' > "$AV/modules/apkovl.conf"
if AVN=$(alpine "$SPORE" --spore "$AV" plan 2>&1); then
    t_fail 'refuses to commit into the void' 'plan succeeded'
else
    has 'refuses to commit into the void' "$AVN" 'converges on every boot and keeps'
fi
# ...but a host already configured by hand is deferred to, not overridden.
SPORE_FACT_LBU_DEST=/media/data
AVH=$(alpine "$SPORE" --spore "$AV" plan 2>&1)
has 'a hand-configured host is kept' "$AVH" "kept (/media/data)"
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

section 'external commands the executor would have run'
CMDS=$(cat "$LOG")
has 'apk add openssh'          "$CMDS" 'apk add --no-progress openssh'
has 'apk add awall'            "$CMDS" 'apk add --no-progress awall'
has 'rc-update add sshd'       "$CMDS" 'rc-update add sshd default'
has 'rc-update add dufs'       "$CMDS" 'rc-update add dufs default'
has 'apk add dufs'             "$CMDS" 'apk add --no-progress dufs'
has 'apk add libcap for :443'  "$CMDS" 'apk add --no-progress libcap'

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
has 'carries the first-boot hook'  "$SEEDLIST" 'etc/local.d/spore.start'
has 'enables the local service'    "$SEEDLIST" 'etc/runlevels/default/local'
has 'carries the tool'             "$SEEDLIST" 'usr/local/bin/spore'
has 'keeps /usr/local across lbu'  "$SEEDLIST" 'etc/apk/protected_paths.d/spore.list'
# The point of the rework: no configuration inside the overlay.
hasnt 'carries no spore'           "$SEEDLIST" 'etc/spore/spore'
hasnt 'bakes no repository list'   "$SEEDLIST" 'etc/apk/repositories'

# The initramfs restores whatever ownership the archive records, and the overlay
# is normally built by an ordinary user on a workstation.
SEEDOWN=$(tar -tvzf "$SEEDF" | awk '{ print $2 }' | sort -u | tr '\n' ' ')
check 'everything is owned by root' "$SEEDOWN" '0/0 '

SEEDSTART=$(tar -xzOf "$SEEDF" ./etc/local.d/spore.start)
has 'hook discovers a spore on media' "$SEEDSTART" '/media/*/spore'
has 'hook scans block devices too'    "$SEEDSTART" '/dev/sd'
has 'hook applies and persists'       "$SEEDSTART" 'apply --persist'
has 'hook is idempotent'              "$SEEDSTART" '/etc/spore/.seeded'
has 'hook retries after failure'      "$SEEDSTART" 'will retry on next boot'
has 'hook says what is missing'       "$SEEDSTART" 'no spore found'

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
    umount "$MP" 2>/dev/null || true
fi
rm -rf "$NB"

rm -rf "$R" "$R2" "$R3" "$R4" "$R5" "$BD" "$LOG" "$LOG2" "$PLOG" 2>/dev/null || true

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
