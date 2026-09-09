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

storage_plan() {
    st_root=$(mconf STORAGE_ROOT /media/storage)
    st_umask=$(mconf STORAGE_FAT_UMASK 000)
    st_uid=$(mconf STORAGE_FAT_UID '')
    st_gid=$(mconf STORAGE_FAT_GID '')
    st_owner=$(mconf STORAGE_OWNER '')

    storage_volumes > "$SPORE_WORK/volumes" || true
    if [ ! -s "$SPORE_WORK/volumes" ]; then
        plan_note 'storage: no volumes.conf in this spore — nothing to mount'
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
