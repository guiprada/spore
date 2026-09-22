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
conf_read()  { ( . "$ROOT/lib/core.sh"; . "$ROOT/lib/conf.sh"; conf_get "$1" "$2" '' ); }


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

section 'the bootstrap seed steps aside so lbu can commit'
# lbu will not write into a directory holding an apkovl it did not write —
# "Please use -d to replace" — and it is right to: two apkovls on one
# filesystem means the initramfs boots whichever it happens to find first. The
# one it finds is ours, put there by `spore install` so a blank Alpine could
# find the spore at all. Its job ends at the first successful commit.
SD2=$(mktemp -d /tmp/spore-seedaside.XXXXXX)
mkdir -p "$SD2/media/data"
printf 'not really an apkovl\n' > "$SD2/media/data/spore-seed.apkovl.tar.gz"
# And one left by the earlier attempt that renamed inside lbu's glob.
printf 'older\n' > "$SD2/media/data/spore-seed.apkovl.tar.gz.superseded"
SD2LOG=$SD2/cmds
export SPORE_FACT_LBU_DEST=/media/data SPORE_RUN_LOG="$SD2LOG"
alpine "$SPORE" --spore "$EX" --root "$SD2" persist > "$SD2/out" 2>&1 || true
unset SPORE_FACT_LBU_DEST SPORE_RUN_LOG
has   'it is set aside, and said so'  "$(cat "$SD2/out")" 'set the bootstrap seed aside'
# The stretch between "N changed" and the commit had nothing in it, so a boot
# that stopped anywhere in here looked exactly like one that stopped at the
# counts. Each step names itself now.
has   'and announced before it happens' "$(cat "$SD2/out")" '> setting the bootstrap seed aside'
has   'as is deciding what to keep'     "$(cat "$SD2/out")" '> recording what to keep'
# lbu's glob is `*.apkovl.tar.gz*`, with a trailing star for the encrypted
# variants. Renaming to `.apkovl.tar.gz.superseded` still matched it, and lbu
# still refused — the new name has to leave that glob, not merely differ.
SD2LEFT=$(cd "$SD2/media/data" && ls -1 ./*.apkovl.tar.gz* 2>/dev/null | tr '\n' ' ')
check 'nothing lbu globs is left behind' "${SD2LEFT:-none}" none
check 'the apkovl name is gone' \
    "$([ -e "$SD2/media/data/spore-seed.apkovl.tar.gz" ] && echo yes || echo no)" no
# Renamed, not deleted: `lbu commit -d` would remove every apkovl in the
# directory, and if the boot partition could not be mounted at install time
# that is the only copy of the seed on the medium.
check 'but the file is kept' \
    "$([ -f "$SD2/media/data/spore-seed.superseded.tar.gz" ] && echo yes || echo no)" yes
# One destination per source. The glob also catches the encrypted variants, and
# moving every match onto a single name kept only whichever went last.
check 'and so is the other variant' \
    "$(cat "$SD2/media/data/spore-seed.superseded.tar.gz.superseded" 2>/dev/null)" older
check 'each under its own name' \
    "$(cat "$SD2/media/data/spore-seed.superseded.tar.gz" 2>/dev/null)" 'not really an apkovl'
has   'and each rename is named as it happens' "$(cat "$SD2/out")" '> renaming spore-seed.apkovl.tar.gz'
has   'and lbu is still asked to commit' "$(cat "$SD2LOG")" 'lbu commit'
hasnt 'but never with -d'               "$(cat "$SD2LOG")" 'lbu commit -d'
rm -rf "$SD2"

# The rename asked the console a question nobody could see, and waited for the
# answer until the machine was switched off. busybox coreutils/mv.c:
#
#     if (dest_exists) {
#         if (!(flags & OPT_FORCE)
#          && ((access(dest, W_OK) < 0 && isatty(0)) || (flags & OPT_INTERACTIVE))
#         ) {
#             fprintf(stderr, "mv: overwrite '%s'? ", dest);
#             if (!bb_ask_y_confirmation()) goto RET_0;
#
# access() reports EROFS on a read-only filesystem even to root; stdin at boot
# is the console; and the question went to a stderr this code was sending to
# /dev/null. All three had to hold, and on the second boot after an install they
# did. Note what the EOF branch does — RET_0, success, nothing moved — so
# closing stdin alone would have traded a hang for a silent no-op.
PSRC=$(cat "$ROOT/lib/persist.sh")
has   'the seed rename never asks'        "$PSRC" 'mv -f "$pcs_f" "$pcs_keep" < /dev/null'
hasnt 'and its errors reach the console'  "$PSRC" 'mv -f "$pcs_f" "$pcs_keep" 2>/dev/null'
has   'and it is bounded like the rest'   "$PSRC" 'persist_bounded 60 mv -f'
SEEDSRC=$(cat "$ROOT/lib/seed.sh")
has   'and the whole boot run has no keyboard to ask' \
    "$SEEDSRC" '} < /dev/null 2>&1 |'

# On the machine it is not that simple: the medium is mounted read-only until
# lbu remounts it, and lbu does that inside `lbu commit` — after this runs. So
# the move fails with EROFS, which a writable temp directory never shows.
SD3=/tmp/spore-roseed.$$
mkdir -p "$SD3"
if [ "$(id -u)" = 0 ] && mount -t tmpfs tmpfs "$SD3" 2>/dev/null; then
    printf 'seed\n' > "$SD3/spore-seed.apkovl.tar.gz"
    # And a destination already there, from the last boot that got this far.
    # That is the combination that hung: read-only filesystem, existing
    # destination, a console at stdin.
    printf 'from an earlier boot\n' > "$SD3/spore-seed.superseded.tar.gz"
    if mount -o remount,ro "$SD3" 2>/dev/null; then
        SD3O=$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/conf.sh"; . "$ROOT/lib/facts.sh"
                . "$ROOT/lib/persist.sh"
                SPORE_ROOT=/; SPORE_DRYRUN=0
                mutate() { return 0; }
                persist_clear_seed "$SD3" 2>&1 )
        has   'a read-only medium is remounted for it' "$SD3O" 'set the bootstrap seed aside'
        check 'and the seed is really renamed' \
            "$(cat "$SD3/spore-seed.superseded.tar.gz" 2>/dev/null)" seed
        SD3LEFT=$(cd "$SD3" && ls -1 ./*.apkovl.tar.gz* 2>/dev/null | tr '\n' ' ')
        check 'with nothing lbu globs left' "${SD3LEFT:-none}" none
        # A remount touches the device, so it can wait on one — and it says
        # nothing while it works.
        has 'each remount is announced'   "$SD3O" '> remounting'
        PSRC3=$(cat "$ROOT/lib/persist.sh")
        has 'and bounded'                 "$PSRC3" 'timeout "$pb_t" "$@"'
        # Read-write first, then the rename — not the rename first and a remount
        # only if it failed. That ordering is the fix: on a writable filesystem
        # there is no unwritable destination, so there is nothing for mv to ask
        # about in the first place.
        SD3RW=$(printf '%s\n' "$SD3O" | grep -n 'remounting.*read-write' | head -1 | cut -d: -f1)
        SD3MV=$(printf '%s\n' "$SD3O" | grep -n '> renaming'            | head -1 | cut -d: -f1)
        if [ -n "$SD3RW" ] && [ -n "$SD3MV" ] && [ "$SD3RW" -lt "$SD3MV" ]; then
            t_ok 'and the remount comes before the rename, not after it fails'
        else
            t_fail 'and the remount comes before the rename, not after it fails' \
                "rw [$SD3RW], rename [$SD3MV]"
        fi
        # Put back read-only, or the next power cut corrupts a USB stick.
        check 'and the medium is read-only again' \
            "$(awk -v d="$SD3" '$2 == d { print $4; exit }' /proc/mounts |
               cut -d, -f1)" ro
    else
        printf '  (could not remount ro here — the EROFS path was not exercised)\n'
    fi
    umount "$SD3" 2>/dev/null || true
else
    printf '  (no root or no tmpfs here — the EROFS path was not exercised)\n'
fi
rmdir "$SD3" 2>/dev/null || true

section 'lbu only remounts for a medium, so the destination has to be one'
# lbu's commit:
#     mnt="$LBU_BACKUPDIR"
#     if [ -z "$mnt" ]; then
#         mnt=/media/$media
#         mount_once_rw "$mnt" || die "failed to mount $mnt"
#     fi
# LBU_BACKUPDIR takes the early path and nothing remounts, so on a read-only
# boot medium the commit dies at `cp: can't create '…/x.apkovl.tar.gz.new':
# Read-only file system` with the destination perfectly correct.
LM=$(mktemp -d /tmp/spore-lbumedia.XXXXXX)/s; cp -r "$EX" "$LM"
printf 'FORMAT=1\nHOST=k\nMODULES="apkovl"\n' > "$LM/spore.conf"
lm_conf() {
    printf 'APKOVL_BACKUPDIR=%s\n' "$1" > "$LM/modules/apkovl.conf"
    LMR=$(mktemp -d /tmp/spore-lbur.XXXXXX)
    env SPORE_FACT_INIT=openrc SPORE_FACT_NETADMIN=yes SPORE_FACT_PERSIST=lbu \
        SPORE_FACT_ARCH=x86_64 SPORE_FACT_ROOT=yes SPORE_FACT_ALPINE=3.20.0 \
        SPORE_FACT_BOOT_MEDIA=yes \
        "$SPORE" --spore "$LM" --root "$LMR" apply >/dev/null 2>&1 || true
    grep -E '^LBU_' "$LMR/etc/lbu/lbu.conf" 2>/dev/null | tr -d '\n'
    rm -rf "$LMR"
}
check 'a plain /media path becomes a medium' "$(lm_conf /media/sda2)" 'LBU_MEDIA=sda2'
# The ones it cannot express stay a backup directory, and persist remounts for
# those itself.
check 'a subdirectory stays a directory'     "$(lm_conf /media/storage/data)" \
      'LBU_BACKUPDIR=/media/storage/data'
check 'and so does somewhere else entirely'  "$(lm_conf /srv/backups)" \
      'LBU_BACKUPDIR=/srv/backups'
rm -rf "$LM"

# /proc/mounts lists mount points, not paths. Looking up /media/storage/data
# finds nothing and concludes it is writable — and a subdirectory of a
# read-only medium is the one case where the answer matters.
PMO=$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/conf.sh"; . "$ROOT/lib/persist.sh"
       persist_mount_of /proc/self/fd )
check 'the enclosing mount is found, not the path' "$PMO" /proc
PMO2=$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/conf.sh"; . "$ROOT/lib/persist.sh"
        persist_mount_of /definitely/not/mounted/anywhere )
check 'and an unmounted path lands on /' "$PMO2" /

# Nothing in a boot may run for ever. Every script action already had a
# deadline; the commit did not, and it is the likeliest thing here to stop
# returning — it tars /etc onto a USB stick and prints nothing while it does,
# so working and wedged look identical from the console.
PSRC2=$(cat "$ROOT/lib/persist.sh")
has 'the commit has a deadline'       "$PSRC2" 'SPORE_COMMIT_TIMEOUT'
has 'and a timeout is told apart'     "$PSRC2" '[ "$pc_rc" = 124 ]'
has 'from a plain failure'            "$PSRC2" 'lbu commit failed (status'
# And it still honours dry-run and the synthetic root, or the suite would
# start running lbu against this workstation.
PTRY=$(mktemp -d /tmp/spore-ptry.XXXXXX)
PTRYO=$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/conf.sh"; . "$ROOT/lib/persist.sh"
         SPORE_DRYRUN=1; SPORE_ROOT=$PTRY; SPORE_RUN_LOG=''
         persist_try lbu commit 2>&1 )
has 'a dry run only says what it would do' "$PTRYO" 'would run: lbu commit'
rm -rf "$PTRY"

section 'the hostname is set on the kernel, not only in a file'
# Nothing rereads /etc/hostname until the next boot, and lbu asks the kernel:
# it names its overlay $(hostname).apkovl.tar.gz. A machine that has not been
# told its own name commits as localhost.apkovl.tar.gz, then as its real name
# next boot — and lbu refuses the second, because now there are two.
NHP=$(alpine "$SPORE" --spore "$EX" plan 2>&1)
has 'the running hostname is set too' "$NHP" 'firstboot  net-hostname'
NHR=$(mktemp -d /tmp/spore-nhost.XXXXXX)
NHW=$(mktemp -d /tmp/spore-nhostw.XXXXXX)
env SPORE_WORK="$NHW" SPORE_WORK_OWNED=0 SPORE_FACT_INIT=openrc \
    SPORE_FACT_NETADMIN=yes SPORE_FACT_PERSIST=lbu SPORE_FACT_ARCH=x86_64 \
    SPORE_FACT_ROOT=yes SPORE_FACT_ALPINE=3.20.0 \
    "$SPORE" --spore "$EX" --root "$NHR" plan >/dev/null 2>&1 || true
NHSHA=$(awk -F'\t' '$2=="firstboot" && $3=="net-hostname"{print $4}' "$NHW/plan.tsv" 2>/dev/null | head -1)
if [ -n "${NHSHA:-}" ] && [ -f "$NHW/content/$NHSHA" ]; then
    has 'it asks the kernel for the name'  "$(cat "$NHW/content/$NHSHA")" 'hostname 2>/dev/null'
    has 'and does nothing when it matches' "$(cat "$NHW/content/$NHSHA")" 'exit 0'
else
    t_fail 'the hostname action is planned' 'no net-hostname action'
fi
rm -rf "$NHR" "$NHW"

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
RP_LASTSH=$(grep -nE '^(timeout [0-9]+ )?sh ' "$RPLOG" | tail -1 | cut -d: -f1)
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
    has 'and the refusal names the fix' "$RPN" 'passwd root'
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
# ifup, not `rc-service networking`: asking OpenRC for the service drags in its
# dependency graph, which wants fsck, which will not start that early — and the
# whole thing dies as "cannot start networking as fsck would not start", three
# layers from the cause.
NETSRC=$(cat "$ROOT/modules/net.sh")
has 'brought up with ifup'          "$NETSRC" 'ifup -a'
has 'and the service is a fallback' "$NETSRC" 'elif [ -x /etc/init.d/networking ]'
has 'no card is not the end of the run' "$NETSRC" 'The rest of the spore still applies'
# "DNS: transient error" is the same message for no address, no route, a dead
# gateway and no resolver. The log has to say which.
has 'and it reports what it got'       "$NETSRC" 'render_net_report'
NRSH=$(mktemp /tmp/spore-netrep.XXXXXX)
{ echo 'iface=lo'; ( . "$ROOT/lib/render.sh"; render_net_report 1 ); } > "$NRSH"
NRO=$(sh "$NRSH" 2>&1)
has 'the default route is always spoken to' "$NRO" 'default route'
# A gateway that ignores ping is not a gateway that is down. One run downloaded
# 28673 packages through a gateway this called dead.
NRSRC2=$(cat "$ROOT/lib/render.sh")
hasnt 'a silent gateway is not called dead' "$NRSRC2" 'nothing leaves this'
has   'it is called what it is'             "$NRSRC2" 'just ICMP being filtered'
has 'and the resolver situation too'        "$NRO" 'resolv'
# A report that cannot tell "no address" from "no tool to ask with" is worse
# than no report, because it is believed.
NRSRC=$(cat "$ROOT/lib/render.sh")
has 'missing tools are said, not guessed'  "$NRSRC" 'no ip or ifconfig here'
has 'the route needs no ip(1) at all'      "$NRSRC" '/proc/net/route'
rm -f "$NRSH"
# Three different things go wrong at an interface name and from a distance they
# look identical. The name can be wrong — predictable naming gives eth0 on one
# box and enp3s0 on the next. It can be right and not there yet, because the
# driver probes asynchronously and a USB-booted box wins the race. Or there can
# be no driver at all because the modloop never mounted, which is a completely
# different repair and worth one line to tell apart.
IFSRC=$(cat "$ROOT/lib/render.sh")
has 'drivers are asked for first'    "$IFSRC" 'udevadm trigger --subsystem-match=net'
has 'then coldplugged by modalias'   "$IFSRC" 'modprobe -b -q --'
# Network cards only. This once walked every modalias under /sys/devices and
# loaded a driver for each — every driver for every device on the box, at once,
# from a tool that wanted one ethernet port.
has 'coldplug is network cards only' "$IFSRC" '# PCI class 0x02xxxx is "network controller"'
hasnt 'not every device on the box'  "$IFSRC" 'find /sys/devices -name modalias'
# And nothing here may block for ever: a boot that hangs writes no log, which
# leaves a power switch and a guess.
has 'blocking calls have a deadline' "$IFSRC" 'spore_bounded'
has 'modprobe among them'            "$IFSRC" 'spore_bounded 10 modprobe'
has 'and the modloop mount'          "$IFSRC" 'spore_bounded 60 rc-service modloop start'
has 'and ifup, which waits on dhcp'  "$NETSRC" 'spore_bounded 90 ifup -a'
has 'and it waits for one to appear' "$IFSRC" 'waiting up to'
has 'a missing interface is named'   "$IFSRC" 'this machine has no interface named'
has 'along with the ones it has'     "$IFSRC" '/sys/class/net/'
has 'and eth0 wins when it is there' "$IFSRC" '[ -e /sys/class/net/eth0 ]'
has 'the modloop is checked'         "$IFSRC" 'spore_modules_here'
has 'and mounted if it is not'       "$IFSRC" 'rc-service modloop start'
# No card at all is a different repair from the wrong name, and the log is the
# only place anyone will ever see the difference.
has 'no card at all names the reason' "$IFSRC" 'the modloop did not'
has 'with the kernel command line'    "$IFSRC" 'cmdline:'
has 'and the card that wants a driver' "$IFSRC" 'network controller'
# Run the thing, where there is a card to find. "Does it resolve" is the test;
# "does the source contain a string" is not.
if [ -e /sys/class/net/eth0 ]; then IFREAL=eth0; else
    IFREAL=$(for i in /sys/class/net/*; do
        n=${i##*/}; [ "$n" = lo ] || printf '%s\n' "$n"
    done | head -1)
