# modules/storage.sh — mount declared volumes under a serve root.
#
# The original wizard discovered disks interactively and asked which to enable.
# A spore cannot do that: it has to name volumes by a stable identifier so the
# same spore produces the same mounts on any box. Hence volumes.conf, keyed by
# UUID or LABEL rather than by /dev/sdb1, which renumbers.
#
# Two hard-won details from the original script are preserved here:
#   * vfat/exfat/ntfs cannot carry Unix ownership, so access comes from mount
#     options (umask), not from chown — and chown must tolerate failure.
#   * nofail on every entry. A disk that is not plugged in must never stop a
#     box from booting.
#
# fstab is edited as an owned block, never rewritten: the root filesystem and
# anything else already in there is not ours to touch.

storage_meta() {
    MOD_DESC='mount declared volumes under a serve root'
    MOD_REQUIRES='root'
    MOD_DATA=$(mconf STORAGE_ROOT /media/storage)
}

# volumes.conf rows:  <name> <spec> <fstype> <options|->
#   spec: UUID=..., LABEL=..., /dev/..., or bind:/some/path
storage_volumes() {
    sv_f=$SPORE_DIR/volumes.conf
    [ -f "$sv_f" ] || return 0
    awk '/^[[:space:]]*#/ { next } NF >= 2 { print $1, $2, ($3 == "" ? "-" : $3), ($4 == "" ? "-" : $4) }' "$sv_f"
}

# Filesystems that cannot express Unix ownership.
storage_is_fatlike() {
    case $1 in
        vfat|msdos|exfat|ntfs|ntfs-3g) return 0 ;;
        *) return 1 ;;
    esac
}

storage_fs_package() {
    case $1 in
        exfat)          printf 'exfatprogs' ;;
        ntfs|ntfs-3g)   printf 'ntfs-3g' ;;
        vfat|msdos)     printf 'dosfstools' ;;
        ext2|ext3|ext4) printf 'e2fsprogs' ;;
        btrfs)          printf 'btrfs-progs' ;;
        xfs)            printf 'xfsprogs' ;;
        *)              printf '' ;;
    esac
}

# --- sharing whatever is plugged in ------------------------------------------
#
# volumes.conf is the declared half: name a disk by UUID and it lands in the
# same place on any machine. That is right for a machine you are describing, and
# useless for the thing a file server is actually for — plug a disk in, have it
# appear.
#
# So this half discovers instead, and it cannot be a plan action: the plan is
# built on the workstation, and what is attached is not known there. Nor can it
# be a firstboot action, because a machine booted from its committed overlay
# stops at /etc/spore/.seeded and never applies anything. It is a service, which
# runs on every boot the way the rest of the machine does.
#
# "Not system" is decided by what is already mounted. Whatever this machine
# booted from is mounted by the time this runs — the boot medium at /media/sdX1,
# the spore's partition at /media/sdX2 — so the rule is simply: mount what is
# not. Then check what was mounted, because the rule is only as good as the
# initramfs being consistent, and an unshared partition that turns up shared is
# this spore's identity file on a web server.
storage_automount_script() {
    printf "root='%s'\nnaming='%s'\nexclude=' %s '\numask='%s'\nowner='%s'\n" \
        "$1" "$2" "$3" "$4" "$5"
    cat <<'SAM'
mkdir -p "$root"

# The device list is overridable so the decisions below can be exercised against
# a real filesystem on a loop device. Nothing sets it on a machine, where the
# globs are the whole point: loop and device-mapper nodes are deliberately not
# among them, because a loop mount is something this machine already did.
: "${SPORE_AUTOMOUNT_DEVS:=}"

# An identifier a disk does not have is not a match for anything. Testing it
# inline reads fine and is wrong: with no exclusions configured $exclude is two
# spaces, and a disk with no LABEL turns *" $la "* into those same two spaces,
# so every unlabelled filesystem excludes itself. Empty means "no such
# identifier", never "matches".
in_exclude() {
    [ -n "$1" ] || return 1
    case $exclude in *" $1 "*) return 0 ;; esac
    return 1
}

# Every branch below says why it passed a device over. A run that shares nothing
# has to account for itself, or the only way to find out what it decided is to
# re-derive the script by hand.
seen=0
shared=0

