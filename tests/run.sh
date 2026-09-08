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
section 'syntax (dash -n, closest POSIX proxy to busybox ash)'
for f in "$ROOT"/bin/spore "$ROOT"/lib/*.sh "$ROOT"/modules/*.sh "$ROOT"/tests/*.sh; do
    if dash -n "$f" 2>/dev/null; then t_ok "parses $(basename "$f")"
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
has  'plans dufs blob'                "$PLAN" 'blob       dufs -> /usr/local/bin/dufs'
has  'plans generated dufs service'   "$PLAN" 'file       /etc/init.d/dufs (0755'
has  'plans sshd in default runlevel' "$PLAN" 'svc        sshd -> default [on]'
has  'plans host keys as firstboot'   "$PLAN" 'firstboot  ssh-hostkeys'
has  'persists blob dest (diskless)'  "$PLAN" 'persist    /usr/local/bin/dufs'
has  'warns firewall not activated'   "$PLAN" 'NOT activated'
hasnt 'carries no private key material' "$PLAN" 'ssh_host_'

# ------------------------------------------------------------- fake root -----
section 'apply into a synthetic root'
R=$(mktemp -d /tmp/spore-test.XXXXXX)
LOG=$(mktemp /tmp/spore-log.XXXXXX)
export SPORE_RUN_LOG="$LOG"
OUT=$(alpine "$SPORE" --spore "$EX" --root "$R" apply 2>&1)
unset SPORE_RUN_LOG

has 'reports changes'        "$OUT" '22 changed, 0 already correct'
check 'authorized_keys is 0600' "$(file_mode "$R/root/.ssh/authorized_keys")" 600
check '.ssh is 0700'            "$(file_mode "$R/root/.ssh")"                 700
check 'init.d/dufs is 0755'     "$(file_mode "$R/etc/init.d/dufs")"           755
check 'conf.d/dufs is 0644'     "$(file_mode "$R/etc/conf.d/dufs")"           644

has 'sshd config carries owned block' "$(cat "$R/etc/ssh/sshd_config")" '# BEGIN spore:sshd'
has 'sshd port set'                   "$(cat "$R/etc/ssh/sshd_config")" 'Port 22'
has 'dufs opts rendered'              "$(cat "$R/etc/conf.d/dufs")"     '--bind 0.0.0.0 --port 5000 /srv/dufs'
has 'dufs uses supervise-daemon'      "$(cat "$R/etc/init.d/dufs")"     'supervisor="supervise-daemon"'
has 'hostname written'                "$(cat "$R/etc/hostname")"        'galadriel'

section 'external commands the executor would have run'
CMDS=$(cat "$LOG")
has 'apk add openssh'          "$CMDS" 'apk add --no-progress openssh'
has 'apk add awall'            "$CMDS" 'apk add --no-progress awall'
has 'rc-update add sshd'       "$CMDS" 'rc-update add sshd default'
has 'rc-update add dufs'       "$CMDS" 'rc-update add dufs default'
has 'blob pinned by sha256'    "$CMDS" '817769f726613194bcff9d0e3e481eaccc86ac11208857614f36a8c02f410977'

section 'firewall policy is generated from other modules ports'
AW=$(cat "$R/etc/awall/optional/spore.json")
has 'opens ssh port'  "$AW" '"spore-tcp-22": { "proto": "tcp", "port": [22] }'
has 'opens dufs port' "$AW" '"spore-tcp-5000": { "proto": "tcp", "port": [5000] }'
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
has   'second apply changes nothing'      "$OUT2" '0 changed, 22 already correct'
check 'second apply runs no commands'     "$(wc -l < "$LOG2" | tr -d ' ')" 0

# -------------------------------------------------------------- dry run -----
section 'dry run'
R2=$(mktemp -d /tmp/spore-dry.XXXXXX)
DRY=$(alpine "$SPORE" --spore "$EX" --root "$R2" --dry-run apply 2>&1)
has   'announces writes'          "$DRY" 'would write file /etc/conf.d/dufs'
has   'announces package install' "$DRY" 'would install package openssh'
check 'writes nothing at all'     "$(find "$R2" -mindepth 1 | wc -l | tr -d ' ')" 0

# --------------------------------------------------------------- status -----
section 'status and diff'
ST=$(alpine "$SPORE" --spore "$EX" --root "$R" status 2>&1)
has 'status clean after apply' "$ST" 'ssh        ok'
printf 'tampered\n' >> "$R/etc/conf.d/dufs"
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
has   'unprivileged LXC: interfaces skipped' "$LXC" 'interfaces and DNS skipped'
check 'unprivileged LXC: no awall policy'  "$([ -f "$R3/etc/awall/optional/spore.json" ] && echo yes || echo no)" no
hasnt 'unprivileged LXC: no diskless warning' "$LXC" 'nothing here survives a reboot'

R4=$(mktemp -d /tmp/spore-noinit.XXXXXX)
NOINIT=$(env SPORE_FACT_INIT=none SPORE_FACT_NETADMIN=no SPORE_FACT_PERSIST=rootfs \
             SPORE_FACT_ARCH=x86_64 SPORE_FACT_ROOT=yes \
             "$SPORE" --spore "$EX" --root "$R4" apply 2>&1)
has 'no OpenRC: ssh n/a'  "$NOINIT" 'ssh: n/a here (no OpenRC)'
has 'no OpenRC: dufs n/a' "$NOINIT" 'dufs: n/a here (no OpenRC)'

section 'arch selects the right blob'
A64=$(env SPORE_FACT_INIT=openrc SPORE_FACT_NETADMIN=yes SPORE_FACT_PERSIST=lbu \
          SPORE_FACT_ARCH=aarch64 SPORE_FACT_ROOT=yes "$SPORE" --spore "$EX" plan 2>&1)
check 'aarch64 plan builds' "$(printf '%s' "$A64" | grep -c 'blob       dufs')" 1

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
    has 'planner refuses conflicting claims' "$CONF" 'claimed by both'
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

# -------------------------------------------------------------- persist -----
section 'persist backends'
PR=$(alpine "$SPORE" --spore "$EX" --root "$R" persist 2>&1)
has 'diskless backend commits to apkovl' "$PR" 'committed to apkovl'
PLOG=$(mktemp /tmp/spore-plog.XXXXXX)
export SPORE_RUN_LOG="$PLOG"
alpine "$SPORE" --spore "$EX" --root "$R" persist >/dev/null 2>&1
unset SPORE_RUN_LOG
has 'includes paths outside /etc' "$(cat "$PLOG")" 'lbu include /usr/local/bin/dufs'
has 'runs lbu commit'             "$(cat "$PLOG")" 'lbu commit'
hasnt 'does not include /etc (already in overlay)' "$(cat "$PLOG")" 'lbu include /etc'

PR2=$(env SPORE_FACT_INIT=openrc SPORE_FACT_NETADMIN=no SPORE_FACT_PERSIST=rootfs \
          SPORE_FACT_ARCH=x86_64 SPORE_FACT_ROOT=yes \
          "$SPORE" --spore "$EX" --root "$R3" persist 2>&1)
has 'rootfs backend exports the spore' "$PR2" 'nothing to commit'
check 'exported spore is readable' "$([ -f "$R3/var/lib/spore/spore/spore.conf" ] && echo yes || echo no)" yes

rm -rf "$R" "$R2" "$R3" "$R4" "$R5" "$BD" "$LOG" "$LOG2" "$PLOG" 2>/dev/null || true

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