fi
if [ -n "$IFREAL" ]; then
    IFSH=$(mktemp /tmp/spore-ifr.XXXXXX)
    ( . "$ROOT/lib/render.sh"; render_iface_resolve auto ) > "$IFSH"
    printf 'printf "RESOLVED=%%s\\n" "$iface"\n' >> "$IFSH"
    IFO=$(sh "$IFSH" 2>&1)
    has 'auto resolves to a real card'     "$IFO" "RESOLVED=$IFREAL"
    has 'and says which one it took'       "$IFO" "using interface $IFREAL"
    has 'and lists what it saw'            "$IFO" 'interfaces present after'
    ( . "$ROOT/lib/render.sh"; render_iface_resolve nosuch0 'NET_IFACE' 2 ) > "$IFSH"
    printf 'printf "RESOLVED=%%s\\n" "$iface"\n' >> "$IFSH"
    IFO2=$(sh "$IFSH" 2>&1)
    has   'a name that is not there waits' "$IFO2" 'waiting up to 2s'
    has   'then says so, with real names'  "$IFO2" "no interface named 'nosuch0'"
    hasnt 'without inventing one'          "$IFO2" "RESOLVED=$IFREAL"
    # Cards here, just not that one: the hardware is fine and the spore is
    # wrong, so the report says that and nothing about modloops.
    has   'and blames the name, not the box' "$IFO2" 'The name is wrong, not the hardware'
    hasnt 'without a word about drivers'     "$IFO2" 'the modloop did not'
    rm -f "$IFSH"
else
    printf '  (no network card on this host — resolver checked by source only)\n'
fi
NA=$(mktemp -d /tmp/spore-netauto.XXXXXX)/s; cp -r "$EX" "$NA"
printf 'NET_HOSTNAME=h\nNET_IFACE=auto\nNET_MODE=dhcp\n' > "$NA/modules/net.conf"
NAP=$(alpine "$SPORE" --spore "$NA" plan 2>&1)
has   'auto is resolved on the machine'  "$NAP" 'NET_IFACE=auto'
has   'and still brought up first'       "$NAP" 'netup      net-up'
# A file whose content depends on hardware this planner has never seen would
# report drift for ever, so auto does not claim to own one.
hasnt 'without claiming to own the file' "$NAP" 'file       /etc/network/interfaces'
# A named interface is a fact, so that file is written and compared as usual.
printf 'NET_HOSTNAME=h\nNET_IFACE=enp3s0\nNET_MODE=dhcp\n' > "$NA/modules/net.conf"
NAN=$(alpine "$SPORE" --spore "$NA" plan 2>&1)
has 'a named interface still owns it'    "$NAN" 'file       /etc/network/interfaces'
NAR=$(mktemp -d /tmp/spore-netautoroot.XXXXXX)
alpine "$SPORE" --spore "$NA" --root "$NAR" apply >/dev/null 2>&1
has 'and carries the name given'         "$(cat "$NAR/etc/network/interfaces")" 'auto enp3s0'
rm -rf "$NA" "$NAR"
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
FIRST_SH=$(grep -nE '^(timeout [0-9]+ )?sh ' "$LOG" | head -1 | cut -d: -f1)
if [ -n "$FIRST_SH" ] && [ -n "$FIRST_APK" ] && [ "$FIRST_SH" -lt "$FIRST_APK" ]; then
    t_ok 'bootstrap scripts run before any apk add'
else
    t_fail 'bootstrap scripts run before any apk add' "first sh=$FIRST_SH first apk=$FIRST_APK"
fi

# Services start last. The accounts they run as, the capabilities they need and
# the volumes they serve are all firstboot work; starting first fails in ways
# that look like the service itself is broken.
LAST_SH=$(grep -nE '^(timeout [0-9]+ )?sh ' "$LOG" | tail -1 | cut -d: -f1)
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
# A zone naming an interface the machine does not have matches nothing: the drop
# rule never applies, the catch-all accept does, and the box reports a firewall
# it does not have. So the interface follows net rather than being typed twice,
# and `auto` is settled on the machine like it is there.
FA=$(mktemp -d /tmp/spore-fwauto.XXXXXX)/s; cp -r "$EX" "$FA"
printf 'NET_HOSTNAME=h\nNET_IFACE=enp3s0\nNET_MODE=dhcp\n' > "$FA/modules/net.conf"
: > "$FA/modules/firewall.conf"
FAR=$(mktemp -d /tmp/spore-fwroot.XXXXXX)
alpine "$SPORE" --spore "$FA" --root "$FAR" apply >/dev/null 2>&1
has 'firewall follows the net interface' \
    "$(cat "$FAR/etc/awall/optional/spore.json")" '"spore_if": "enp3s0"'
printf 'NET_HOSTNAME=h\nNET_IFACE=auto\nNET_MODE=dhcp\n' > "$FA/modules/net.conf"
FAA=$(alpine "$SPORE" --spore "$FA" plan 2>&1)
hasnt 'auto does not own the policy'     "$FAA" 'file       /etc/awall/optional/spore.json'
has   'it is written on the machine'     "$FAA" 'firewall: FW_IFACE=auto'
rm -rf "$FA" "$FAR"

# ---------------------------------------------------------- idempotence -----
section 'age travels on the medium, so a sealed password needs no network'
# The whole run can get everything else right and still end at "age (no such
# package)", which leaves no password on any account. The workstation building
# the medium has a network by definition; the machine booting it may not.
AGSRC=$(cat "$ROOT/lib/plan.sh")
has 'the medium is looked at first'   "$AGSRC" '/media/*/spore-bin/age'
has 'and the package is the fallback' "$AGSRC" 'apk add --no-progress age'
has 'a copied binary is run once'     "$AGSRC" 'age --version'
# 3.24.1 is v3.24; edge stays edge. Guessing this wrong fetches a binary built
# against a different musl and it fails on the target, one boot away from here.
AGB=$( . "$ROOT/lib/apkfetch.sh"; apk_branch 3.24.1; printf ' '; apk_branch 3.20.7
       printf ' '; apk_branch 3.24.0_alpha20260101 )
check 'the branch comes off the release' "$AGB" 'v3.24 v3.20 edge'
# Run the emitted shell against a fake medium carrying a binary, and confirm it
# is preferred over any package manager.
AGR=$(mktemp -d /tmp/spore-agebin.XXXXXX)
mkdir -p "$AGR/media/sdz1/spore-bin" "$AGR/usr/local/bin"
printf '#!/bin/sh\ncase $1 in --version) echo 1.2.3 ;; esac\n' > "$AGR/media/sdz1/spore-bin/age"
chmod 755 "$AGR/media/sdz1/spore-bin/age"
# Out of a real plan, not by hand-wiring the planner: the script that ships is
# the one worth running.
AGD=$(mktemp -d /tmp/spore-ageplan.XXXXXX)
AGS=$AGD/s; cp -r "$EX" "$AGS"; mkdir -p "$AGS/secrets"
AGW=$(mktemp -d /tmp/spore-agework.XXXXXX)
if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
    age-keygen -o "$AGD/identity" 2>"$AGD/pub"
    grep -o 'age1[a-z0-9]*' "$AGD/pub" > "$AGS/secrets/recipients"
    sed -i "s|^SECRETS_IDENTITY=.*|SECRETS_IDENTITY=$AGD/identity|" "$AGS/spore.conf"
    # A secret a module actually consumes: an unused one plans no secret
    # action, so nothing would ask for age at all.
    printf 'x' | "$SPORE" --spore "$AGS" seal root.password >/dev/null 2>&1 || true
fi
if [ -f "$AGS/secrets/root.password.age" ]; then
    env SPORE_WORK="$AGW" SPORE_WORK_OWNED=0 SPORE_FACT_INIT=openrc \
        SPORE_FACT_NETADMIN=yes SPORE_FACT_PERSIST=lbu SPORE_FACT_ARCH=x86_64 \
        SPORE_FACT_ROOT=yes SPORE_FACT_ALPINE=3.20.0 \
        "$SPORE" --spore "$AGS" plan >/dev/null 2>&1 || true
    AGSHA=$(awk -F'\t' '$2=="bootstrap" && $3=="age-available"{print $4}' \
            "$AGW/plan.tsv" 2>/dev/null | head -1)
    if [ -n "${AGSHA:-}" ] && [ -f "$AGW/content/$AGSHA" ]; then
        sed "s|/media/\*|$AGR/media/*|g; s|/mnt/\*|$AGR/mnt/*|g; s|/usr/local/bin|$AGR/usr/local/bin|g" \
            "$AGW/content/$AGSHA" > "$AGW/run.sh"
        # A PATH with no age on it, or the script rightly exits at its first
        # line and proves nothing. Just enough utilities for it to work with.
        mkdir -p "$AGR/shim"
        for AGU in mkdir cp chmod rm; do
            AGP=$(command -v "$AGU") && ln -sf "$AGP" "$AGR/shim/$AGU"
        done
        AGSH=$(command -v sh)
        AGO=$(PATH="$AGR/usr/local/bin:$AGR/shim" "$AGSH" "$AGW/run.sh" 2>&1 || true)
        has   'a carried binary is used'     "$AGO" 'using the age carried on the boot medium'
        check 'and put where it will run'    "$([ -x "$AGR/usr/local/bin/age" ] && echo yes || echo no)" yes
    else
        t_fail 'the age bootstrap action is planned' 'no age-available action in the plan'
    fi
else
    printf '  (no age here — the carried-binary script was not run)\n'
fi
rm -rf "$AGR" "$AGW" "$AGD"
# A mirror that answers with an error page must not leave that on the medium as
# a "binary" — it would fail on the target, one boot and a day away from here.
AGE2=$(mktemp -d /tmp/spore-agebad.XXXXXX)
printf '<html>not found</html>\n' > "$AGE2/notelf"
AGELF=$(head -c 4 "$AGE2/notelf" | od -An -tx1 | tr -d ' \n')
check 'an html error page is not an ELF' "$([ "$AGELF" = 7f454c46 ] && echo elf || echo no)" no
rm -rf "$AGE2"
# And carrying it is never fatal: a medium without it is exactly as good as
# every medium was before this existed.
BSSRC=$(cat "$ROOT/lib/bootstrap.sh")
has 'a failed fetch only warns'       "$BSSRC" 'could not fetch age for'
has 'and only when something is sealed' "$BSSRC" "-name '*.age'"

section 'options are read wherever they are written'
# `spore -s DIR apply --persist` is exactly what the seed runs. The option loop
# stopped at the first word that was not an option, so the command was taken and
# --persist was left unread, silently. The machine converged perfectly,
# persisted nothing, and reported success for both — for a week.
OPT=$(mktemp -d /tmp/spore-opt.XXXXXX)/s; cp -r "$EX" "$OPT"
OPTR=$(mktemp -d /tmp/spore-optr.XXXXXX)
OPTO=$(alpine "$SPORE" -s "$OPT" --root "$OPTR" apply --persist 2>&1 || true)
has   'an option after the command is read'  "$OPTO" 'committed to apkovl'
hasnt 'and the run does not claim otherwise' "$OPTO" 'nothing here survives a reboot'
# Without it the warning is the correct answer, so the two are really distinct.
OPTR2=$(mktemp -d /tmp/spore-optr2.XXXXXX)
OPTO2=$(alpine "$SPORE" -s "$OPT" --root "$OPTR2" apply 2>&1 || true)
has 'and without it, it is still warned about' "$OPTO2" 'nothing here survives a reboot'
# A word the command cannot use is nearly always a misspelled option, and doing
# three-quarters of what was asked while reporting success is how this hid.
if OPTE=$(alpine "$SPORE" -s "$OPT" plan --persst 2>&1); then
    t_fail 'a misspelled option is refused' 'accepted'
else has 'a misspelled option is refused' "$OPTE" 'unknown option: --persst'; fi
if OPTE2=$(alpine "$SPORE" -s "$OPT" plan wat 2>&1); then
    t_fail 'a stray word is refused' 'accepted'
else has 'a stray word is refused' "$OPTE2" 'takes no arguments'; fi
# Positionals keep their order and their meaning wherever the options sit.
OPTE3=$(alpine "$SPORE" install 2>&1 || true)
has 'a command still gets its arguments' "$OPTE3" 'usage: spore install DIR DATA'
rm -rf "$OPT" "$OPTR" "$OPTR2"

section 'a slow action says what it is before it is slow'
# Every other line reports something finished, so while a slow action runs the
# last line names the one before it — and "is this working or has it hung?"
# has no answer. Only the ones that can take real time: announcing a symlink
# would bury the ones that matter.
PG=$(mktemp -d /tmp/spore-prog.XXXXXX)/s; cp -r "$EX" "$PG"
PGR=$(mktemp -d /tmp/spore-progr.XXXXXX)
PGO=$(alpine "$SPORE" --spore "$PG" --root "$PGR" apply --persist 2>&1 || true)
has 'a package is announced first'   "$PGO" '> package openssh'
has 'and reported after'             "$PGO" '+ package openssh'
has 'a script action too'            "$PGO" '> netup net-up'
# The longest silence in the run, and the one that prompted this.
has 'and the commit, which is silent' "$PGO" '> committing the apkovl to'
# The order is the whole point: announced, then done.
PG_A=$(printf '%s\n' "$PGO" | grep -n '> package openssh' | head -1 | cut -d: -f1)
PG_B=$(printf '%s\n' "$PGO" | grep -n '+ package openssh' | head -1 | cut -d: -f1)
if [ -n "$PG_A" ] && [ -n "$PG_B" ] && [ "$PG_A" -lt "$PG_B" ]; then
    t_ok 'announced before it is reported done'
else
    t_fail 'announced before it is reported done' "start [$PG_A], done [$PG_B]"
fi
# A dry run promises, it does not announce: two lines for work never done
# would read as work in progress.
PGD=$(mktemp -d /tmp/spore-progd.XXXXXX)
PGDO=$(alpine "$SPORE" --spore "$PG" --root "$PGD" --dry-run apply 2>&1 || true)
hasnt 'a dry run announces nothing'  "$PGDO" '> package openssh'
has   'it only says what it would do' "$PGDO" 'would install package openssh'
rm -rf "$PG" "$PGR" "$PGD"

section 'try says what the boot did, instead of just exiting'
# Without this the command exits silently, and "it did not boot", "it booted
# and the seed never ran" and "it stopped halfway through installing a
# package" are the same event as far as the terminal is concerned — three
# completely different problems.
TRW=$(mktemp -d /tmp/spore-tryrep.XXXXXX)
tr_say() {
    printf '%s' "$2" > "$TRW/l"
    ( . "$ROOT/lib/core.sh"; . "$ROOT/lib/try.sh"
      SPORE_WORK=$TRW; SPORE_SELF=spore; try_report "$TRW/l" ) 2>&1
}
has 'nothing at all means no kernel' \
    "$(tr_say empty '')" 'never
         reached a kernel'
has 'output but no banner is the bootloader' \
    "$(tr_say nokern 'SeaBIOS
no bootable device')" 'no kernel banner'
has 'a kernel with no seed is the overlay' \
    "$(tr_say noseed '[0.0] Linux version 6.18
login:')" 'spore-seed service never ran'
# The announcement with no completion is what names the stall — the whole
# reason those announcements exist.
has 'a stall names the action it stalled in' \
    "$(tr_say stall '[0.0] Linux version 6.18
=== spore seed: now ===
  > package openssh
  + package openssh
  > committing the apkovl to /media/sda2')" 'committing the apkovl to /media/sda2'
has 'and says it never finished' \
    "$(tr_say stall2 '[0.0] Linux version 6.18
=== spore seed: now ===
  > committing the apkovl to /media/sda2')" 'never reported finishing'
has 'a finished boot is reported as such' \
    "$(tr_say ok '[0.0] Linux version 6.18
=== spore seed: now ===
  > committing the apkovl to /media/sda2
  + committed
converged and committed')" 'applied and committed'
# An action that did finish is not reported as a stall.
hasnt 'a completed action is not a stall' \
    "$(tr_say done '[0.0] Linux version 6.18
=== spore seed: now ===
  > package openssh
  + package openssh')" 'stopped in the middle of'
rm -rf "$TRW"

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
    # Not `pkg age`: that needs a mirror, and the machine most in need of an
    # unattended password is the one whose network is not up. `spore install`
    # carries the binary, and this looks there first.
    has 'age is there before secrets are written'            "$SP" 'bootstrap  age-available'
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
    has 'and brings age with it'        "$PWP" 'bootstrap  age-available'
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
has 'ordered after mounts and drivers'  "$SEEDUNIT" 'after localmount hwdrivers modules net'
hasnt 'without depending on them'      "$SEEDUNIT" 'need localmount'
has 'hook discovers a spore on media' "$SEEDSTART" '/media/*/spore'
# The spore is looked for before the stamp is checked, because finding it is
# also what tells save_log where this boot's log goes. Stopping at the stamp
# first meant the boot that finally came up on its own overlay — the one worth
# having a record of — wrote its log to a RAM disk and took it down with it.
SEED_FIND=$(printf '%s\n' "$SEEDSTART" | grep -n 'for d in /media/\*/spore' | head -1 | cut -d: -f1)
SEED_STAMP=$(printf '%s\n' "$SEEDSTART" | grep -n 'f /etc/spore/.seeded' | head -1 | cut -d: -f1)
if [ -n "$SEED_FIND" ] && [ -n "$SEED_STAMP" ] && [ "$SEED_FIND" -lt "$SEED_STAMP" ]; then
    t_ok 'and looks before it checks the converged stamp'
else
    t_fail 'and looks before it checks the converged stamp' \
        "find [$SEED_FIND], stamp [$SEED_STAMP]"