# A partition is a candidate; a whole disk only when it carries a filesystem
# itself, which is why the disk globs come second and skip anything partitioned.
for dev in ${SPORE_AUTOMOUNT_DEVS:-/dev/sd[a-z][0-9]* /dev/vd[a-z][0-9]* /dev/xvd[a-z][0-9]* \
           /dev/nvme[0-9]n[0-9]p[0-9]* /dev/mmcblk[0-9]p[0-9]* \
           /dev/sd[a-z] /dev/vd[a-z] /dev/xvd[a-z]}; do
    [ -b "$dev" ] || continue
    seen=$((seen + 1))
    case $dev in
        */sd[a-z]|*/vd[a-z]|*/xvd[a-z])
            # Partitioned: its partitions were the candidates, not the disk.
            for p in "$dev"[0-9]*; do
                [ -b "$p" ] || continue
                echo "spore: $dev is partitioned, so its partitions were the"
                echo "spore: candidates and the whole disk is not one."
                continue 2
            done ;;
    esac

    # Mounted already is the whole definition of "this machine's own": the
    # initramfs mounted what it booted from before anything here ran. Except
    # under the serve root, where the thing that mounted it was this script on an
    # earlier pass — a restart must not report the disks it is serving as the one
    # it booted from.
    at=$(awk -v d="$dev" '$1 == d { print $2; exit }' /proc/mounts)
    if [ -n "$at" ]; then
        case $at in
            "$root"/*)
                shared=$((shared + 1))
                echo "spore: $dev is shared already, at $at" ;;
            *)
                echo "spore: $dev is mounted at $at, so this machine is using it" ;;
        esac
        continue
    fi

    info=$(blkid "$dev" 2>/dev/null) || info=''
    ty=$(printf '%s' "$info" | sed -n 's/.*[[:space:]]TYPE="\([^"]*\)".*/\1/p')
    if [ -z "$ty" ]; then
        echo "spore: $dev has no filesystem blkid recognises, so there is nothing"
        echo "spore: to share on it — an empty disk, or one whose partition table"
        echo "spore: is the only thing on it."
        [ -z "$info" ] || echo "spore:   blkid said: $info"
        continue
    fi
    case $ty in
        swap|crypto_LUKS|linux_raid_member|LVM2_member)
            echo "spore: $dev is $ty, which is not a filesystem to serve"
            continue ;;
    esac
    # The leading space is what tells UUID= from PARTUUID=.
    uu=$(printf '%s' "$info" | sed -n 's/.*[[:space:]]UUID="\([^"]*\)".*/\1/p')
    la=$(printf '%s' "$info" | sed -n 's/.*[[:space:]]LABEL="\([^"]*\)".*/\1/p')

    short=${dev##*/}
    if in_exclude "$short" || in_exclude "$uu" || in_exclude "$la"; then
        echo "spore: $dev is named in STORAGE_AUTO_EXCLUDE, so it is not shared"
        continue
    fi

    case $naming in
        dev)   name=$short ;;
        label) name=${la:-${uu:-$short}} ;;
        *)     name=${uu:-$short} ;;
    esac
    name=$(printf '%s' "$name" | sed 's/[^A-Za-z0-9_.-]/_/g')
    [ -n "$name" ] || name=$short

    tgt=$root/$name
    if awk -v t="$tgt" '$2 == t { found = 1 } END { exit !found }' /proc/mounts; then
        echo "spore: $tgt is mounted already, so $dev is left as it is"
        continue
    fi
    opts=noatime
    case $ty in
        vfat|msdos|exfat|ntfs|ntfs-3g) opts="noatime,umask=$umask" ;;
    esac
    mkdir -p "$tgt"
    if ! mount -t "$ty" -o "$opts" "$dev" "$tgt" 2>/dev/null; then
        rmdir "$tgt" 2>/dev/null || true
        echo "spore: $dev is $ty and would not mount" >&2
        continue
    fi

    # Now look at what was mounted. Everything above trusts the initramfs to
    # have mounted this machine's own partitions first, and one boot where it
    # does not would put the spore — identity file and all — on a file server.
    # Cheap to check, and the only check that does not depend on that being
    # true.
    if [ -e "$tgt/identity" ] || [ -f "$tgt/spore/spore.conf" ] ||
       [ -f "$tgt/.alpine-release" ] || ls "$tgt"/*.apkovl.tar.gz >/dev/null 2>&1; then
        umount "$tgt" 2>/dev/null || true
        rmdir "$tgt" 2>/dev/null || true
        echo "spore: $dev carries a spore or an apkovl, so it is this machine's" >&2
        echo "spore: own medium and is not being shared." >&2
        continue
    fi

    # A file server running as its own account cannot write to a disk owned by
    # root, so "allow uploads" and "uploads work" are two different settings.
    #
    # One directory, never the tree. This runs at every boot against whatever
    # happens to be plugged in, so a recursive chown here would rewrite the
    # ownership of a disk nobody was thinking about when the setting was chosen —
    # irreversibly, with no record of what it changed, every boot. The top is
    # what the server needs to start writing; the rest is a decision to make with
    # the disk in front of you, and the note below hands you the command for it.
    was=''
    if [ -n "$owner" ]; then
        case $ty in
            vfat|msdos|exfat|ntfs|ntfs-3g)
                # No Unix ownership to hold; the umask above is what grants
                # access on these, and chown would fail for a real reason.
                ;;
            *)
                # Recorded before it changes, so the line below is enough to put
                # it back. A chown with no record of what it replaced is the part
                # that makes one hard to undo.
                was=$(stat -c '%U:%G' "$tgt" 2>/dev/null) || was=''
                if chown "$owner" "$tgt" 2>/dev/null; then
                    :
                else
                    was=''
                    echo "spore: could not chown $tgt to $owner — is that account" >&2
                    echo "spore: on this machine? Uploads to it will be refused." >&2
                fi ;;
        esac
    fi

    # Read back how it actually mounted rather than how it was asked to. A disk
    # the kernel decided to protect comes up read-only, which from a browser
    # looks the same as a server that was never told to accept uploads.
    how=$(awk -v t="$tgt" '$2 == t { print $4; exit }' /proc/mounts)
    case ,$how, in
        *,ro,*)
            echo "spore: $tgt is mounted READ-ONLY ($how), so nothing can be" >&2
            echo "spore: written to it whatever the server is configured to allow." >&2 ;;
    esac

    shared=$((shared + 1))
    echo "spore: sharing $dev ($ty) at $tgt${was:+, owner $was -> $owner}"

    # What the disk arrived with is still the disk's. Rather than a setting that
    # takes it over on every boot of every disk, say that it is there and hand
    # over the one command — run once, on a disk you are looking at, by someone
    # who decided to. -h so it cannot follow a symlink off the disk, which is not
    # a hypothetical on media you did not format.
    if [ -n "$was" ]; then
        theirs=$(find "$tgt" -mindepth 1 -maxdepth 1 ! -user "$owner" \
                      ! -name 'lost+found' 2>/dev/null | head -n 1)
        if [ -n "$theirs" ]; then
            echo "spore: $tgt came with directories $owner does not own, starting"
            echo "spore: at ${theirs##*/} — those stay read-only to it. Uploads land, and"
            echo "spore: what was already there does not move. To hand the rest over,"
            echo "spore: once, with the disk in front of you:  chown -Rh $owner $tgt"
        fi
    fi
done

if [ "$seen" -eq 0 ]; then
    echo "spore: no block device matched at all. This looks at sd*, vd*, xvd*,"
    echo "spore: nvme* and mmcblk* — not loop or device-mapper nodes, which are"
    echo "spore: mounts this machine made itself."
elif [ "$shared" -eq 0 ]; then
    echo "spore: looked at $seen device(s) and shared none; the lines above say why."
else
    echo "spore: looked at $seen device(s), shared $shared under $root"
fi
SAM
}

storage_plan_automount() {
    spa_root=$1
    spa_umask=$2
    spa_owner=$3
    spa_name=$(mconf STORAGE_AUTO_NAME uuid)
    case $spa_name in
        uuid|label|dev) : ;;
        *) plan_note "storage: STORAGE_AUTO_NAME is uuid, label or dev — not '$spa_name'.
         Using uuid, which is the one that does not move between boots."
           spa_name=uuid ;;
    esac
    spa_excl=$(mconf STORAGE_AUTO_EXCLUDE '')

    # Whatever turns up has to be mountable, and what turns up is not knowable
    # from here, so the drivers travel rather than the guess.
    for spa_p in e2fsprogs dosfstools exfatprogs ntfs-3g; do
        plan_pkg "$spa_p"
    done

    plan_dir "$spa_root" 0755
    plan_file /usr/local/sbin/spore-automount 0755 "#!/bin/sh