fi
# `spore retire` takes the live seed away, so a medium is ours by any of its
# marks. Keying only on the seed meant the first boot after a retire had nowhere
# to write its log.
has 'a retired medium still takes the log' "$SEEDSTART" 'spore-seed.superseded.tar.gz'
has 'as does one with just a spore on it'  "$SEEDSTART" '/mnt/spore-log/spore/spore.conf'
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
# And to the console, always. Writing only to a file assumes a filesystem can be
# written, and "nothing could be read or written" is the failure worth
# reporting — so the report went into the void exactly when it was needed.
has 'everything is said on the console too' "$SEEDSTART" 'tee -a /dev/console'
has 'and the exit status survives the pipe' "$SEEDSTART" 'spore-seed.rc'
# When nothing is found, say what was tried and why each one failed.
has 'a failed scan names what it tried'     "$SEEDSTART" 'would not mount'
# The initramfs mounts the medium read-only, so every copy failed silently —
# which is why there was never a log to read in any boot that produced one.
has 'the medium is remounted to write it'   "$SEEDSTART" 'remount,rw'
has 'and put back read-only after'          "$SEEDSTART" 'remount,ro'

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
# /etc is NOT "already in the overlay": lbu's list is `apk audit --backup` plus
# the includes, and on a real machine the audit half reported
# etc/runlevels/default/sshd and etc/hostname while missing
# etc/init.d/spore-seed. So the spore's own files are named, /etc included —
# a service in a runlevel whose script did not survive errors on every boot.
has 'the spore-owned /etc files are named too' "$(cat "$PLOG")" 'lbu include /etc/'

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
    'tester' 'y' "$WZ/id.pub" 'y' '2222' 'n' 'n' 'n' |
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
# Asked once. A validation loop here was a prompt you could not get past, which
# is a worse thing to be caught in than the problem it was avoiding.
WZK=$(mktemp -d /tmp/spore-wizkm.XXXXXX)
printf '%s\n' 'kmhost' 'br' 'UTC' 'none' 'auto' 'dhcp' '' 'tester' 'n' '' 'n' 'n' 'n' |
    env HOME="$WZK" SUDO_USER= SPORE_PUBKEY= "$SPORE" setup > "$WZK/out" 2>&1 || true
check 'a layout alone is taken as given' \
    "$(grep '^SYSTEM_KEYMAP=' "$WZK/spores/kmhost/spore/modules/system.conf")" \
    'SYSTEM_KEYMAP="br"'
check 'and the next question is the next one' \
    "$(grep -c 'Keyboard \[' "$WZK/out")" 1
rm -rf "$WZK"
# And there has to be a way to say "leave it alone" that is not a blank line,
# because a blank line is how you take the default.
WZD=$(mktemp -d /tmp/spore-wizdash.XXXXXX)
printf '%s\n' 'dashhost' '-' 'UTC' 'none' 'auto' 'dhcp' '' 'tester' 'n' '' 'n' 'n' 'n' |
    env HOME="$WZD" SUDO_USER= SPORE_PUBKEY= "$SPORE" setup > "$WZD/out" 2>&1 || true
check 'a dash leaves the layout alone' \
    "$(grep -c '^SYSTEM_KEYMAP=' "$WZD/spores/dashhost/spore/modules/system.conf" || true)" 0
rm -rf "$WZD"
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
# Given a layout with no variant, setup-keymap asks the machine for one — and
# nobody answers on a box that is booting itself, so it reads EOF and asks
# again, for ever, with no console to say so on.
# setup-keymap is not called at all. Its prompt is a `while true` around a read
# that treats an empty answer as "ask again", so on a machine with nobody at the
# console it loops on EOF for ever, reprinting the variant list as fast as the
# console will take it. Closing its stdin makes it spin faster, not stop.
SYSRC=$(cat "$ROOT/modules/system.sh")
has   'the keymap is installed direct' "$SYSRC" 'render_keymap'
KMGEN=$( . "$ROOT/lib/render.sh"; render_keymap br br-abnt2 )
hasnt 'and the script never calls it'  "$KMGEN" 'setup-keymap'
KMSRC=$(cat "$ROOT/lib/render.sh")
has 'it copies the map itself'        "$KMSRC" '/usr/share/bkeymaps'
has 'and points loadkmap at it'       "$KMSRC" '/etc/conf.d/loadkmap'
has 'and adds the service'            "$KMSRC" 'rc-update --quiet add loadkmap boot'
# Run it. A pair that exists must land, and one that does not must say which do
# and stop — that listing is the whole of what the prompt was for.
KMT=$(mktemp -d /tmp/spore-km.XXXXXX)
mkdir -p "$KMT/usr/share/bkeymaps/br" "$KMT/usr/share/bkeymaps/us"
touch "$KMT/usr/share/bkeymaps/br/br-abnt2.bmap.gz" \
      "$KMT/usr/share/bkeymaps/br/br-latin1-abnt2.bmap.gz" \
      "$KMT/usr/share/bkeymaps/us/us.bmap.gz"
km_run() {
    ( . "$ROOT/lib/render.sh"; render_keymap "$1" "$2" ) |
        sed "s|/usr/share/bkeymaps|$KMT/usr/share/bkeymaps|g;
             s|/etc/keymap|$KMT/etc/keymap|g; s|/etc/conf.d|$KMT/etc/conf.d|g" > "$KMT/km.sh"
    # The failing cases exit 1 on purpose, and under `set -e` a command
    # substitution that fails takes the whole suite with it.
    sh "$KMT/km.sh" 2>&1 || true
}
KMO=$(km_run br br-abnt2)
has   'a real pair is installed'     "$KMO" 'spore: keymap br br-abnt2'
check 'and loadkmap points at it' \
    "$(grep -c 'br-abnt2.bmap.gz' "$KMT/etc/conf.d/loadkmap" 2>/dev/null || echo 0)" 1
# `br br` is exactly what a layout with no variant becomes, and it is not real.
# Alpine names every variant for its layout — us-dvorak, br-abnt2 — so the bare
# word is the natural thing to write and matches nothing. Try it both ways.
KMO4=$(km_run br abnt2)
has 'a bare variant finds the real one' "$KMO4" 'spore: keymap br abnt2'
check 'and installs the prefixed file' \
    "$(grep -c 'br-abnt2.bmap.gz' "$KMT/etc/conf.d/loadkmap" 2>/dev/null || echo 0)" 1
# `br br` is what a layout with no variant becomes, and it is not real.
KMO2=$(km_run br br)
has 'a pair that is not real is named'  "$KMO2" "layout 'br' has no variant 'br'"
has 'with the ones that are'            "$KMO2" 'spore:   br br-abnt2'
KMO3=$(km_run zz zz)
has 'and an unknown layout likewise'    "$KMO3" "no layout 'zz'"
has 'listing the layouts there are'     "$KMO3" 'spore:   br'
# But it does not take the machine with it. This aborted a run three actions
# short of the password, on a box whose whole purpose was to come up with one.
km_rc() {
    ( . "$ROOT/lib/render.sh"; render_keymap "$1" "$2" ) |
        sed "s|/usr/share/bkeymaps|$KMT/usr/share/bkeymaps|g;
             s|/etc/keymap|$KMT/etc/keymap|g; s|/etc/conf.d|$KMT/etc/conf.d|g" > "$KMT/km.sh"
    sh "$KMT/km.sh" >/dev/null 2>&1
    printf '%s' $?
}
check 'a keymap nobody has is not fatal' "$(km_rc br nosuchvariant)" 0
check 'nor is a layout nobody has'       "$(km_rc zz zz)" 0
check 'a real one still succeeds'        "$(km_rc br br-abnt2)" 0
rm -rf "$KMT"
# Nothing may run for ever, whatever it is. An action that never returns takes
# the boot with it, before anything can be written down about why.
ELSRC=$(cat "$ROOT/lib/exec_live.sh")
has 'every script action has a deadline' "$ELSRC" 'timeout "$SPORE_SCRIPT_TIMEOUT" sh'
has 'and stdin is left alone'            "$ELSRC" 'Stdin is deliberately not redirected'
# A layout on its own becomes its own variant, which is all `us us` ever was.
# Refusing instead would fail a whole apply over a keyboard, and re-asking would
# be a prompt you cannot get past — neither is better than a keymap.
KM=$(mktemp -d /tmp/spore-keymap.XXXXXX)/s; cp -r "$EX" "$KM"
printf 'SYSTEM_KEYMAP=br\n' > "$KM/modules/system.conf"
printf 'FORMAT=1\nHOST=k\nMODULES="system"\n' > "$KM/spore.conf"
KMO=$(alpine "$SPORE" --spore "$KM" plan 2>&1)
has 'a layout alone still plans'          "$KMO" 'firstboot  system-keymap'
# No note here any more: whether `br br` is a real pair is a fact about the
# image's keymaps, which this planner cannot see. The script says so on the
# machine, where the files are, and lists the variants that do exist.
printf 'SYSTEM_KEYMAP=br br-abnt2\n' > "$KM/modules/system.conf"
KMO2=$(alpine "$SPORE" --spore "$KM" plan 2>&1)
has 'both words plan fine'                "$KMO2" 'firstboot  system-keymap'
hasnt 'and are left alone'                "$KMO2" 'named a layout and no variant'
# Three words is not a keymap in any reading, so that one is said plainly.
printf 'SYSTEM_KEYMAP=a b c\n' > "$KM/modules/system.conf"
if KMO3=$(alpine "$SPORE" --spore "$KM" plan 2>&1); then
    t_fail 'three words is refused' 'planned anyway'
else has 'three words is refused' "$KMO3" "Got 'a b c'"; fi
rm -rf "$KM"
has 'the network comes up before apk'   "$WZP" 'netup      net-up'
# setup-alpine asks for both of these, and for good reason: the default CDN can
# be far away, and a box with no battery-backed clock boots in 1970, where every
# certificate looks not-yet-valid.
check 'the mirror is recorded'          "$(grep '^REPOS_MIRROR=' "$WZS/modules/repos.conf")" \
                                        'REPOS_MIRROR=https://mirror.ufpr.br/alpine'
has 'and set before any package'        "$WZP" 'bootstrap  repos-mirror'
check 'the ntp client'                  "$(grep '^SYSTEM_NTP=' "$WZS/modules/system.conf")" \
                                        'SYSTEM_NTP=chrony'
has 'the clock is set before anything' "$WZP" 'firstboot  system-ntp'
# Not setup-ntp: its last line is `rc-service $svc start`, so its exit status
# is that start's — and from inside a service in the default runlevel OpenRC
# refuses anything whose dependencies belong to an earlier one. The daemon ends
# up configured correctly and the whole apply dies anyway.
SYSRC2=$(cat "$ROOT/modules/system.sh")
hasnt 'setup-ntp is never invoked'      "$SYSRC2" 'setup-ntp '
has   'the daemon is a service action'  "$SYSRC2" 'plan_svc "$sy_svc" default on'
has   'and the clock is set on its own' "$SYSRC2" 'busybox ntpd -qnN'
# Starting is best-effort everywhere, for the same reason. Enabling is the
# durable half and stays fatal; a service that will not start right now is in
# the runlevel and comes up on the next boot.
ELSRC2=$(cat "$ROOT/lib/exec_live.sh")
has   'a service that will not start yet is not fatal' \
      "$ELSRC2" 'enabled, starts next boot'
hasnt 'and no longer dies on a dead daemon' \
      "$ELSRC2" 'die "$es_name reported a successful start'
has 'and the apkovl has a destination'  "$WZP" 'file       /etc/lbu/lbu.conf'
# An existing machine is offered up for replacement rather than refused — but
# only a machine, and only when the answer is yes. Its identity is in there.
WZE=$(mktemp -d /tmp/spore-wizexist.XXXXXX)
printf '%s\n' 'again' 'us us' 'UTC' 'none' 'eth0' 'dhcp' '' 'tester' 'n' '' 'n' 'n' 'n' |
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
printf '%s\n' 'again' 'y' 'us us' 'UTC' 'none' 'eth0' 'dhcp' '' 'tester' 'n' '' 'n' 'n' 'n' |
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
    'tester' 'n' '' 'n' 'n' 'n' |
    env HOME="$WZH" SUDO_USER= SPORE_PUBKEY= "$SPORE" setup > "$WZH/out" 2>&1 || true
has 'the disk is offered, not a directory' "$(cat "$WZH/out")" 'Write a USB stick now'
check 'declining still keeps the answers' \
    "$([ -f "$WZH/spores/homehost/spore/spore.conf" ] && echo yes || echo no)" yes
check 'and the identity with them' \
    "$([ -f "$WZH/spores/homehost/identity" ] && echo yes || echo no)" yes
has 'and it says what is left to do' "$(cat "$WZH/out")" 'not on a disk yet'
rm -rf "$WZH"

# Input that runs out must stop the wizard, not make it spin. Read through $( ),
# every prompt ran in a subshell that could not stop anything, so on EOF each one
# silently handed back its default for ever — and a loop that rejects its own
# default (an empty IP address, say) asked the same unanswerable question until
# the terminal was killed. `timeout` is the assertion here: without it this test
# never returns, which is exactly the bug.
WZX=$(mktemp -d /tmp/spore-wizeof.XXXXXX)
if command -v timeout >/dev/null 2>&1; then
    WZXRC=0
    printf '%s\n' 'eofhost' 'us us' 'UTC' 'none' 'eth0' 'static' |
        env HOME="$WZX" SUDO_USER= SPORE_PUBKEY= \
            timeout 20 "$SPORE" setup > "$WZX/out" 2>&1 || WZXRC=$?
    check 'input running out ends the wizard' "$([ "$WZXRC" = 124 ] && echo spun || echo stopped)" stopped
    has   'and says where it ran out'         "$(cat "$WZX/out")" 'input ended at "IP address"'
else
    printf '  (no timeout(1) here — the EOF loop guard was not exercised)\n'
fi
rm -rf "$WZX"

# A mistyped device path costs a retry, not the answers to fifteen questions.
WZR=$(mktemp -d /tmp/spore-wizretry.XXXXXX)
printf '%s\n' 'retryhost' 'us us' 'UTC' 'none' 'eth0' 'dhcp' '' 'tester' 'n' '' \
    'n' 'n' 'y' '/dev/definitely-not-here' '' |
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
# One unreachable mirror is not a reason to abandon a machine: the boot medium
# may carry a local repository with what is needed, and a package that genuinely
# is not available anywhere says so when it fails to install — a far clearer
# place to stop than an update that could not reach one of three repositories.
REPOSRC=$(cat "$ROOT/modules/repos.sh")
has  'a partly unreachable mirror is survivable' "$REPOSRC" 'could not reach every repository'
if grep -qx 'apk update' "$ROOT/modules/repos.sh"; then
    t_fail 'rather than a bare apk update' 'an unguarded apk update remains'
else
    t_ok 'rather than a bare apk update'
fi
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

# Once the seed is retired the machine boots its own overlay, the seed service
# stops at the stamp, and nothing is committed because nothing changed. That is
# the finished state — and it read as "the boot ended without the spore
# committing", word for word what a boot that died halfway gets.
TRD=$(mktemp -d /tmp/spore-tryverdict.XXXXXX)
printf 'Linux version 6.18\n=== spore seed: now ===\nalready converged; nothing to do\n' \
    > "$TRD/quiet.log"
TRD_Q=$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/try.sh"
         SPORE_WORK=$TRD; try_report "$TRD/quiet.log" 2>&1 )
has   'a boot with nothing to do is a finished machine' "$TRD_Q" 'booted from its own committed overlay'
hasnt 'not a boot that failed to commit'                "$TRD_Q" 'ended without the spore committing'
# And a boot that really did stop short still says so.
printf 'Linux version 6.18\n=== spore seed: now ===\n  > package openssh\n' > "$TRD/stuck.log"
TRD_S=$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/try.sh"
         SPORE_WORK=$TRD; try_report "$TRD/stuck.log" 2>&1 )
has 'while one that stopped still names where' "$TRD_S" 'package openssh'
rm -rf "$TRD"

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
# A seed set aside by a commit did its job; saying "nothing would have run at
# all" about it describes the opposite of what happened.
INSUP=$(mktemp -d /tmp/spore-supseed.XXXXXX)
mkdir -p "$INSUP/spore"
printf 'FORMAT=1\nHOST=k\nMODULES="net"\n' > "$INSUP/spore/spore.conf"
printf 'x\n' > "$INSUP/spore-seed.superseded.tar.gz"
INSUPO=$("$SPORE" inspect "$INSUP" 2>&1)
has   'a retired seed is reported as retired' "$INSUPO" 'set aside after a commit'
hasnt 'not as one that never ran'             "$INSUPO" 'nothing would have run at all'
# But that is a fact about this directory, not a verdict on the machine. Whether
# it boots its own overlay is decided by what the initramfs finds first, and
# install always leaves a second seed on the boot partition — which this had no
# way of knowing and claimed anyway.
hasnt 'and does not claim what it cannot see' "$INSUPO" 'boots from its own committed overlay'
rm -rf "$INSUP"

# Two apkovls on one medium: the seed the install left on the boot partition,
# and the overlay the first commit wrote. Alpine's init takes `head -n 1` of
# whatever nlplug-findfs turned up, so the machine that comes up is probe order.
RACE=$(mktemp -d /tmp/spore-race.XXXXXX)
mkdir -p "$RACE/boot" "$RACE/data"
printf 'seed\n' > "$RACE/boot/spore-seed.apkovl.tar.gz"
RACE_Q=$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/inspect.sh"
          inspect_seed_race "$RACE/boot" "$RACE/data" /dev/sdz 2>&1 )
check 'before any commit, a seed on the boot partition is just the seed' \
    "${RACE_Q:-quiet}" quiet
printf 'overlay\n' > "$RACE/data/coisas.apkovl.tar.gz"
RACE_W=$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/inspect.sh"
          inspect_seed_race "$RACE/boot" "$RACE/data" /dev/sdz 2>&1 )
has   'once one is committed, the race is called out' "$RACE_W" 'holds two apkovls'
# A mount/rename/unmount printed inside a warning is a line long enough to wrap,
# and the first person to paste it pasted as far as the wrap — renaming the seed
# onto itself. It names the verb now.
has   'with the command to settle it'                 "$RACE_W" 'spore retire /dev/sdz'
hasnt 'and not a shell line long enough to wrap'      "$RACE_W" 'sudo mv /mnt/'
# The log settles which way it went, so this does not have to predict it. A full
# apply can only happen when there was no /etc/spore/.seeded to find, and the
# committed overlay carries one — so that boot came up from a seed.
printf 'applying /media/sda2/spore\n25 changed, 3 already correct\n' > "$RACE/data/spore-seed.log"
RACE_A=$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/inspect.sh"
          inspect_seed_race "$RACE/boot" "$RACE/data" /dev/sdz 2>&1 )
has   'and the last boot is read off the log'  "$RACE_A" 'did not use it: its log is a full apply'
printf 'already converged; nothing to do\n' > "$RACE/data/spore-seed.log"
RACE_C=$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/inspect.sh"
          inspect_seed_race "$RACE/boot" "$RACE/data" /dev/sdz 2>&1 )
has   'the other way round too'    "$RACE_C" 'last boot used the committed overlay'
has   'still warning, since it is probe order either way' "$RACE_C" 'holds two apkovls'
rm -f "$RACE/data/spore-seed.log"
# And why you might not want to: that copy is the recovery path if the
# initramfs cannot read the ext4 data partition at all.
has   'and the reason to keep it'  "$RACE_W" 'until you have seen the machine boot without it'
# The retired seed is not an apkovl any more and must not count as the overlay,
# or every committed medium would report a race with itself.
rm -f "$RACE/data/coisas.apkovl.tar.gz"
printf 'x\n' > "$RACE/data/spore-seed.superseded.tar.gz"
RACE_S=$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/inspect.sh"
          inspect_seed_race "$RACE/boot" "$RACE/data" /dev/sdz 2>&1 )
check 'a retired seed is not a second apkovl' "${RACE_S:-quiet}" quiet
rm -rf "$RACE"

# The same question one step earlier: inspect can see it in the overlay, so it
# should not take a retire attempt to find out.
OVLT=$(mktemp -d /tmp/spore-ovltool.XXXXXX)
mkdir -p "$OVLT/m/spore" "$OVLT/half/etc/init.d" \
         "$OVLT/whole/etc/init.d" "$OVLT/whole/usr/local/lib/spore"
printf 'FORMAT=1\nHOST=k\nMODULES="net"\n' > "$OVLT/m/spore/spore.conf"
printf 'svc\n' > "$OVLT/half/etc/init.d/spore-seed"
printf 'svc\n' > "$OVLT/whole/etc/init.d/spore-seed"
printf 'run\n' > "$OVLT/whole/usr/local/lib/spore/seed-run"
( cd "$OVLT/half" && tar -czf "$OVLT/m/k.apkovl.tar.gz" . )
OVLT_H=$("$SPORE" inspect "$OVLT/m" 2>&1)
has 'inspect calls out an overlay that cannot run its own service' \
    "$OVLT_H" 'without the tool that'
( cd "$OVLT/whole" && tar -czf "$OVLT/m/k.apkovl.tar.gz" . )
OVLT_W=$("$SPORE" inspect "$OVLT/m" 2>&1)
has 'and confirms one that can'  "$OVLT_W" 'it carries the tool'
has 'but says that boot still redoes everything' "$OVLT_W" 'no etc/spore/.seeded'
mkdir -p "$OVLT/whole/etc/spore"
printf 'now\n' > "$OVLT/whole/etc/spore/.seeded"
( cd "$OVLT/whole" && tar -czf "$OVLT/m/k.apkovl.tar.gz" . )
OVLT_S=$("$SPORE" inspect "$OVLT/m" 2>&1)
has 'and with the stamp, that it goes straight through' "$OVLT_S" 'goes straight through'
# An overlay with no seed service at all is a third answer, not the absence of
# one. Printing nothing for it meant a report where the check had simply not
# been installed yet read exactly like a clean bill of health.
( cd "$OVLT/m" && rm -f k.apkovl.tar.gz )
mkdir -p "$OVLT/bare/etc"
printf 'x\n' > "$OVLT/bare/etc/hostname"
( cd "$OVLT/bare" && tar -czf "$OVLT/m/k.apkovl.tar.gz" . )
OVLT_B=$("$SPORE" inspect "$OVLT/m" 2>&1)
has 'and says so when there is no seed service in it' "$OVLT_B" 'no spore-seed service'
# "No seed service in it" is a finding, not an explanation. lbu does not tar
# /etc wholesale — it takes what `apk audit --backup` reports plus the includes
# — so which half dropped a file is not guessable, and the archive is the only
# thing that knows.
has 'and shows what the overlay does hold' "$OVLT_B" 'of the files spore itself writes'
has 'naming the spore files it has'        "$OVLT_B" 'etc/hostname'
has 'and the ones it has not'              "$OVLT_B" 'etc/init.d/spore-seed'
rm -rf "$OVLT"

# Every file the seed carries, not a sample. This compared lib/seed.sh,
# lib/plan.sh, modules/net.sh and bin/spore, and said "matches this tool" about
# a medium whose persist.sh was two commits old — while persist.sh was the file
# the whole question was about. A staleness check you cannot trust is worse than
# none: the next thing you do is re-read a log that cannot have changed.
STW=$(mktemp -d /tmp/spore-stalew.XXXXXX)
STS=$(mktemp -d /tmp/spore-stales.XXXXXX)
mkdir -p "$STS/usr/local/lib/spore"
cp -r "$ROOT/bin" "$ROOT/lib" "$ROOT/modules" "$STS/usr/local/lib/spore/"
( cd "$STS" && tar -czf "$STW/same.tar.gz" . )
ST_SAME=$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/inspect.sh"
           SPORE_PREFIX=$ROOT; SPORE_WORK=$STW; inspect_stale "$STW/same.tar.gz" )
check 'an identical seed differs in nothing' "${ST_SAME:-none}" none
# A file the old check never looked at.
printf '\n# drift\n' >> "$STS/usr/local/lib/spore/lib/persist.sh"
( cd "$STS" && tar -czf "$STW/drift.tar.gz" . )
ST_DRIFT=$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/inspect.sh"
            SPORE_PREFIX=$ROOT; SPORE_WORK=$STW; inspect_stale "$STW/drift.tar.gz" )
check 'and one that drifted is named' "$ST_DRIFT" 'lib/persist.sh'
# A file added since the seed was built is absent from it, which comparing only
# what the seed holds could never notice.
rm -f "$STS/usr/local/lib/spore/lib/apkfetch.sh"
( cd "$STS" && tar -czf "$STW/missing.tar.gz" . )
ST_MISS=$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/inspect.sh"
           SPORE_PREFIX=$ROOT; SPORE_WORK=$STW; inspect_stale "$STW/missing.tar.gz" )
has 'a file the seed lacks is named too' "$ST_MISS" 'lib/apkfetch.sh(not-in-seed)'
rm -rf "$STW" "$STS"

# A log present is printed verbatim — it is the thing being looked for.
printf '=== spore seed ===\nno spore found on any attached filesystem.\n' \
    > "$IN/m/spore-seed.log"
INL=$("$SPORE" inspect "$IN/m" 2>&1)
has 'a log that exists is printed' "$INL" 'no spore found on any attached filesystem'
# The log is newer than the seed here, so nothing is said about its age.
hasnt 'a fresh log is not doubted'  "$INL" 'older than the seed'
# A log from before the last install reads exactly like fresh evidence, and a
# whole round can go into explaining a failure that has already been replaced.
touch "$IN/m/spore-seed.apkovl.tar.gz"
INA=$("$SPORE" inspect "$IN/m" 2>&1)
has 'a log older than its seed is doubted' "$INA" 'older than the seed next to it'

# The other log, on this side. Under -snapshot the medium's own log cannot
# change, so the VM's console is the only record a try boot leaves — and being
# told "nothing happened" while the answer sits in the working directory is a
# trap this command laid for its own user, repeatedly.
INV=$(mktemp -d /tmp/spore-vmlog.XXXXXX)
mkdir -p "$INV/m/spore"
printf 'FORMAT=1\nHOST=k\nMODULES="net"\n' > "$INV/m/spore/spore.conf"
printf 'an older boot\n' > "$INV/m/spore-seed.log"
sleep 1
printf '[0.0] Linux version 6.18\n=== spore seed: now ===\n  > recording what to keep\n' \
    > "$INV/boot.log"
INVO=$(SPORE_TRY_LOG="$INV/boot.log" "$SPORE" inspect "$INV/m" 2>&1)
has 'a newer VM log is read too'     "$INVO" 'the last VM boot'
has 'and its verdict given'          "$INVO" 'recording what to keep'
# The other way round would be the same confusion pointing backwards.
touch "$INV/m/spore-seed.log"
INVO2=$(SPORE_TRY_LOG="$INV/boot.log" "$SPORE" inspect "$INV/m" 2>&1)
hasnt 'an older VM log is left alone' "$INVO2" 'the last VM boot'
rm -rf "$INV"
has 'and says to boot before reading it'   "$INA" 'boot the machine again'
# The commonest reason it stays old is not that nobody booted: `spore try`
# discards writes unless told otherwise, so the seed log never lands.
has 'and names snapshot as the usual cause' "$INA" 'writes go to a'
has 'pointing at the console log instead'   "$INA" 'spore-boot.log'
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

section 'the plan does not carry the same action twice'
# Two sealed passwords each ask for age, so `bootstrap age-available` was
# emitted twice — the executor ran the first and reported the second as already
# correct, in the same run:
#
#     + bootstrap age-available
#     . bootstrap age-available
#
# Nothing was wrong with the machine; the plan was, and it inflated the counts.
DUP=$(mktemp -d /tmp/spore-dup.XXXXXX)
DUPP=$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/conf.sh"; . "$ROOT/lib/plan.sh"
        SPORE_WORK=$DUP; SPORE_PLAN=$DUP/plan.tsv; mkdir -p "$DUP/content"
        plan_reset
        SPORE_MOD=users
        plan_bootstrap age-available 'echo hi'
        plan_bootstrap age-available 'echo hi'
        plan_pkg doas; plan_pkg doas
        wc -l < "$DUP/plan.tsv" | tr -d ' ' )
check 'an identical line is emitted once' "$DUPP" 2
# Same name, different content, is a disagreement between two modules and not
# something to quietly drop.
DUPD=$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/conf.sh"; . "$ROOT/lib/plan.sh"
        SPORE_WORK=$DUP; SPORE_PLAN=$DUP/plan2.tsv; mkdir -p "$DUP/content"
        plan_reset
        SPORE_MOD=users
        plan_bootstrap age-available 'echo hi'
        plan_bootstrap age-available 'echo something else'
        wc -l < "$DUP/plan2.tsv" | tr -d ' ' )
check 'but a differing one still shows' "$DUPD" 2
rm -rf "$DUP"

section 'the keymap is loaded, not handed to a service that will refuse it'
# loadkmap.initd declares `need localmount`, and localmount is in the boot
# runlevel, which has finished by the time the spore-seed service runs in
# default. So `rc-service loadkmap restart` fails exactly the way chronyd does —
# and the failure went to /dev/null with a `|| true` after it. Every later boot
# picked the map up off the overlay, so the only boot with the wrong keyboard
# was the one that had just configured the machine, and it printed
# "keymap us dvorak" while doing it.
KMSRC=$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/render.sh"; render_keymap us dvorak )
# The call, not the word: the comment above it names rc-service too, and an
# assertion that matches its own explanation tests nothing.
if printf '%s\n' "$KMSRC" | grep -v '^[[:space:]]*#' | grep -q 'rc-service loadkmap'; then
    t_fail 'it does not go through rc-service' 'the call is still there'
else
    t_ok 'it does not go through rc-service'
fi
has   'it loads the map itself'             "$KMSRC" 'loadkmap'
has   'decompressing it the way the service does' "$KMSRC" 'zcat "$km" 2>/dev/null | loadkmap'
has   'and reading a plain one directly'    "$KMSRC" 'loadkmap < "$km"'
# Still added to the boot runlevel: that is where it belongs, and where every
# boot after this one gets it from.
has   'the service is still enabled for next boot' "$KMSRC" 'rc-update --quiet add loadkmap boot'
# The old line claimed success unconditionally. A console that did not take the
# map matters most when the next thing you do is type a password at it.
has   'a load that failed says so'          "$KMSRC" 'could not be applied to this console now'
has   'and says what that means'            "$KMSRC" 'about to type a password'

section 'spore modules add/rm: MODULES lives in spore.conf, so set could not reach it'
# Everything about a module was settable except whether it ran at all. Turning
# one on meant opening spore.conf and editing a quoted list by hand, which is
# where a typo becomes "that module silently does nothing".
MD=$(mktemp -d /tmp/spore-mods.XXXXXX)
cp -r "$EX" "$MD/s"
sed -i 's/^MODULES=.*/MODULES="net users"/' "$MD/s/spore.conf"

"$SPORE" -s "$MD/s" modules add dufs >/dev/null 2>&1
check 'it turns a module on'  "$(conf_read "$MD/s/spore.conf" MODULES)" 'net users dufs'
MD_TWICE=$("$SPORE" -s "$MD/s" modules add dufs 2>&1)
has   'adding it twice says so'     "$MD_TWICE" 'already enabled'
check 'and changes nothing'         "$(conf_read "$MD/s/spore.conf" MODULES)" 'net users dufs'
"$SPORE" -s "$MD/s" modules rm users >/dev/null 2>&1
check 'and off again'               "$(conf_read "$MD/s/spore.conf" MODULES)" 'net dufs'
MD_GONE=$("$SPORE" -s "$MD/s" modules rm users 2>&1)
has   'removing one that is off says so' "$MD_GONE" 'is not enabled'

MD_NO=$("$SPORE" -s "$MD/s" modules add nosuch 2>&1 || true)
has   'a module that does not exist is refused' "$MD_NO" "no module called 'nosuch'"
check 'and the list is untouched' "$(conf_read "$MD/s/spore.conf" MODULES)" 'net dufs'

# A spore with no modules plans nothing at all, which is not a state to leave
# someone in by accident.
MD_EMPTY=$("$SPORE" -s "$MD/s" modules rm net dufs 2>&1 || true)
has 'emptying MODULES is refused' "$MD_EMPTY" 'would leave MODULES empty'

MD_DRY=$("$SPORE" -n -s "$MD/s" modules add ssh 2>&1)
has   'a dry run says what it would do' "$MD_DRY" 'would set MODULES='
check 'and changes nothing'             "$(conf_read "$MD/s/spore.conf" MODULES)" 'net dufs'
# Listing still takes no arguments and still works without a spore.
MD_LIST=$("$SPORE" modules 2>&1)
has 'listing still lists'               "$MD_LIST" 'dufs file server'
rm -rf "$MD"

section 'spore setup asks about files, so the answer is one command'
# Sharing disks took eight `spore set` calls and two `modules add`. The guided
# command is where that belongs: a second verb for it would be a parallel way to
# express configuration, and the conf files are already the format.
WZ=$(mktemp -d /tmp/spore-wizshare.XXXXXX)
printf 'coisas\n\n\n\n\n\n\n\n\n\ny\n\n\ny\ny\nn\n' |
    "$SPORE" setup "$WZ/m" >/dev/null 2>&1 || true
if [ -f "$WZ/m/spore/spore.conf" ]; then
    has   'answering yes turns both modules on' \
        "$(conf_read "$WZ/m/spore/spore.conf" MODULES)" 'storage dufs'
    check 'and shares what is attached' \
        "$(conf_read "$WZ/m/spore/modules/storage.conf" STORAGE_AUTO)" 'yes'
    # By UUID, because the same stick was sdb2 on one boot and sdc2 the next.
    check 'named by uuid'  "$(conf_read "$WZ/m/spore/modules/storage.conf" STORAGE_AUTO_NAME)" 'uuid'
    check 'served from the same root' \
        "$(conf_read "$WZ/m/spore/modules/dufs.conf" DUFS_SERVE)" \
        "$(conf_read "$WZ/m/spore/modules/storage.conf" STORAGE_ROOT)"
    check 'over TLS when asked' \
        "$(conf_read "$WZ/m/spore/modules/dufs.conf" DUFS_TLS_SELFSIGNED)" 'yes'
    # "Allow writing?" is answered once, and it takes two settings to be true:
    # the server has to offer it and the filesystem has to permit it. Answering
    # yes and getting only the first is a server with an upload button that
    # refuses every upload.
    check 'answering yes to writing lets the server offer it' \
        "$(conf_read "$WZ/m/spore/modules/dufs.conf" DUFS_ALLOW_ALL)" 'yes'
    check 'and hands it the disks so the writes land' \
        "$(conf_read "$WZ/m/spore/modules/storage.conf" STORAGE_OWNER)" 'dufs'
    # And the result has to be a spore that plans, not just files that parse.
    WZ_PLAN=$(alpine "$SPORE" -s "$WZ/m/spore" -r "$WZ/r" plan 2>&1)
    has 'and the spore it wrote plans the service' "$WZ_PLAN" 'spore-automount'

    # Read-only is the default, and it must not hand the disks over anyway.
    printf 'coisas\n\n\n\n\n\n\n\n\n\ny\n\n\nn\ny\nn\n' |
        "$SPORE" setup "$WZ/m3" >/dev/null 2>&1 || true
    check 'a read-only share sets no owner' \
        "$(conf_read "$WZ/m3/spore/modules/storage.conf" STORAGE_OWNER)" ''
    has   'and says what to set if that changes' \
        "$(cat "$WZ/m3/spore/modules/storage.conf")" 'refuse every upload'

    # Answering no leaves both out entirely rather than writing them off.
    printf 'coisas\n\n\n\n\n\n\n\n\n\nn\nn\n' |
        "$SPORE" setup "$WZ/m2" >/dev/null 2>&1 || true
    hasnt 'answering no leaves them out' \
        "$(conf_read "$WZ/m2/spore/spore.conf" MODULES)" 'dufs'
    check 'and writes no config for them' \
        "$([ -f "$WZ/m2/spore/modules/dufs.conf" ] && echo yes || echo no)" no
    hasnt 'and no desktop either'  "$(conf_read "$WZ/m2/spore/spore.conf" MODULES)" 'desktop'

    # The desktop is the same shape of question: one answer, and the module is
    # on with a conf that explains itself.
    printf 'coisas\n\n\n\n\n\n\n\n\n\nn\ny\nsway\n' |
        "$SPORE" setup "$WZ/m4" >/dev/null 2>&1 || true
    has   'answering yes turns the desktop on' \
        "$(conf_read "$WZ/m4/spore/spore.conf" MODULES)" 'desktop'
    check 'with the environment that was asked for' \
        "$(conf_read "$WZ/m4/spore/modules/desktop.conf" DESKTOP_ENV)" 'sway'
    # users has to plan before desktop, or the account exists after the groups
    # were handed out. The wizard writes the order, so the wizard has to get it
    # right — and the spore it wrote has to plan, not merely parse.
    WZ_DPLAN=$(alpine "$SPORE" -s "$WZ/m4/spore" -r "$WZ/r4" plan 2>&1)
    has 'and the spore it wrote plans a desktop' "$WZ_DPLAN" 'pkg        sway'
    hasnt 'in an order that is not refused'      "$WZ_DPLAN" 'MODULES lists desktop before users'

    # The gateway was the default resolver here, and a gateway that routes
    # without resolving is invisible: the route works, it answers a ping, and
    # only apk complains — about the mirror.
    WZSRC=$(cat "$ROOT/lib/wizard.sh")
    hasnt 'the gateway is not offered as the resolver' "$WZSRC" "'DNS servers, space separated' \"\${wz_gw:-1.1.1.1}\""
    has   'a resolver that answers is'                 "$WZSRC" "'DNS servers, space separated' '1.1.1.1'"