# Managed by spore. Mounts every attached filesystem this machine did not boot
# from, under $spa_root.
set -u
$(storage_automount_script "$spa_root" "$spa_name" "$spa_excl" "$spa_umask" \
                           "$spa_owner")"

    plan_file /etc/init.d/spore-automount 0755 "#!/sbin/openrc-run
# Managed by spore.
description=\"Mount attached volumes this machine did not boot from\"

depend() {
    need localmount
    before dufs
}

start() {
    ebegin \"spore: looking for volumes to share\"
    /usr/local/sbin/spore-automount
    eend 0
}

stop() { return 0; }"
    plan_svc spore-automount default on

    plan_note "storage: STORAGE_AUTO=yes — every attached filesystem this machine
         did not boot from is mounted under $spa_root at each boot, named by
         $spa_name, and whatever serves that root serves all of it. That
         includes internal disks and anything plugged in later. Name the ones
         to leave alone in STORAGE_AUTO_EXCLUDE (device, UUID or label), or
         use volumes.conf instead to mount only what you have declared."

    # The one that costs a boot to discover: a server told to accept uploads,
    # writing as its own account, to disks owned by root. Nothing errors at plan
    # time and nothing errors at mount time — it just refuses every upload.
    if [ -z "$spa_owner" ]; then
        plan_note "storage: these mounts keep whatever ownership the disks carry,
         which is usually root, so only root can write to them. A server that
         runs as its own account (dufs does) will be refused every upload and
         delete however it is configured. Set STORAGE_OWNER to that account —
         STORAGE_OWNER=dufs for this one — to hand it the top of each disk."
    else
        # There is deliberately no setting that chowns the whole tree. This runs
        # at every boot against whatever is plugged in, and a recursive chown
        # there rewrites the ownership of disks nobody had in mind when the
        # setting was chosen, with no record of what it replaced. The service
        # names the command instead, for a disk you are looking at.
        plan_note "storage: STORAGE_OWNER=$spa_owner is given the top of each
         shared disk, and only that. Anything the server creates from then on is
         its own; a disk that arrives with directories on it keeps them, and they
         stay read-only to the server. That is not a setting, on purpose — this
         runs on every boot against whatever is attached, and a recursive chown
         there would rewrite disks you were not thinking about. The service
         prints the one-off command when it finds such a disk."
    fi
}