else
    t_skip 'wizard file-sharing section (setup did not produce a spore here)'
fi
rm -rf "$WZ"

section 'what was declared, against what is actually listening'
# "The service started" and "you can reach it" are different claims, and every
# gap between them has cost a round trip here: a loopback bind, a port meaning
# https while serving http, a key the service could not read, a daemon
# supervise-daemon launched that exited a moment later. Each time the log said
# the service had started, because it had.
RPSRC=$(cat "$ROOT/lib/exec_live.sh")
has 'apply asks the kernel what is listening' "$RPSRC" 'netstat -lnt 2>/dev/null || ss -lnt'
has 'and says when a declared port is not'   "$RPSRC" 'and nothing is listening on it'
has 'and when it is only on loopback'        "$RPSRC" 'bound to the loopback address'
has 'it is called from apply'                "$(cat "$ROOT/bin/spore")" 'report_ports'
# MOD_PORTS already existed for the firewall; this reads the same declaration.
RP=$(mktemp -d /tmp/spore-ports.XXXXXX)
cp -r "$EX" "$RP/s"
sed -i 's/^MODULES=.*/MODULES="dufs"/' "$RP/s/spore.conf"
"$SPORE" -s "$RP/s" set dufs DUFS_PORT 8080 >/dev/null 2>&1
RP_OUT=$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/conf.sh"; . "$ROOT/lib/facts.sh"
          . "$ROOT/lib/plan.sh"; . "$ROOT/lib/module.sh"; . "$ROOT/lib/exec_live.sh"
          SPORE_ROOT=/; SPORE_DRYRUN=0; SPORE_ALL_PORTS='8080/tcp'
          report_ports 2>&1 )
has 'a declared port nothing serves is reported' "$RP_OUT" 'declared port 8080'
# And a port something is on comes back with the address, which is the whole
# point: 0.0.0.0 and 127.0.0.1 are different answers to "is it reachable".
hasnt 'without inventing a listener'             "$RP_OUT" 'port 8080: '
# Nothing to say when no module declared a port at all.
RP_NONE=$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/conf.sh"; . "$ROOT/lib/facts.sh"
           . "$ROOT/lib/plan.sh"; . "$ROOT/lib/module.sh"; . "$ROOT/lib/exec_live.sh"
           SPORE_ROOT=/; SPORE_DRYRUN=0; SPORE_ALL_PORTS=''
           report_ports 2>&1 )
check 'and silence when none was declared' "${RP_NONE:-quiet}" quiet
rm -rf "$RP"

section 'the service user exists before anything is given to it'
# firstboot actions run in the order they are planned, and dufs-tls came first.
# It chowned the private key to an account dufs-user had not created yet: the
# chown failed, `2>/dev/null || true` swallowed it, chmod 600 left the key
# root-owned, and dufs — running as dufs:dufs — could not read its own key. It
# started and died, and the only complaint in the chain was the silenced one.
UO=$(mktemp -d /tmp/spore-dufsorder.XXXXXX)
cp -r "$EX" "$UO/s"
sed -i 's/^MODULES=.*/MODULES="dufs"/' "$UO/s/spore.conf"
"$SPORE" -s "$UO/s" set dufs DUFS_TLS_SELFSIGNED yes >/dev/null 2>&1
alpine env SPORE_WORK="$UO/w" "$SPORE" -s "$UO/s" -r "$UO/r" plan >/dev/null 2>&1
UO_USER=$(grep -n 'dufs-user' "$UO/w/plan.tsv" | head -1 | cut -d: -f1)
UO_TLS=$(grep -n 'dufs-tls'  "$UO/w/plan.tsv" | head -1 | cut -d: -f1)
if [ -n "$UO_USER" ] && [ -n "$UO_TLS" ] && [ "$UO_USER" -lt "$UO_TLS" ]; then
    t_ok 'the account is created before the certificate'
else
    t_fail 'the account is created before the certificate' "user [$UO_USER], tls [$UO_TLS]"
fi

if command -v openssl >/dev/null 2>&1; then
    UO_SHA=$(awk -F'\t' '$2=="firstboot" && $3=="dufs-tls" {print $4}' "$UO/w/plan.tsv")
    sed "s|/etc/dufs/tls|$UO/tls|g" "$UO/w/content/$UO_SHA" > "$UO/gen.sh"
    # With no such account — which is every seed boot, since the seed's /etc is
    # generic — the key cannot be handed over, and that has to be fatal rather
    # than tolerated: a root-owned key is a service that exits on startup.
    UO_OUT=$(sh "$UO/gen.sh" 2>&1 || true)
    # Not $( ...; echo $? ): set -e kills the subshell at the failing command
    # and the echo never runs, which empties the variable and takes the suite
    # down with it.
    UO_RC=0
    sh "$UO/gen.sh" >/dev/null 2>&1 || UO_RC=$?
    has   'a key that cannot be handed over is fatal' "$UO_OUT" 'could not give the TLS key'
    check 'and the action fails rather than continuing' "$UO_RC" 1
fi
# The serve directory keeps its tolerance — that one can be on vfat, which
# carries no ownership at all.
DSRC=$(cat "$ROOT/modules/dufs.sh")
has   'the serve directory chown is still tolerated' "$DSRC" "chown -R '\$dufs_user:\$dufs_user' '\$dufs_serve' 2>/dev/null || true"
hasnt 'but the key chown is not'                     "$DSRC" "chown '\$dufs_user:\$dufs_user' '\$dufs_key' '\$dufs_cert' 2>/dev/null"
rm -rf "$UO"

section 'https on a port that means https'
# SSL_ERROR_RX_RECORD_TOO_LONG: plain bytes where the browser expected a
# handshake. It is the one TLS failure Firefox will not let you click past —
# unlike a self-signed certificate, which it will — so a file server on 443
# with no TLS is a page that simply never loads.
TW=$(mktemp -d /tmp/spore-tlswarn.XXXXXX)
cp -r "$EX" "$TW/s"
sed -i 's/^MODULES=.*/MODULES="dufs"/' "$TW/s/spore.conf"
rm -f "$TW/s/modules/dufs.conf"          # enabled with `modules add`, nothing else
"$SPORE" -s "$TW/s" set dufs DUFS_PORT 443 >/dev/null 2>&1
TW_443=$(alpine "$SPORE" -s "$TW/s" -r "$TW/r" plan 2>&1)
has 'a tls port serving plain http is called out' "$TW_443" 'port 443 with no TLS configured'
has 'by the error the browser will give'          "$TW_443" 'SSL_ERROR_RX_RECORD_TOO_LONG'
has 'and says Firefox offers no way past it'      "$TW_443" 'will not let you click'

# The whole TLS block is gated on the certificate paths, and those default to
# empty — so asking for a self-signed certificate and nothing else did nothing
# at all, silently. Nobody means that.
"$SPORE" -s "$TW/s" set dufs DUFS_TLS_SELFSIGNED yes >/dev/null 2>&1
TW_SS=$(alpine env SPORE_WORK="$TW/w" "$SPORE" -s "$TW/s" -r "$TW/r2" plan 2>&1)
has   'asking for TLS alone now supplies the paths' "$TW_SS" 'TLS was asked for without'
hasnt 'and the port warning goes with it'           "$TW_SS" 'port 443 with no TLS'
check 'and a certificate is actually planned' \
    "$(awk -F'\t' '$2=="firstboot" && $3=="dufs-tls"' "$TW/w/plan.tsv" | wc -l | tr -d ' ')" 1
has   'and the config names it'  "$TW_SS" 'tls'

# An ordinary port serving http is not a mistake, and says nothing.
"$SPORE" -s "$TW/s" set dufs DUFS_TLS_SELFSIGNED no >/dev/null 2>&1
"$SPORE" -s "$TW/s" set dufs DUFS_PORT 5000 >/dev/null 2>&1
TW_PLAIN=$(alpine "$SPORE" -s "$TW/s" -r "$TW/r3" plan 2>&1)
hasnt 'plain http on an ordinary port is left alone' "$TW_PLAIN" 'with no TLS configured'
rm -rf "$TW"

section 'the self-signed certificate, against both shapes of ip(1)'
# Getting the address wrong here writes no certificate at all, not a wrong one:
#   openssl req ... -addext "subjectAltName=IP:localhost"
#   error:11000076:X509 V3 routines:a2i_GENERAL_NAME:bad ip address
# Two ways that happened. `ip route get 1` ends the line with `uid 0` on
# iproute2 and with the address on busybox, so the last field was `0` on one of
# them; and the fallback was the word `localhost`, which is a name. IP:0 is
# refused too, so the path meant to rescue the other one could not work either.
if command -v openssl >/dev/null 2>&1; then
    TL=$(mktemp -d /tmp/spore-dufstls.XXXXXX)
    cp -r "$EX" "$TL/s"
    sed -i 's/^MODULES=.*/MODULES="dufs"/' "$TL/s/spore.conf"
    "$SPORE" -s "$TL/s" set dufs DUFS_TLS_SELFSIGNED yes >/dev/null 2>&1
    alpine env SPORE_WORK="$TL/w" "$SPORE" -s "$TL/s" -r "$TL/r" plan >/dev/null 2>&1
    TL_SHA=$(awk -F'\t' '$2=="firstboot" && $3=="dufs-tls" {print $4}' "$TL/w/plan.tsv")
    sed "s|/etc/dufs/tls|$TL/tls|g" "$TL/w/content/$TL_SHA" > "$TL/gen.sh"
    mkdir -p "$TL/bin"

    # iproute2: the line ends `uid 0`, which is what used to become the CN.
    printf '#!/bin/sh\n[ "$1 $2" = "route get" ] && { echo "1.0.0.0 via 10.0.0.1 dev eth0 src 10.0.0.5 uid 0"; exit 0; }\nexit 1\n' \
        > "$TL/bin/ip"
    chmod 755 "$TL/bin/ip"
    TL_OUT=$(PATH="$TL/bin:$PATH" sh "$TL/gen.sh" 2>&1 || true)
    check 'a certificate is written at all' \
        "$([ -s "$TL/tls/server.crt" ] && echo yes || echo no)" yes
    has 'with the address after src, not the uid' \
        "$(openssl x509 -in "$TL/tls/server.crt" -noout -ext subjectAltName 2>/dev/null)" \
        'IP Address:10.0.0.5'
    # And the hostname too: a machine reached by name and one reached by address
    # are the same machine.
    has 'and the hostname beside it' \
        "$(openssl x509 -in "$TL/tls/server.crt" -noout -ext subjectAltName 2>/dev/null)" 'DNS:'

    # busybox: the same line without the uid, which used to be the working case.
    rm -rf "$TL/tls"
    printf '#!/bin/sh\n[ "$1 $2" = "route get" ] && { echo "1.0.0.0 via 10.0.0.1 dev eth0  src 10.0.0.5"; exit 0; }\nexit 1\n' \
        > "$TL/bin/ip"
    PATH="$TL/bin:$PATH" sh "$TL/gen.sh" >/dev/null 2>&1 || true
    has 'busybox output still works' \
        "$(openssl x509 -in "$TL/tls/server.crt" -noout -ext subjectAltName 2>/dev/null)" \
        'IP Address:10.0.0.5'

    # No route at all: a name is a DNS SAN, never an IP one, or openssl refuses
    # and the machine is left configured for TLS with no certificate.
    rm -rf "$TL/tls"
    printf '#!/bin/sh\nexit 1\n' > "$TL/bin/ip"
    PATH="$TL/bin:$PATH" sh "$TL/gen.sh" >/dev/null 2>&1 || true
    check 'with no address, a certificate is still written' \
        "$([ -s "$TL/tls/server.crt" ] && echo yes || echo no)" yes
    hasnt 'and the hostname is not claimed to be an IP' \
        "$(openssl x509 -in "$TL/tls/server.crt" -noout -ext subjectAltName 2>/dev/null)" \
        'IP Address'
    rm -rf "$TL"
else
    t_skip 'dufs self-signed certificate (openssl missing)'
fi

section 'a privileged port needs its capability at every start, not once'
# setcap was a firstboot action, which is the wrong shape twice over here. A
# diskless Alpine installs its world packages into a RAM root at every boot, so
# /usr/bin/dufs is a new file each time with no xattrs on it; and a machine
# booted from its committed overlay stops at /etc/spore/.seeded and runs no
# firstboot action at all. Port 443 would have worked on the boot that
# configured the machine and failed on every boot after.
PP=$(mktemp -d /tmp/spore-privport.XXXXXX)
cp -r "$EX" "$PP/s"
sed -i 's/^MODULES=.*/MODULES="dufs"/' "$PP/s/spore.conf"
"$SPORE" -s "$PP/s" set dufs DUFS_PORT 443 >/dev/null 2>&1
alpine "$SPORE" -s "$PP/s" -r "$PP/r" apply >/dev/null 2>&1
PP_INIT=$(cat "$PP/r/etc/init.d/dufs" 2>/dev/null)
has   'the capability is set in start_pre' "$PP_INIT" "setcap 'cap_net_bind_service=+ep'"
has   'and a failure to set it stops the start' "$PP_INIT" 'could not give dufs permission to bind'
# Not as a firstboot action any more: that runs once, and once is not enough.
PPLOG=$(mktemp /tmp/spore-privlog.XXXXXX)
export SPORE_RUN_LOG="$PPLOG"
alpine "$SPORE" -s "$PP/s" -r "$PP/r3" plan > "$PP/plan.out" 2>&1
unset SPORE_RUN_LOG
hasnt 'and not as a one-off firstboot action' "$(cat "$PP/plan.out")" 'dufs-setcap'
# libcap still travels, or setcap is not there to run.
has   'libcap travels with it'                "$(cat "$PP/plan.out")" 'libcap'

# An unprivileged port needs none of it, and the init script stays plain.
"$SPORE" -s "$PP/s" set dufs DUFS_PORT 5000 >/dev/null 2>&1
alpine "$SPORE" -s "$PP/s" -r "$PP/r2" apply >/dev/null 2>&1
hasnt 'an unprivileged port sets no capability' \
    "$(cat "$PP/r2/etc/init.d/dufs" 2>/dev/null)" 'setcap'
rm -rf "$PP" "$PPLOG"

section 'dufs on loopback is indistinguishable from dufs being broken'
# DUFS_BIND defaults to 127.0.0.1, which is a defensible default — enabling a
# module should not open a file server to the network. It is also exactly what a
# broken one looks like: the service starts, rc-service says started, the port
# is open on the machine, and nothing off it connects. Nothing failed, so
# nothing said anything.
DB=$(mktemp -d /tmp/spore-dufsbind.XXXXXX)
cp -r "$EX" "$DB/s"
sed -i 's/^MODULES=.*/MODULES="dufs"/' "$DB/s/spore.conf"
rm -f "$DB/s/modules/dufs.conf"          # enabled with `modules add`, nothing else
DB_LOOP=$(alpine "$SPORE" -s "$DB/s" -r "$DB/r" plan 2>&1)
has 'the default bind is called out'   "$DB_LOOP" 'which is the loopback address'
has 'and what it means in practice'    "$DB_LOOP" 'nothing on the network will reach it'
has 'and what opening it up costs'     "$DB_LOOP" 'DUFS_AUTH_SECRET'
"$SPORE" -s "$DB/s" set dufs DUFS_BIND 0.0.0.0 >/dev/null 2>&1
DB_OPEN=$(alpine "$SPORE" -s "$DB/s" -r "$DB/r2" plan 2>&1)
hasnt 'and nothing to say once it serves the network' "$DB_OPEN" 'loopback address'
# A module that is off is not a file server nobody can reach; it is off.
"$SPORE" -s "$DB/s" set dufs DUFS_BIND 127.0.0.1 >/dev/null 2>&1
"$SPORE" -s "$DB/s" set dufs DUFS_ENABLED no >/dev/null 2>&1
DB_OFF=$(alpine "$SPORE" -s "$DB/s" -r "$DB/r3" plan 2>&1)
hasnt 'nor when the service is disabled' "$DB_OFF" 'loopback address'
rm -rf "$DB"

section 'a service whose deps ran in an earlier runlevel still starts'
# "cannot start dufs as localmount would not start" does not mean localmount is
# down — the boot runlevel ran it minutes earlier. It means localmount is not in
# this runlevel's graph, and OpenRC will not re-enter a finished runlevel, so it
# refuses rather than checks. chronyd hit this on every boot of this machine's
# life, and when dufs hit it the machine served nothing until someone rebooted.
ELSRC=$(cat "$ROOT/lib/exec_live.sh")
has 'a refused start is retried without the check' "$ELSRC" 'rc-service --nodeps "$es_name" start'
# The call, not the word: the comment above it says --nodeps too.
EL_FIRST=$(printf '%s\n' "$ELSRC" | grep -vn '^[[:space:]]*#' |
           grep -n 'rc-service "\$es_name" start' | head -1 | cut -d: -f1)
EL_DEPS=$(printf '%s\n' "$ELSRC" | grep -vn '^[[:space:]]*#' |
          grep -n 'rc-service --nodeps' | head -1 | cut -d: -f1)
if [ -n "$EL_FIRST" ] && [ -n "$EL_DEPS" ] && [ "$EL_FIRST" -lt "$EL_DEPS" ]; then
    t_ok 'and only as a fallback, never the first attempt'
else
    t_fail 'and only as a fallback, never the first attempt' "plain [$EL_FIRST], nodeps [$EL_DEPS]"
fi
# Skipping the check is not the same as the dependency being met, so the start
# is still verified — a daemon that dies immediately must not read as started.
has 'the start is still verified afterwards'  "$ELSRC" 'reported a successful start but is not running'
has 'and it says the check was skipped'       "$ELSRC" 'dependency check skipped'
# The old message told you to wait for a reboot. It is only true now when both
# attempts failed.
has 'the reboot advice survives both failing' "$ELSRC" 'starting it without that check did not work'

section 'try disk: something for STORAGE_AUTO to find'
# Without a second drive the VM has nothing attached that it did not boot from,
# so a boot proves only that the automount did not crash — and the only way to
# test sharing was to plug a real disk into the real machine.
TD=$(mktemp -d /tmp/spore-trydisk.XXXXXX)
TDSRC=$(cat "$ROOT/lib/try.sh")
has 'it attaches a second usb drive'  "$TDSRC" 'drive=sporeextra'
has 'on the same controller as the medium' "$TDSRC" 'bus=xhci.0,drive=sporeextra'
TD_BAD=$(SPORE_TRY_LOG=$TD/log "$SPORE" try /dev/null nonsense 2>&1 || true)
has 'an unknown option still names the real ones' "$TD_BAD" '(write, bootloader, disk, disk=PATH)'
TD_MISS=$("$SPORE" try /dev/null disk=/tmp/definitely-not-here.img 2>&1 || true)
has 'and a disk that is not there is refused' "$TD_MISS" 'no such disk image or device'

if command -v mkfs.ext4 >/dev/null 2>&1; then
    TD_IMG=$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/conf.sh"; . "$ROOT/lib/try.sh"
              SPORE_WORK=$TD; try_scratch_disk "$TD/scratch.img" )
    check 'a scratch disk is made' "$([ -s "$TD_IMG" ] && echo yes || echo no)" yes
    # ext4 and labelled, so blkid on the guest gives the automount a type and a
    # uuid to name it by — an image with no filesystem would simply be skipped.
    check 'with a filesystem on it' "$(blkid -s TYPE -o value "$TD_IMG" 2>/dev/null)" ext4
    check 'and a label that says where it came from' \
        "$(blkid -s LABEL -o value "$TD_IMG" 2>/dev/null)" spore-try
    # And something in it: "it mounted" and "it mounted and there is nothing in
    # it" look identical from the console otherwise.
    if [ "$(id -u)" = 0 ]; then
        mkdir -p "$TD/m"
        if mount -o loop "$TD_IMG" "$TD/m" 2>/dev/null; then
            check 'carrying files you can recognise' \
                "$([ -f "$TD/m/README.txt" ] && [ -f "$TD/m/holiday/beach.jpg" ] &&
                   echo yes || echo no)" yes
            umount "$TD/m"
        else
            t_skip 'scratch disk contents (could not loop-mount here)'
        fi
    fi
else
    t_skip 'scratch disk (mkfs.ext4 missing)'
fi
rm -rf "$TD"

section 'storage: sharing whatever is attached'
# volumes.conf is the declared half — name a disk by UUID and it lands in the
# same place on any machine. That is right for a machine you are describing and
# useless for what a file server is for: plug a disk in, have it appear. This
# half discovers, so it cannot be a plan action (the plan is built on a
# workstation) nor a firstboot one (a machine on its own overlay stops at the
# stamp and applies nothing). It is a service.
AM=$(mktemp -d /tmp/spore-automount.XXXXXX)
cp -r "$EX" "$AM/s"
sed -i 's/^MODULES=.*/MODULES="storage"/' "$AM/s/spore.conf"
"$SPORE" -s "$AM/s" set storage STORAGE_AUTO yes >/dev/null 2>&1
AM_PLAN=$(alpine "$SPORE" -s "$AM/s" -r "$AM/r" plan 2>&1)
has 'it ships a service, not a firstboot action' "$AM_PLAN" 'svc        spore-automount'
has 'and the script it runs'                     "$AM_PLAN" '/usr/local/sbin/spore-automount'
# Serving everything attached is a decision with a blast radius, so it is stated
# rather than assumed.
has 'and says what that means'    "$AM_PLAN" 'includes internal disks and anything plugged in later'
# Whatever turns up has to be mountable, and what turns up is not knowable from
# the workstation.
has 'the filesystem drivers travel with it' "$AM_PLAN" 'exfatprogs'
# Sharing disks a server cannot write to is the failure that costs a boot to
# find: nothing errors, the browser just refuses every upload. The example spore
# sets an owner, so this half has to unset it to see the note at all.
sed -i '/^STORAGE_OWNER=/d' "$AM/s/modules/storage.conf"
AM_NOOWN=$(alpine "$SPORE" -s "$AM/s" -r "$AM/rn" plan 2>&1)
has 'no STORAGE_OWNER is called out at plan time' "$AM_NOOWN" \
    'only root can write to them'
has 'and it names the account to use'             "$AM_NOOWN" 'STORAGE_OWNER=dufs for this one'
"$SPORE" -s "$AM/s" set storage STORAGE_OWNER dufs >/dev/null 2>&1
AM_OWN=$(alpine "$SPORE" -s "$AM/s" -r "$AM/ro" plan 2>&1)
hasnt 'set, and the warning goes away'  "$AM_OWN" 'only root can write to them'
has   'replaced by what it does cover'  "$AM_OWN" 'and only that'
has   'and says the rest is not a setting' "$AM_OWN" 'That is not a setting, on purpose'
# A recursive chown at boot, over whatever happens to be plugged in, rewrites
# disks nobody had in mind when the setting was chosen — irreversibly, with no
# record of what it replaced, every boot. There is no switch for it anywhere.
hasnt 'no switch for it in the plan'    "$AM_OWN" 'STORAGE_OWNER_DEEP'
hasnt 'nor in the module'  "$(cat "$ROOT/modules/storage.sh")" 'STORAGE_OWNER_DEEP'
hasnt 'nor in the wizard'  "$(cat "$ROOT/lib/wizard.sh")"      'STORAGE_OWNER_DEEP'
hasnt 'and chown -R is never run at boot' \
    "$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/conf.sh"; . "$ROOT/lib/plan.sh"
        . "$ROOT/lib/module.sh"; . "$ROOT/modules/storage.sh"
        storage_automount_script /media/storage uuid '' 000 dufs )" 'chown -R "'
# It is spliced into a chown in a generated script, so it is checked here rather
# than written into a script that will not parse — or worse, one that will.
"$SPORE" -s "$AM/s" set storage STORAGE_OWNER "dufs'; rm -rf /" >/dev/null 2>&1
AM_BAD=$(alpine "$SPORE" -s "$AM/s" -r "$AM/rb" plan 2>&1)
has 'an owner that is not an account is refused' "$AM_BAD" 'is not an account name'
has 'and the mounts keep what they had'          "$AM_BAD" 'ownership their disks carry'
# The note quotes the value back, so the plan is not where to look — the script
# that gets written is.
alpine "$SPORE" -s "$AM/s" -r "$AM/rb2" apply >/dev/null 2>&1 || true
AM_BADSH=$(cat "$AM/rb2/usr/local/sbin/spore-automount" 2>/dev/null || echo MISSING)
hasnt 'and none of it reaches the script'        "$AM_BADSH" 'rm -rf /'
has   'which is written with no owner at all'    "$AM_BADSH" "owner=''"
"$SPORE" -s "$AM/s" set storage STORAGE_OWNER dufs >/dev/null 2>&1

AM_OFF=$(alpine "$SPORE" -s "$AM/s" -r "$AM/r2" plan 2>&1)
"$SPORE" -s "$AM/s" set storage STORAGE_AUTO no >/dev/null 2>&1
AM_NONE=$(alpine "$SPORE" -s "$AM/s" -r "$AM/r3" plan 2>&1)
hasnt 'and nothing of it when STORAGE_AUTO is off' "$AM_NONE" 'spore-automount'

# The decisions, against real filesystems on loop devices rather than by reading
# the script.
if [ "$(id -u)" = 0 ] && command -v losetup >/dev/null 2>&1 &&
   command -v mkfs.ext4 >/dev/null 2>&1 && command -v blkid >/dev/null 2>&1; then
    AMR=$AM/run
    mkdir -p "$AMR"
    ( . "$ROOT/lib/core.sh"; . "$ROOT/lib/conf.sh"; . "$ROOT/lib/plan.sh"
      . "$ROOT/lib/module.sh"; . "$ROOT/modules/storage.sh"
      printf '#!/bin/sh\nset -u\n'
      storage_automount_script "$AMR/root" uuid 'skipme' 000 '' ) > "$AM/am.sh"
    chmod 755 "$AM/am.sh"

    for n in data mine skipme busy; do
        dd if=/dev/zero of="$AM/$n.img" bs=1M count=8 status=none 2>/dev/null
        mkfs.ext4 -q -L "$n" "$AM/$n.img"
    done
    # No label, which is what a disk you formatted and never named looks like —
    # and the shape that a bug lived in until a real machine shared nothing.
    dd if=/dev/zero of="$AM/bare.img" bs=1M count=8 status=none 2>/dev/null
    mkfs.ext4 -q "$AM/bare.img"
    # No filesystem at all: eight megabytes of zeros.
    dd if=/dev/zero of="$AM/empty.img" bs=1M count=8 status=none 2>/dev/null
    # A partition table and nothing else, which blkid answers with a PTTYPE and
    # no TYPE — a disk that has been partitioned but never formatted.
    dd if=/dev/zero of="$AM/ptonly.img" bs=1M count=8 status=none 2>/dev/null
    printf '\125\252' | dd of="$AM/ptonly.img" bs=1 seek=510 conv=notrunc status=none 2>/dev/null
    printf '\200\040\041\000\203\020\202\020\000\010\000\000\000\070\000\000' |
        dd of="$AM/ptonly.img" bs=1 seek=446 conv=notrunc status=none 2>/dev/null

    AM_D=$(losetup --show -f "$AM/data.img")
    AM_M=$(losetup --show -f "$AM/mine.img")
    AM_X=$(losetup --show -f "$AM/skipme.img")
    AM_B=$(losetup --show -f "$AM/bare.img")
    AM_E=$(losetup --show -f "$AM/empty.img")
    AM_P=$(losetup --show -f "$AM/ptonly.img")
    AM_U=$(losetup --show -f "$AM/busy.img")
    # A disk that arrives with somebody else's directories on it.
    dd if=/dev/zero of="$AM/full.img" bs=1M count=8 status=none 2>/dev/null
    mkfs.ext4 -q "$AM/full.img"
    AM_FU=$(losetup --show -f "$AM/full.img")
    mkdir -p "$AM/tmp2" && mount "$AM_FU" "$AM/tmp2" &&
        mkdir -p "$AM/tmp2/holiday" && umount "$AM/tmp2"
    mkdir -p "$AM/tmp"
    mount "$AM_M" "$AM/tmp" && mkdir -p "$AM/tmp/spore" &&
        printf 'FORMAT=1\n' > "$AM/tmp/spore/spore.conf" &&
        printf 'KEY\n' > "$AM/tmp/identity" && umount "$AM/tmp"
    # Mounted before the run, the way the initramfs mounts the boot medium.
    mkdir -p "$AM/busy" && mount "$AM_U" "$AM/busy"

    AM_OUT=$(SPORE_AUTOMOUNT_DEVS="$AM_D $AM_M $AM_X $AM_B $AM_E $AM_P $AM_U" sh "$AM/am.sh" 2>&1)
    AM_UU=$(blkid -s UUID -o value "$AM_D")
    AM_BU=$(blkid -s UUID -o value "$AM_B")
    check 'an attached disk is shared, named by its uuid' \
        "$([ -d "$AMR/root/$AM_UU" ] && echo yes || echo no)" yes
    # The regression. STORAGE_AUTO_EXCLUDE tested inline expanded to *"  "* for a
    # disk with no LABEL, which matched the two spaces an empty exclude list is,
    # so every unlabelled filesystem excluded itself — in silence.
    check 'a disk with no label is shared too'  \
        "$([ -d "$AMR/root/$AM_BU" ] && echo yes || echo no)" yes
    # The one check that does not depend on the initramfs having mounted this
    # machine's own partitions first. Getting it wrong puts the spore's identity
    # file on a web server.
    has   'a disk carrying a spore is refused'  "$AM_OUT" "carries a spore or an apkovl"
    check 'and is left unmounted'               "$(awk -v d="$AM_M" '$1 == d { print "mounted" }' /proc/mounts)" ''
    # By label, because that is what STORAGE_AUTO_EXCLUDE takes as well as a
    # device or a uuid.
    hasnt 'an excluded volume is never shared'  "$AM_OUT" "sharing $AM_X"
    check 'and not mounted'                     "$(awk -v d="$AM_X" '$1 == d { print "mounted" }' /proc/mounts)" ''

    # Every skip accounts for itself. A run that shares nothing was indist-
    # inguishable from a run that never looked, and cost several boots of a real
    # machine to tell apart.
    has 'an exclusion says it was an exclusion' "$AM_OUT" \
        "$AM_X is named in STORAGE_AUTO_EXCLUDE"
    has 'a disk with no filesystem says so'     "$AM_OUT" \
        "$AM_E has no filesystem blkid recognises"
    # Partitioned but never formatted is the same skip for a different reason, so
    # it repeats back what blkid did answer rather than leaving you to run it.
    has 'and shows what blkid did say'          "$AM_OUT" "blkid said: $AM_P: PTTYPE=\"dos\""
    has 'one this machine is using says where'  "$AM_OUT" "$AM_U is mounted at $AM/busy"
    hasnt 'and does not call that sharing'      "$AM_OUT" "sharing $AM_U"
    has 'and the run totals what it did'        "$AM_OUT" 'looked at 7 device(s), shared 2'

    for m in "$AMR/root"/*; do
        # A leftover empty directory from an earlier pass is not a mountpoint,
        # and umount exits 32 on one — which under set -eu ends the suite.
        [ ! -d "$m" ] || umount "$m" 2>/dev/null || true
    done

    # With nothing excluded at all, which is the default and the configuration
    # the real machine was running.
    ( . "$ROOT/lib/core.sh"; . "$ROOT/lib/conf.sh"; . "$ROOT/lib/plan.sh"
      . "$ROOT/lib/module.sh"; . "$ROOT/modules/storage.sh"
      printf '#!/bin/sh\nset -u\n'
      storage_automount_script "$AMR/two" uuid '' 000 '' ) > "$AM/am2.sh"
    AM_OUT2=$(SPORE_AUTOMOUNT_DEVS="$AM_D $AM_B" sh "$AM/am2.sh" 2>&1)
    has 'no exclusions excludes nothing'    "$AM_OUT2" "sharing $AM_B"
    has 'the labelled one included'         "$AM_OUT2" "sharing $AM_D"
    hasnt 'and nothing claims an exclusion' "$AM_OUT2" 'STORAGE_AUTO_EXCLUDE'
    for m in "$AMR/two"/*; do
        # A leftover empty directory from an earlier pass is not a mountpoint,
        # and umount exits 32 on one — which under set -eu ends the suite.
        [ ! -d "$m" ] || umount "$m" 2>/dev/null || true
    done

    # A second pass over what it already shared is a no-op that says so, rather
    # than an error or a silent one. It also must not call a disk it is itself
    # serving one the machine booted from, which is what "already mounted" meant
    # before there was a second pass to read.
    AM_OUT3=$(SPORE_AUTOMOUNT_DEVS="$AM_D" sh "$AM/am.sh" 2>&1)
    has 'the first pass shares it'      "$AM_OUT3" "sharing $AM_D"
    AM_OUT4=$(SPORE_AUTOMOUNT_DEVS="$AM_D" sh "$AM/am.sh" 2>&1)
    has 'a second pass says it is shared already' "$AM_OUT4" \
        "$AM_D is shared already, at $AMR/root/$AM_UU"
    hasnt 'not that the machine is using it'      "$AM_OUT4" 'this machine is using it'
    has 'and it still counts as shared'           "$AM_OUT4" 'looked at 1 device(s), shared 1'
    for m in "$AMR/root"/*; do
        # A leftover empty directory from an earlier pass is not a mountpoint,
        # and umount exits 32 on one — which under set -eu ends the suite.
        [ ! -d "$m" ] || umount "$m" 2>/dev/null || true
    done

    # Nothing attached is its own answer, not an empty one.
    AM_OUT5=$(SPORE_AUTOMOUNT_DEVS="/dev/spore-no-such-device" sh "$AM/am.sh" 2>&1)
    has 'no device at all says that'   "$AM_OUT5" 'no block device matched at all'
    has 'and names what it looks at'   "$AM_OUT5" 'nvme* and mmcblk*'

    # Ownership. A server running as its own account cannot write to a disk
    # owned by root, so "the server allows uploads" and "an upload lands" are
    # two different settings — and nothing errors when only the first is set.
    ( . "$ROOT/lib/core.sh"; . "$ROOT/lib/conf.sh"; . "$ROOT/lib/plan.sh"
      . "$ROOT/lib/module.sh"; . "$ROOT/modules/storage.sh"
      printf '#!/bin/sh\nset -u\n'
      storage_automount_script "$AMR/own" uuid '' 000 nobody ) > "$AM/am3.sh"
    AM_OUT6=$(SPORE_AUTOMOUNT_DEVS="$AM_D" sh "$AM/am3.sh" 2>&1)
    has   'a shared disk is handed to STORAGE_OWNER' "$AM_OUT6" '-> nobody'
    # A chown with no record of what it replaced is the part that makes one hard
    # to undo, and this one runs unattended.
    has   'and the line says what it replaced'       "$AM_OUT6" 'owner root:root ->'
    check 'the mount point really changes hands' \
        "$(stat -c '%U' "$AMR/own/$AM_UU" 2>/dev/null)" nobody
    check 'and nothing under it does' \
        "$(stat -c '%U' "$AMR/own/$AM_UU/lost+found" 2>/dev/null)" root
    for m in "$AMR/own"/*; do
        [ ! -d "$m" ] || umount "$m" 2>/dev/null || true
    done

    # A disk that arrives with directories on it. There is no setting that takes
    # them over, because this runs on every boot against whatever is attached: a
    # recursive chown here rewrites disks nobody had in mind, with no record of
    # what it replaced. So it says so and hands over the command.
    AM_OUT8=$(SPORE_AUTOMOUNT_DEVS="$AM_FU" sh "$AM/am3.sh" 2>&1)
    AM_FUU=$(blkid -s UUID -o value "$AM_FU")
    has 'a disk that came with data says so'    "$AM_OUT8" \
        'came with directories nobody does not own'
    has 'and names one of them'                 "$AM_OUT8" 'starting'
    has 'and hands over the one-off command'    "$AM_OUT8" \
        "chown -Rh nobody $AMR/own/$AM_FUU"
    # -h, because without it busybox chown follows a symlink and changes its
    # target: it only picks lchown inside an IF_DESKTOP branch, and a recursive
    # chown as root over media somebody else formatted should not rest on a
    # dependency's build flag.
    hasnt 'never a bare chown -R'               "$AM_OUT8" 'chown -R nobody'
    check 'and it really did not touch the tree' \
        "$(stat -c '%U' "$AMR/own/$AM_FUU/holiday" 2>/dev/null)" root
    for m in "$AMR/own"/*; do
        [ ! -d "$m" ] || umount "$m" 2>/dev/null || true
    done

    # A filesystem that cannot hold ownership must not be chowned: the umask on
    # the mount is what grants access there, and the chown would fail for a real
    # reason and read as a fault.
    if command -v mkfs.vfat >/dev/null 2>&1; then
        dd if=/dev/zero of="$AM/fat.img" bs=1M count=8 status=none 2>/dev/null
        mkfs.vfat -n FATDISK "$AM/fat.img" >/dev/null 2>&1
        AM_F=$(losetup --show -f "$AM/fat.img")
        AM_OUT7=$(SPORE_AUTOMOUNT_DEVS="$AM_F" sh "$AM/am3.sh" 2>&1)
        hasnt 'a vfat disk is never chowned' "$AM_OUT7" 'could not chown'
        has   'it is shared all the same'    "$AM_OUT7" "sharing $AM_F (vfat)"
        for m in "$AMR/own"/*; do
            [ ! -d "$m" ] || umount "$m" 2>/dev/null || true
        done
        losetup -d "$AM_F" 2>/dev/null || true
    else
        t_skip 'vfat is not chowned (mkfs.vfat missing)'
    fi

    # A read-only mount looks, from a browser, exactly like a server that was
    # never told to accept uploads. It says which it is.
    AM_SRC_RO=$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/conf.sh"; . "$ROOT/lib/plan.sh"
                 . "$ROOT/lib/module.sh"; . "$ROOT/modules/storage.sh"
                 storage_automount_script /media/storage uuid '' 000 dufs )
    has 'a read-only mount is called out' "$AM_SRC_RO" 'is mounted READ-ONLY'
    has 'and says the server cannot help' "$AM_SRC_RO" \
        'whatever the server is configured to allow'

    umount "$AM/busy" 2>/dev/null
    losetup -d "$AM_D" "$AM_M" "$AM_X" "$AM_B" "$AM_E" "$AM_P" "$AM_U" "$AM_FU" 2>/dev/null || true
else
    t_skip 'automount against real filesystems (needs root, losetup, mkfs.ext4)'
fi
# The partitioned-disk branch needs a partition table to exercise, so its
# message is checked in the script it generates rather than against a loop
# device — the point being that it has one at all.
AM_SRC=$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/conf.sh"; . "$ROOT/lib/plan.sh"
          . "$ROOT/lib/module.sh"; . "$ROOT/modules/storage.sh"
          storage_automount_script /media/storage uuid '' 000 '' )
has 'a partitioned whole disk says why it was passed over' "$AM_SRC" \
    'echo "spore: $dev is partitioned, so its partitions were the"'
has 'and it leaves the device loop, not just the partition scan' "$AM_SRC" \
    'continue 2'
rm -rf "$AM"

section 'desktop: a graphical machine, planned rather than shelled out to'
# Alpine ships setup-desktop and this does not call it: its exit status is that
# of a trailing `rc-update del acpid`, it reaches scripts that rc-service-start
# sysinit services (which OpenRC refuses from the default runlevel, where this
# always runs), and with no argument it prompts. So upstream's package sets are
# mirrored into plan actions, which also means the whole desktop is visible
# before any of it exists.
DK=$(mktemp -d /tmp/spore-desktop.XXXXXX)
cp -r "$EX" "$DK/s"
sed -i 's/^MODULES=.*/MODULES="users desktop"/' "$DK/s/spore.conf"
"$SPORE" -s "$DK/s" set desktop DESKTOP_ENV xfce >/dev/null 2>&1
DK_XFCE=$(alpine "$SPORE" -s "$DK/s" -r "$DK/r" plan 2>&1)
has 'xorg comes from setup-xorg-base'   "$DK_XFCE" 'pkg        xorg-server'
has 'with the libinput driver'          "$DK_XFCE" 'pkg        xf86-input-libinput'
has 'the environment itself'            "$DK_XFCE" 'pkg        xfce4'
has 'and a greeter to reach it through' "$DK_XFCE" 'svc        lightdm -> default [on]'
# setup-xorg-base and setup-wayland-base both end in `setup-devd udev`, because
# Xorg's libinput driver and elogind's seats both want it. A diskless Alpine
# boots with mdev.
has 'the device manager moves to udev'  "$DK_XFCE" 'svc        udev -> sysinit [on]'
has 'and mdev is stood down'            "$DK_XFCE" 'svc        mdev -> sysinit [off]'
has 'with hwdrivers, which was its job' "$DK_XFCE" 'svc        hwdrivers -> sysinit [off]'
# sysinit ran long before this did, so none of it is live until a reboot. A
# first boot that ends at a text console has worked, and saying so is cheaper
# than the message that says it did not.
has 'and says none of that is live yet' "$DK_XFCE" 'come up on the *next* boot'
# Nothing is executed on the workstation and no setup-* script is invoked on the
# machine either: every line of it is an action.
hasnt 'setup-desktop is never called'   "$DK_XFCE" 'setup-desktop'
hasnt 'nor setup-xorg-base'             "$DK_XFCE" 'setup-xorg-base'