storage_plan() {
    st_root=$(mconf STORAGE_ROOT /media/storage)
    st_umask=$(mconf STORAGE_FAT_UMASK 000)
    st_uid=$(mconf STORAGE_FAT_UID '')
    st_gid=$(mconf STORAGE_FAT_GID '')
    st_owner=$(mconf STORAGE_OWNER '')
    # It is spliced into a chown in a generated script, so it is an account name
    # (optionally user:group) or it is refused here rather than at 3am on a box
    # with no console.
    case $st_owner in
        ''|*[!A-Za-z0-9_.:-]*)
            [ -z "$st_owner" ] || {
                plan_note "storage: STORAGE_OWNER='$st_owner' is not an account name.
         Expected user, or user:group. Ignoring it, so the mounts keep the
         ownership their disks carry."
                st_owner='' ; } ;;
    esac

    st_auto=no
    if mconf_bool STORAGE_AUTO no; then
        st_auto=yes
        storage_plan_automount "$st_root" "$st_umask" "$st_owner"
    fi

    storage_volumes > "$SPORE_WORK/volumes" || true
    if [ ! -s "$SPORE_WORK/volumes" ]; then
        # Declared and discovered are two halves of the same root, and having
        # neither is the only case worth mentioning.
        [ "$st_auto" = yes ] ||
            plan_note 'storage: no volumes.conf in this spore, and STORAGE_AUTO is
         not set, so nothing is mounted. Declare volumes by UUID in
         volumes.conf, or set STORAGE_AUTO=yes to share whatever is attached.'
        return 0
    fi

    plan_dir "$st_root" 0755

    st_lines=''
    st_mounts=''
    st_chowns=''
    st_pkgs=''

    while read -r st_name st_spec st_fs st_opts; do
        [ -n "$st_name" ] || continue

        case $st_name in
            *[!A-Za-z0-9_-]*)
                plan_note "storage: skipping volume '$st_name' — name must be alphanumeric, _ or -"
                continue ;;
        esac

        st_target=$st_root/$st_name

        # A volume must land under the serve root. Without this a typo in
        # volumes.conf could put an fstab entry on / or /etc.
        case $st_target in
            "$st_root"/*) ;;
            *) plan_note "storage: refusing volume '$st_name' — target escapes $st_root"; continue ;;
        esac

        # bind: mounts an existing path rather than a block device. This is how
        # the boot medium gets served without exposing it as a raw device.
        case $st_spec in
            bind:*)
                st_src=${st_spec#bind:}
                st_fstype=none
                st_defopts=bind,nofail
                ;;
            UUID=*|LABEL=*|PARTUUID=*|/dev/*)
                st_src=$st_spec
                st_fstype=$st_fs
                if [ "$st_fstype" = '-' ]; then
                    st_fstype=auto
                fi
                if storage_is_fatlike "$st_fstype"; then
                    # umask=000 is what actually grants access here: on these
                    # filesystems permissions come from the mount, not the inode.
                    st_defopts="noatime,nofail,umask=$st_umask"
                    if [ -n "$st_uid" ]; then st_defopts="$st_defopts,uid=$st_uid"; fi
                    if [ -n "$st_gid" ]; then st_defopts="$st_defopts,gid=$st_gid"; fi
                else
                    st_defopts=noatime,nofail
                    if [ -n "$st_owner" ]; then
                        st_chowns="$st_chowns
chown -R '$st_owner' '$st_target' 2>/dev/null || true"
                    fi
                fi
                st_p=$(storage_fs_package "$st_fstype")
                if [ -n "$st_p" ]; then st_pkgs="$st_pkgs $st_p"; fi
                ;;
            *)
                plan_note "storage: skipping volume '$st_name' — spec '$st_spec' is not UUID=, LABEL=, PARTUUID=, /dev/ or bind:"
                continue ;;
        esac

        if [ "$st_opts" = '-' ]; then
            st_useopts=$st_defopts
        else
            st_useopts=$st_opts
            case ,$st_useopts, in
                *,nofail,*) ;;
                *) plan_note "storage: volume '$st_name' has custom options without nofail — an absent disk will block boot" ;;
            esac
        fi

        plan_dir "$st_target" 0755
        st_lines="$st_lines
$st_src	$st_target	$st_fstype	$st_useopts	0	0"
        st_mounts="$st_mounts
grep -q ' $st_target ' /proc/mounts || mount '$st_target' || echo \"spore: could not mount $st_target\" >&2"
    done < "$SPORE_WORK/volumes"

    [ -n "$st_lines" ] || return 0

    for st_pk in $st_pkgs; do
        plan_pkg "$st_pk"
    done

    plan_file /etc/fstab 0644 \
        "$(render_marked_block /etc/fstab storage "# name	mountpoint	type	options	dump	pass$st_lines")"

    # Mounting is runtime state, not file state: fstab handles it at boot, this
    # only makes it live now without a reboot. Re-runs whenever the set changes,
    # because the stamp follows the script's content.
    plan_firstboot storage-mount "set -e
mkdir -p '$st_root'$st_mounts$st_chowns"
}

# Shown under `spore status`, because "is it actually mounted right now" is not
# something the plan can answer.
storage_status_extra() {
    sse_root=$(mconf STORAGE_ROOT /media/storage)
    storage_volumes | while read -r sse_name sse_rest; do
        [ -n "$sse_name" ] || continue
        sse_t=$sse_root/$sse_name
        if grep -q " $sse_t " /proc/mounts 2>/dev/null; then
            printf '%s mounted\n' "$sse_t"
        else
            printf '%s NOT mounted\n' "$sse_t"
        fi
    done
}