# A browser is a large package and not everyone wants that one. Upstream's
# ${BROWSER:-firefox} cannot express leaving it out.
has 'a browser is installed by default' "$DK_XFCE" 'pkg        firefox'
"$SPORE" -s "$DK/s" set desktop DESKTOP_BROWSER none >/dev/null 2>&1
DK_NOBR=$(alpine "$SPORE" -s "$DK/s" -r "$DK/rb" plan 2>&1)
hasnt 'and none leaves it out'          "$DK_NOBR" 'pkg        firefox'
"$SPORE" -s "$DK/s" set desktop DESKTOP_BROWSER firefox >/dev/null 2>&1

# The groups are the difference between a desktop and a desktop nobody can open:
# adduser -D puts an account in none of them.
has 'the desktop account joins the seat groups' "$DK_XFCE" 'video, input, audio, netdev and'
has 'named from users.conf, not asked twice'    "$DK_XFCE" '(from users.conf)'
has 'and it is a firstboot action'              "$DK_XFCE" 'firstboot  desktop-groups'

# Firstboot actions run in MODULES order and `adduser <user> <group>` needs the
# account to exist. Listed the wrong way round nothing fails on the machine: the
# desktop installs and refuses the only account meant to use it. On a diskless
# box there is no second chance, because firstboot stamps live on the RAM root
# and none of them run once it is on its own overlay.
sed -i 's/^MODULES=.*/MODULES="desktop users"/' "$DK/s/spore.conf"
DK_ORDER=$(alpine "$SPORE" -s "$DK/s" -r "$DK/ro" plan 2>&1 || true)
has 'desktop before users is refused'    "$DK_ORDER" 'MODULES lists desktop before users'
has 'and it says what would have gone wrong' "$DK_ORDER" 'refuse the one account meant to use it'
has 'and prints the line to paste'       "$DK_ORDER" 'MODULES="users desktop"'
sed -i 's/^MODULES=.*/MODULES="users desktop"/' "$DK/s/spore.conf"

# The fact that decides whether a diskless desktop is a good idea. Alpine's
# initramfs re-reads world out of the apkovl and apk-adds every line of it into
# the tmpfs root on every boot — a handful of packages for a file server, the
# entire desktop for this.
has 'the diskless cost is stated at plan time' "$DK_XFCE" 'into the RAM root at every boot'
has 'both halves of it, with both fixes'       "$DK_XFCE" 'REPOS_APK_CACHE'
has 'and the memory half'                      "$DK_XFCE" 'sits in tmpfs for as long as'
# An environment name is not a package name, and a command nobody can paste is
# worse than no command.
has 'with a package name that exists'          "$DK_XFCE" 'apk add --simulate xfce4'
DK_VM=$(env SPORE_FACT_INIT=openrc SPORE_FACT_NETADMIN=yes SPORE_FACT_PERSIST=rootfs \
            SPORE_FACT_ARCH=x86_64 SPORE_FACT_ROOT=yes SPORE_FACT_ALPINE=3.20.0 \
            "$SPORE" -s "$DK/s" -r "$DK/rv" plan 2>&1)
hasnt 'and not said at all on a host with a disk' "$DK_VM" 'into the RAM root at every boot'

# gnome and plasma are much the largest, and upstream builds their package list
# on the target with `apk info --depends`, which a plan made on a workstation
# cannot do.
"$SPORE" -s "$DK/s" set desktop DESKTOP_ENV gnome >/dev/null 2>&1
DK_GN=$(alpine "$SPORE" -s "$DK/s" -r "$DK/rg" plan 2>&1)
has 'gnome plans its meta-packages'   "$DK_GN" 'pkg        gnome'
has 'and its greeter'                 "$DK_GN" 'svc        gdm -> default [on]'
has 'and says it is the expensive one' "$DK_GN" 'much the largest'
has 'with a simulate line that matches' "$DK_GN" 'apk add --simulate gnome'

# sway has no display manager upstream and none here, which is worth saying:
# a machine that boots to a text console is otherwise indistinguishable from a
# broken one.
"$SPORE" -s "$DK/s" set desktop DESKTOP_ENV sway >/dev/null 2>&1
DK_SW=$(alpine "$SPORE" -s "$DK/s" -r "$DK/rs" plan 2>&1)
has   'sway is planned'                 "$DK_SW" 'pkg        sway'
has   'on the wayland base'             "$DK_SW" 'pkg        elogind'
hasnt 'with no display manager'         "$DK_SW" 'svc        lightdm'
has   'and it says so'                  "$DK_SW" 'sway has no display manager'

# An unknown environment is a typo, and it is knowable here.
"$SPORE" -s "$DK/s" set desktop DESKTOP_ENV kde >/dev/null 2>&1
DK_BAD=$(alpine "$SPORE" -s "$DK/s" -r "$DK/rx" plan 2>&1 || true)
has 'an unknown environment is refused' "$DK_BAD" "not 'kde'"
has 'and the message lists the real ones' "$DK_BAD" 'xfce xfce-wayland gnome plasma mate sway lxqt'
rm -rf "$DK"

section 'MOD_DATA: a module payload on the RAM root does not outlast the boot'
# Declared by two modules and read by none. It matters most on exactly the host
# this tool is for: a diskless Alpine is a RAM root, so dufs serving its default
# /var/lib/dufs accepts uploads all day and has none of them in the morning —
# and nothing reports it, because writing to it works.
MDATA=$(mktemp -d /tmp/spore-moddata.XXXXXX)
cp -r "$EX" "$MDATA/s"
sed -i 's/^MODULES=.*/MODULES="dufs"/' "$MDATA/s/spore.conf"
"$SPORE" -s "$MDATA/s" set dufs DUFS_SERVE /var/lib/dufs >/dev/null 2>&1
MDATA_RAM=$(alpine "$SPORE" -s "$MDATA/s" -r "$MDATA/r" plan 2>&1)
has 'a RAM-root payload is called out' "$MDATA_RAM" 'is on the RAM root of a diskless host'
"$SPORE" -s "$MDATA/s" set dufs DUFS_SERVE /media/storage/files >/dev/null 2>&1
MDATA_OK=$(alpine "$SPORE" -s "$MDATA/s" -r "$MDATA/r" plan 2>&1)
hasnt 'one on a mounted filesystem is not' "$MDATA_OK" 'is on the RAM root'
# And nothing to say on a host with a disk, where /var/lib is simply /var/lib.
"$SPORE" -s "$MDATA/s" set dufs DUFS_SERVE /var/lib/dufs >/dev/null 2>&1
MDATA_DISK=$(env SPORE_FACT_INIT=openrc SPORE_FACT_NETADMIN=yes SPORE_FACT_PERSIST=rootfs \
    SPORE_FACT_ARCH=x86_64 SPORE_FACT_ROOT=yes SPORE_FACT_ALPINE=3.20.0 \
    "$SPORE" -s "$MDATA/s" -r "$MDATA/r" plan 2>&1)
hasnt 'and a host with a disk is left alone' "$MDATA_DISK" 'is on the RAM root'
rm -rf "$MDATA"

section 'spore set: a module setting, checked'
# The conf files are the format and stay authoritative — they are meant to be
# read, diffed and committed. What a command adds is the checking: a module that
# does not exist, one that is not in MODULES and so reads nothing, and a value
# that does not survive the round trip. All three are silent in an editor, and
# the last one is silent until a boot.
ST=$(mktemp -d /tmp/spore-set.XXXXXX)
cp -r "$EX" "$ST/s"

"$SPORE" -s "$ST/s" set net NET_DNS 1.1.1.1 >/dev/null 2>&1
check 'it sets a value' "$(conf_read "$ST/s/modules/net.conf" NET_DNS)" '1.1.1.1'
# Quoted on the way out, because a resolver list is two words and an unquoted
# one would read back as the first.
"$SPORE" -s "$ST/s" set net NET_DNS "1.1.1.1 1.0.0.1" >/dev/null 2>&1
check 'and a value with spaces survives' \
    "$(conf_read "$ST/s/modules/net.conf" NET_DNS)" '1.1.1.1 1.0.0.1'
ST_AGAIN=$("$SPORE" -s "$ST/s" set net NET_DNS 9.9.9.9 2>&1)
has 'a change says what it replaced' "$ST_AGAIN" '1.1.1.1 1.0.0.1 -> 9.9.9.9'

# sed's replacement text treats \ and & specially, and every caller before this
# passed a hostname or a keymap. This one passes whatever was typed at it.
"$SPORE" -s "$ST/s" set net NET_DNS 'a&b\c|d' >/dev/null 2>&1
check 'sed metacharacters come back as themselves' \
    "$(conf_read "$ST/s/modules/net.conf" NET_DNS)" 'a&b\c|d'
"$SPORE" -s "$ST/s" set net NET_DNS 1.1.1.1 >/dev/null 2>&1

ST_NOMOD=$("$SPORE" -s "$ST/s" set nosuch KEY v 2>&1 || true)
has 'a module that does not exist is refused' "$ST_NOMOD" "no module called 'nosuch'"
ST_BADK=$("$SPORE" -s "$ST/s" set net 'not a key' v 2>&1 || true)
has 'and so is a key that is not one'         "$ST_BADK" 'not a config key'
ST_NL=$("$SPORE" -s "$ST/s" set net NET_DNS "$(printf 'a\nb')" 2>&1 || true)
has 'and a value that spans lines'            "$ST_NL" 'a value is one line'
ST_USAGE=$("$SPORE" -s "$ST/s" set net NET_DNS 2>&1 || true)
has 'it takes three words'                    "$ST_USAGE" 'usage: spore set MODULE KEY VALUE'

# A module that is off reads nothing, so the setting is written and said to be
# inert rather than quietly doing nothing.
ST_OFF=$("$SPORE" -s "$ST/s" set system SYSTEM_TIMEZONE UTC 2>&1)
has 'a module not in MODULES is called out' "$ST_OFF" 'is not in MODULES'
check 'but the setting is still written' \
    "$(conf_read "$ST/s/modules/system.conf" SYSTEM_TIMEZONE)" 'UTC'

ST_DRY=$("$SPORE" -n -s "$ST/s" set net NET_DNS 8.8.8.8 2>&1)
has   'a dry run says what it would do' "$ST_DRY" 'would set NET_DNS=8.8.8.8'
check 'and changes nothing'             "$(conf_read "$ST/s/modules/net.conf" NET_DNS)" '1.1.1.1'
rm -rf "$ST"

section 'spore passwd: one command, not a pipeline with a flag to remember'
# `openssl passwd -6 | spore -s <spore> seal root.password` was the documented
# way to set a password on a spore that already existed: a pipeline, a flag, and
# a silent lockout if you forgot the flag.
if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1 &&
   command -v openssl >/dev/null 2>&1; then
    PW=$(mktemp -d /tmp/spore-passwd.XXXXXX)
    cp -r "$EX" "$PW/s"
    mkdir -p "$PW/s/secrets"
    age-keygen -o "$PW/identity" 2>"$PW/pub"
    sed -n 's/^Public key: //p' "$PW/pub" > "$PW/s/secrets/recipients"

    # Piped rather than typed: a script gets one line from stdin, and the
    # plaintext still never becomes an argument anyone can see in ps.
    printf 'hunter2\n' | "$SPORE" -s "$PW/s" passwd root >/dev/null 2>&1
    check 'it seals a password for root' \
        "$([ -f "$PW/s/secrets/root.password.age" ] && echo yes || echo no)" yes
    # What comes out has to be a hash, because chpasswd -e writes it into
    # /etc/shadow verbatim — the plaintext would be an account nobody can use.
    PW_OUT=$(age --decrypt -i "$PW/identity" "$PW/s/secrets/root.password.age")
    case $PW_OUT in
        '$6$'*) t_ok 'and what is sealed is a hash, not the password' ;;
        *)      t_fail 'and what is sealed is a hash, not the password' "got [$PW_OUT]" ;;
    esac
    hasnt 'the plaintext is nowhere in it' "$PW_OUT" 'hunter2'
    # And the machine can actually use it: the same password must verify
    # against the hash that travelled.
    check 'and the password verifies against it' \
        "$(openssl passwd -6 -salt "$(printf '%s' "$PW_OUT" | cut -d'$' -f3)" hunter2)" \
        "$PW_OUT"

    # A name nothing applies is a password that silently does not exist.
    PW_TYPO=$(printf 'x\n' | "$SPORE" -s "$PW/s" passwd guiprada 2>&1 || true)
    has 'a name not in USERS is called out' "$PW_TYPO" 'neither root nor in USERS'

    PW_USAGE=$("$SPORE" -s "$PW/s" passwd 2>&1 || true)
    has 'and it needs to be told who'       "$PW_USAGE" 'usage: spore passwd USER'

    # Nothing on stdin is not an empty password, it is no answer at all.
    printf '' | "$SPORE" -s "$PW/s" passwd root >/dev/null 2>&1 &&
        t_fail 'an empty answer seals nothing' 'it returned success' ||
        t_ok 'an empty answer seals nothing'
    rm -rf "$PW"
else
    t_skip 'spore passwd (age, age-keygen or openssl missing)'
fi

section 'a sealed password is a hash, and seal says so'
# The firstboot action feeds it to `chpasswd -e`, which writes its input into
# /etc/shadow verbatim. Seal the plaintext by mistake and the account gets a
# field no password matches — not an error, just an account nobody can log into,
# found out at a console on a machine that is by then the only copy of itself.
if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1 &&
   command -v openssl >/dev/null 2>&1; then
    SP=$(mktemp -d /tmp/spore-sealpw.XXXXXX)
    cp -r "$EX" "$SP/s"
    mkdir -p "$SP/s/secrets"
    age-keygen -o "$SP/identity" 2>"$SP/pub"
    sed -n 's/^Public key: //p' "$SP/pub" > "$SP/s/secrets/recipients"

    SP_NO=$(printf 'hunter2\n' | "$SPORE" -s "$SP/s" seal root.password 2>&1 || true)
    has   'a plaintext password is refused'   "$SP_NO" 'must hold a password *hash*'
    has   'with the command that makes one'   "$SP_NO" 'passwd root'
    check 'and nothing is written' \
        "$([ -f "$SP/s/secrets/root.password.age" ] && echo yes || echo no)" no

    SP_HASH=$(openssl passwd -6 -salt spore hunter2)
    printf '%s\n' "$SP_HASH" | "$SPORE" -s "$SP/s" seal root.password >/dev/null 2>&1
    check 'a hash is sealed' \
        "$([ -f "$SP/s/secrets/root.password.age" ] && echo yes || echo no)" yes
    # Byte for byte: chpasswd -e is given whatever comes back out, so a stray
    # newline or a truncated field is a locked account just the same.
    check 'and comes back out unchanged' \
        "$(age --decrypt -i "$SP/identity" "$SP/s/secrets/root.password.age")" "$SP_HASH"

    # Only passwords. Every other secret is arbitrary bytes and must not be
    # second-guessed — a TLS key does not start with $6$.
    printf 'not a hash at all\n' | "$SPORE" -s "$SP/s" seal tls.key >/dev/null 2>&1
    check 'other secrets are sealed as they are' \
        "$(age --decrypt -i "$SP/identity" "$SP/s/secrets/tls.key.age" 2>/dev/null)" \
        'not a hash at all'
    rm -rf "$SP"
else
    t_skip 'sealed-password checks (age, age-keygen or openssl missing)'
fi

section 'root without a password is not root without a way in'
# A stock diskless Alpine leaves root's field in /etc/shadow empty, and an empty
# field is a password — the console takes a bare Enter. The spore would seal a
# password for its user, enable sshd, refuse root over ssh, and leave the
# machine open to anyone standing in front of it.
RL=$(mktemp -d /tmp/spore-rootlock.XXXXXX)
cp -r "$EX" "$RL/s"
RLPLAN() { alpine "$SPORE" --spore "$RL/s" --root "$RL/r" plan 2>&1; }

# No sealed password for the doas admin: `permit persist` prompts for a password
# the account has not got, so locking root would strand the machine.
RL_NONE=$(RLPLAN)
hasnt 'root is not locked when nothing else can become it' "$RL_NONE" 'users-root-lock'
has   'and it says why, and what would change it'          "$RL_NONE" 'sealed password'

# With one, doas is a real way back and root gets locked.
mkdir -p "$RL/s/secrets"
printf 'ciphertext\n' > "$RL/s/secrets/gui.password.age"
RL_SEALED=$(RLPLAN)
has 'a sealed admin password is a way back, so root is locked' "$RL_SEALED" 'users-root-lock'

# nopass is the other way back: no password needed, so the rule always works.
rm -f "$RL/s/secrets/gui.password.age"
printf 'USERS_DOAS_NOPASS=yes\n' >> "$RL/s/modules/users.conf"
RL_NOPASS=$(RLPLAN)
has 'as is doas without a password' "$RL_NOPASS" 'users-root-lock'
sed -i '/USERS_DOAS_NOPASS=yes/d' "$RL/s/modules/users.conf"

# A sealed root password is a deliberate answer to the same question.
mkdir -p "$RL/s/secrets"
printf 'ciphertext\n' > "$RL/s/secrets/root.password.age"
RL_ROOT=$(RLPLAN)
hasnt 'a sealed root password locks nothing'  "$RL_ROOT" 'users-root-lock'
has   'it sets one instead'                   "$RL_ROOT" 'user-root-password'
rm -f "$RL/s/secrets/root.password.age"

# And it can be turned off, because locking root is the kind of thing that is
# someone else's call on someone else's machine.
printf 'ciphertext\n' > "$RL/s/secrets/gui.password.age"
printf 'USERS_ROOT_LOCK=no\n' >> "$RL/s/modules/users.conf"
RL_OFF=$(RLPLAN)
hasnt 'USERS_ROOT_LOCK=no leaves it alone' "$RL_OFF" 'users-root-lock'
has   'and says what that means'           "$RL_OFF" 'Anyone at the console is root'
rm -rf "$RL"

section 'a resolver that is named is not a resolver that answers'
# Twelve boots logged "DNS: transient error" against the mirror while the report
# above them said "resolvers: 172.16.100.1" and stopped there. The gateway gets
# written in as the resolver as a matter of course and routinely does not serve
# DNS; apk is then the only thing that mentions it, and it blames the mirror.
NRSRC=$( . "$ROOT/lib/core.sh"; . "$ROOT/lib/render.sh"; render_net_report )
has 'the report asks the resolver a question' "$NRSRC" '$netq alpinelinux.org'
has 'and is bounded, like everything at boot' "$NRSRC" 'timeout 10 nslookup'
has 'a working one is said so'                "$NRSRC" 'and they resolve names'
has 'and a silent one names the setting'      "$NRSRC" 'Set NET_DNS in modules/net.conf'
has 'and says what it will look like instead' "$NRSRC" 'as a problem with the mirror'

section 'spore retire: handing the machine over to its own overlay'
# The counterpart to the second seed `install` writes on the boot partition.
# Once the machine has committed, that copy stops being insurance and starts
# competing: two apkovls means the initramfs picks by probe order.
RET=$(mktemp -d /tmp/spore-retire.XXXXXX)
mkdir -p "$RET/data" "$RET/boot"
printf 'seed\n' > "$RET/data/spore-seed.apkovl.tar.gz"
printf 'seed\n' > "$RET/boot/spore-seed.apkovl.tar.gz"

# Refused while the seed is the only thing that can boot the machine. Retiring
# it here leaves the medium with no apkovl at all, and the box comes up as blank
# Alpine with nothing on it to say why.
RET_E=$("$SPORE" retire "$RET/data" "$RET/boot" 2>&1 || true)
has   'it refuses before anything is committed' "$RET_E" 'no committed overlay'
check 'and the seed is untouched' \
    "$([ -f "$RET/data/spore-seed.apkovl.tar.gz" ] && echo yes || echo no)" yes

printf 'overlay\n' > "$RET/data/coisas.apkovl.tar.gz"
RET_N=$("$SPORE" -n retire "$RET/data" "$RET/boot" 2>&1)
has   'a dry run says what it would do' "$RET_N" 'would retire'
check 'and does not do it' \
    "$([ -f "$RET/boot/spore-seed.apkovl.tar.gz" ] && echo yes || echo no)" yes

RET_O=$("$SPORE" retire "$RET/data" "$RET/boot" 2>&1)
# Both partitions: re-running `install` after a commit puts a live seed back on
# the data partition too, so retiring only the boot copy still leaves two.
check 'the boot-partition seed is retired' \
    "$([ -f "$RET/boot/spore-seed.apkovl.tar.gz" ] && echo yes || echo no)" no
check 'and the data-partition one as well' \
    "$([ -f "$RET/data/spore-seed.apkovl.tar.gz" ] && echo yes || echo no)" no
check 'renamed, not deleted' \
    "$(cat "$RET/boot/spore-seed.superseded.tar.gz" 2>/dev/null)" seed
check 'and the committed overlay is left alone' \
    "$(cat "$RET/data/coisas.apkovl.tar.gz" 2>/dev/null)" overlay
RET_LEFT=$(cd "$RET/boot" && ls -1 ./*.apkovl.tar.gz* 2>/dev/null | tr '\n' ' ')
check 'nothing the initramfs globs is left on the boot partition' "${RET_LEFT:-none}" none
has   'it says what the next boot should look like' "$RET_O" 'already converged'
has   'and how to undo it'                          "$RET_O" 'spore install'

# Running it twice is not an error: the medium is simply already handed over.
RET_T=$("$SPORE" retire "$RET/data" "$RET/boot" 2>&1)
has   'a second run is a no-op, and says so' "$RET_T" 'already handed over'

# `retire` overwrites the seed the commit set aside, which is the usual case on
# a medium that has booted once — mv asks before overwriting a destination it
# cannot write to, and that question has hung a boot here already.
RETSRC=$(cat "$ROOT/lib/bootstrap.sh")
has   'the rename never asks' "$RETSRC" 'mv -f "$rs_f" "$rs_keep" < /dev/null'

# An overlay that carries the spore-seed service but not the tool that service
# runs is a machine that fails its own boot service every time and has no
# `spore` on it. /etc/init.d/spore-seed is committed because it is under /etc;
# /usr/local/lib/spore is only kept if the commit was told to. Invisible while
# the machine still boots from the seed — which is what retire takes away.
TOOLW=$(mktemp -d /tmp/spore-toolovl.XXXXXX)
mkdir -p "$TOOLW/half/etc/init.d" "$TOOLW/whole/etc/init.d" \
         "$TOOLW/whole/usr/local/lib/spore"
printf 'svc\n' > "$TOOLW/half/etc/init.d/spore-seed"
printf 'svc\n' > "$TOOLW/whole/etc/init.d/spore-seed"
printf 'run\n' > "$TOOLW/whole/usr/local/lib/spore/seed-run"
mkdir -p "$TOOLW/d"
printf 'seed\n' > "$TOOLW/d/spore-seed.apkovl.tar.gz"
( cd "$TOOLW/half" && tar -czf "$TOOLW/d/k.apkovl.tar.gz" . )
TOOL_H=$("$SPORE" retire "$TOOLW/d" 2>&1 || true)
has   'retire refuses an overlay missing the tool' "$TOOL_H" 'but not the tool it runs'
check 'and leaves the seed alone' \
    "$([ -f "$TOOLW/d/spore-seed.apkovl.tar.gz" ] && echo yes || echo no)" yes
( cd "$TOOLW/whole" && tar -czf "$TOOLW/d/k.apkovl.tar.gz" . )
TOOL_W=$("$SPORE" retire "$TOOLW/d" 2>&1)
check 'one that carries it is retired' \
    "$([ -f "$TOOLW/d/spore-seed.apkovl.tar.gz" ] && echo yes || echo no)" no
rm -rf "$TOOLW"

# And the commit keeps it, which is what makes that overlay whole. The service
# is the tell: a host with /etc/init.d/spore-seed is one that runs the tool at
# boot, so the tool has to survive the reboot with it.
TOOLP=$(mktemp -d /tmp/spore-toolkeep.XXXXXX)
mkdir -p "$TOOLP/etc/init.d" "$TOOLP/usr/local/lib/spore" "$TOOLP/usr/local/bin"
printf 'svc\n' > "$TOOLP/etc/init.d/spore-seed"
mkdir -p "$TOOLP/etc/runlevels/default"
ln -sf /etc/init.d/spore-seed "$TOOLP/etc/runlevels/default/spore-seed"
printf 'run\n' > "$TOOLP/usr/local/lib/spore/seed-run"
printf 'w\n'   > "$TOOLP/usr/local/bin/spore"
TOOLPLOG=$(mktemp /tmp/spore-toolkeeplog.XXXXXX)
export SPORE_FACT_LBU_DEST=/media/data SPORE_RUN_LOG="$TOOLPLOG"
alpine "$SPORE" --spore "$EX" --root "$TOOLP" persist >/dev/null 2>&1 || true
unset SPORE_FACT_LBU_DEST SPORE_RUN_LOG
has 'the commit keeps the tool tree'   "$(cat "$TOOLPLOG")" 'lbu include /usr/local/lib/spore'
# lbu takes an include that names a directory, lists it back, and keeps nothing
# of it: _gen_filelist drops any + entry that is a real directory. So the tool
# tree has to be named file by file, or the fix is a no-op that reads like a fix.
has 'the tool is kept file by file'  "$(cat "$TOOLPLOG")" 'lbu include /usr/local/lib/spore/seed-run'
# And the service is named too, though it lives under /etc and /etc was meant to
# look after itself. A real machine's overlay came back with
# etc/runlevels/default/sshd in it and etc/init.d/spore-seed not — both new,
# both owned by no package, both under /etc. Whatever `apk audit --backup` makes
# of those two, it does not make the same thing, and an include does not care.
has 'the seed service is named, not assumed' "$(cat "$TOOLPLOG")" 'lbu include /etc/init.d/spore-seed'
if grep -qx 'lbu include /usr/local/lib/spore' "$TOOLPLOG"; then
    t_fail 'not as a directory lbu drops' 'the tree was named, so nothing is kept'
else
    t_ok 'not as a directory lbu drops'
fi
has 'and the wrapper beside it'        "$(cat "$TOOLPLOG")" 'lbu include /usr/local/bin/spore'
# A dangling runlevel link is worse than no service: OpenRC errors on it every
# boot. Both halves travel together or neither does.
has 'with its runlevel link'          "$(cat "$TOOLPLOG")" 'lbu include /etc/runlevels/default/spore-seed'
# seed-run stamps /etc/spore/.seeded when `apply --persist` returns, and the
# commit happens inside that apply — so the stamp has never been in an apkovl
# and never could be. Without it an overlay-booted machine redoes the whole
# spore, which is what retiring the seed was supposed to stop.
check 'the converged stamp is written before the tar, not after the boot' \
    "$([ -f "$TOOLP/etc/spore/.seeded" ] && echo yes || echo no)" yes
has   'and kept'                      "$(cat "$TOOLPLOG")" 'lbu include /etc/spore/.seeded'
# But only on a machine that runs it at boot. A workstation applying a spore to
# itself has no spore-seed service and no business keeping a copy of the tool.
rm -f "$TOOLP/etc/init.d/spore-seed"
TOOLPLOG2=$(mktemp /tmp/spore-toolkeeplog2.XXXXXX)
export SPORE_FACT_LBU_DEST=/media/data SPORE_RUN_LOG="$TOOLPLOG2"
alpine "$SPORE" --spore "$EX" --root "$TOOLP" persist >/dev/null 2>&1 || true
unset SPORE_FACT_LBU_DEST SPORE_RUN_LOG
hasnt 'not where there is no seed service' "$(cat "$TOOLPLOG2")" 'lbu include /usr/local'
rm -rf "$TOOLP" "$TOOLPLOG" "$TOOLPLOG2"

RET_U=$("$SPORE" retire 2>&1 || true)
has   'it needs a target'    "$RET_U" 'usage: spore retire'
RET_M=$("$SPORE" retire "$RET/nope" 2>&1 || true)
has   'and refuses one that is not there' "$RET_M" 'no such device or directory'
rm -rf "$RET"


rm -rf "$R" "$R2" "$R3" "$R4" "$R5" "$BD" "$LOG" "$LOG2" "$PLOG" 2>/dev/null || true

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]