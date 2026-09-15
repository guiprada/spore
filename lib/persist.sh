# lib/persist.sh — make it survive a reboot, by whatever mechanism this host has.
#
# The command is identical everywhere; only the backend differs. This is where
# diskless and container/VM hosts are unified.

persist_backend() { fact_persist; }

# run(), but handing back the status instead of dying on it: the caller has a
# read-only mount to restore before anything else happens, and a timeout to
# tell apart from a genuine failure. Same dry-run and synthetic-root guards,
# because skipping those is how a test suite starts running lbu for real.
persist_try() {
    runlog "$*"
    if [ "$SPORE_DRYRUN" = 1 ]; then say "would run: $*"; return 0; fi
    if [ "${SPORE_NOEXEC:-0}" = 1 ] || synthetic; then return 0; fi
    "$@"
}

# Anything that touches the medium can wait on it — a USB stick that has gone
# slow or is failing takes the boot with it, silently, because none of these
# tools say anything while they work. So they all get a deadline, and the
# command is logged before it runs rather than after it returns, because the
# ones that matter are the ones that do not return.
#
# It always runs: no dry-run or synthetic-root guard, deliberately. Those are
# decisions about whether an action should happen at all, and every caller here
# has already made one — `run` and `persist_try` are the guarded forms.
persist_bounded() {
    pb_t=$1
    shift
    runlog "$*"
    if command -v timeout >/dev/null 2>&1; then
        timeout "$pb_t" "$@"
    else
        "$@"
    fi
}

persist_mount() { pm_t=$1; shift; persist_bounded "$pm_t" mount "$@" 2>/dev/null; }

# The filesystem a path is on, which is not the path. /proc/mounts lists mount
# points, so looking up /media/storage/data finds nothing at all and the caller
# concludes it is writable — the one case where the answer matters is a
# subdirectory of a read-only medium, and that is the case the naive lookup
# cannot see.
persist_mount_of() {
    pmo_p=$1
    while [ -n "$pmo_p" ]; do
        if awk -v d="$pmo_p" '$2 == d { f = 1 } END { exit !f }' /proc/mounts 2>/dev/null
        then
            printf '%s' "$pmo_p"
            return 0
        fi
        case $pmo_p in
            /|'') break ;;
        esac
        pmo_p=${pmo_p%/*}
        [ -n "$pmo_p" ] || pmo_p=/
    done
    printf '/'
}

# Is the filesystem under this path mounted read-only?
persist_is_ro() {
    pir_m=$(persist_mount_of "$1")
    pir_o=$(awk -v d="$pir_m" '$2 == d { print $4; exit }' /proc/mounts 2>/dev/null || true)
    case ",${pir_o}," in
        *,ro,*) printf '%s' "$pir_m"; return 0 ;;
    esac
    return 1
}

# lbu refuses to commit when its destination holds an apkovl that is not the
# one it is about to write:
#
#     The following apkovl file(s) were found:
#     /media/sda2/spore-seed.apkovl.tar.gz
#     Please use -d to replace.
#
# and it is right to. Two apkovls on one filesystem is genuinely ambiguous —
# the initramfs takes whichever it finds first, so which machine you boot is
# down to scan order. The one it found is ours: the bootstrap seed, put there
# by `spore install` so a blank Alpine could find the spore in the first place.
#
# Its job ends here. What is about to be written is a superset of it — the same
# tool, the same service, plus everything the spore just converged — so the seed
# is renamed out of the way rather than deleted. `lbu commit -d` would delete
# it, along with anything else matching, and if this medium's boot partition
# could not be mounted at install time that would be the only copy.
persist_clear_seed() {
    pcs_dir=$(rootpath "${1:-}")
    [ -n "${1:-}" ] && [ -d "$pcs_dir" ] || return 0
    # Every seed of ours in here, under whatever name. lbu's glob is
    # `*.apkovl.tar.gz*` — with a trailing star, for the encrypted variants —
    # so an earlier attempt that renamed to `.apkovl.tar.gz.superseded` still
    # matched it and lbu still refused. The name it moves to has to leave that
    # glob entirely, not merely look different.
    #
    # Only files that are plainly ours. An apkovl from another machine is
    # exactly the ambiguity lbu is warning about, and quietly moving it aside
    # would answer a question that was worth asking.
    pcs_found=no
    for pcs_seed in "$pcs_dir"/spore-seed.apkovl.tar.gz*; do
        [ -f "$pcs_seed" ] && { pcs_found=yes; break; }
    done
    [ "$pcs_found" = yes ] || return 0
    if ! mutate; then
        say "would set the bootstrap seed aside so lbu can commit here"
        return 0
    fi
    starting "setting the bootstrap seed aside in $pcs_dir"

    # Read-only first, before the move rather than after it has failed.
    #
    # The medium is mounted read-only at this point: lbu remounts it itself, and
    # only inside `lbu commit`, which is after this runs. Trying the move anyway
    # and remounting only if it failed is what hung a boot here for a week. By
    # then the destination already existed, from the last boot that got this
    # far, and busybox mv does this (coreutils/mv.c):
    #
    #     if (dest_exists) {
    #         if (!(flags & OPT_FORCE)
    #          && ((access(dest, W_OK) < 0 && isatty(0)) || ...
    #             fprintf(stderr, "mv: overwrite '%s'? ", dest);
    #             if (!bb_ask_y_confirmation()) goto RET_0;
    #
    # access() reports EROFS on a read-only filesystem even to root, stdin at
    # boot is the console, and the question went to a stderr this code was
    # sending to /dev/null. So the machine asked something nobody could see and
    # waited for an answer until it was switched off — no error, no progress,
    # nothing on the console but the line above this one.
    #
    # Three things settle it: the remount happens first, so there is nothing to
    # ask about; `-f` means it would not ask anyway; and stdin is /dev/null, so
    # anything else down here that decides to ask gets EOF instead of the
    # keyboard. Errors go to the console now rather than to /dev/null — a
    # question that cannot be seen is exactly what this cost.
    #
    # Only when it really is read-only, read off /proc/mounts rather than
    # inferred from a failure. A move can fail for permissions on a perfectly
    # writable filesystem, and "put it back read-only" would then be taking away
    # something nobody gave. And it goes straight back afterwards rather than
    # being left for lbu: lbu decides whether to restore read-only by checking
    # whether the medium was read-only when it started, so leaving it writable
    # here means it stays writable afterwards, and a USB stick mounted rw is a
    # corruption risk at the next power cut.
    pcs_mp=''
    if pcs_ro=$(persist_is_ro "$pcs_dir"); then
        starting "remounting $pcs_ro read-write"
        persist_mount 60 -o remount,rw "$pcs_ro" && pcs_mp=$pcs_ro
    fi

    # Kept, and kept legible: still a seed, no longer an apkovl. `spore install`
    # writes a fresh one whenever it runs, and `spore seed` rebuilds one from a
    # running machine, so this is a courtesy rather than the only copy.
    #
    # One destination per source, not one for all of them: the glob also catches
    # the encrypted variants, and moving every match onto a single name would
    # quietly leave only the last one.
    pcs_moved=no
    for pcs_f in "$pcs_dir"/spore-seed.apkovl.tar.gz*; do
        [ -f "$pcs_f" ] || continue
        pcs_name=${pcs_f##*/}
        pcs_keep=$pcs_dir/spore-seed.superseded.tar.gz${pcs_name#spore-seed.apkovl.tar.gz}
        # Named one at a time. When this stalled, the console had only that the
        # step as a whole had begun — one line covering a glob, a stat, a
        # remount and a rename, which is a week of boots to narrow down by hand.
        starting "renaming $pcs_name"
        persist_bounded 60 mv -f "$pcs_f" "$pcs_keep" < /dev/null && pcs_moved=yes
    done

    if [ -n "$pcs_mp" ]; then
        starting "remounting $pcs_mp read-only"
        persist_mount 60 -o remount,ro "$pcs_mp" || true
    fi

    if [ "$pcs_moved" = yes ]; then
        say "set the bootstrap seed aside: it has done its job, and lbu will not
         commit into a directory holding an apkovl it did not write"
    else
        warn "could not move the bootstrap seed out of $pcs_dir, so lbu is about to refuse
         to commit here. Remove it by hand, or set APKOVL_BACKUPDIR to a
         directory it is not in."
    fi
}

# The tool keeps itself, when the machine is one that runs it at boot.
#
# The seed puts the spore-seed service in /etc/init.d, so lbu commits it without
# being asked — /etc is the one thing an apkovl always carries. What the service
# runs is /usr/local/lib/spore/seed-run, and /usr/local is on the RAM root like
# everything else outside /etc. So the overlay carried a service whose program
# was not in it: a machine booted from that overlay fails spore-seed on every
# boot and has no `spore` on it at all.
#
# Invisible for as long as the machine keeps booting from the seed, which
# carries the tool — and the seed is exactly what `spore retire` takes away.
persist_tool_paths() {
    [ -f "$(rootpath /etc/init.d/spore-seed)" ] || return 0
    for ptp_p in /usr/local/lib/spore /usr/local/bin/spore; do
        [ -e "$(rootpath "$ptp_p")" ] && printf '%s\n' "$ptp_p"
    done
    return 0
}

persist_commit() {
    case $(persist_backend) in
        lbu)
            lbu_warnings
            # Deliberately NOT remounting the media read-write here. lbu does it
            # itself (mount_once_rw), records what it remounted, and restores
            # read-only on exit. Remounting first would make lbu's is_ro check
            # see it as already writable, so it would not be added to
            # REMOUNT_RO_LIST and the boot medium would be left mounted rw — a
            # corruption risk on a USB stick at power loss. The original wizard's
            # make_usb_writable was for writing certs and the apk cache to the
            # medium directly, which is a different operation.

            # /etc is already in the overlay by default; everything else has to
            # be declared. Owned paths come from the plan, so this can't drift.
            # Announced as a phase, because the gap between "N changed" and
            # the commit was the one stretch of this run with nothing in it —
            # and a boot that stopped somewhere in here looked exactly like a
            # boot that stopped at the counts.
            starting 'recording what to keep'
            { plan_persist_paths; plan_all_owned_paths; persist_tool_paths; } |
                sort -u > "$SPORE_WORK/persist.final"
            while read -r pc_p; do
                [ -n "$pc_p" ] || continue
                case $pc_p in /etc|/etc/*) continue ;; esac
                run lbu include "$pc_p"
            done < "$SPORE_WORK/persist.final"

            # lbu writes into its destination but never creates it, and on a
            # diskless box that directory usually sits on a partition a
            # firstboot action mounted a moment ago. Doing it here, last, is the
            # only point where the path is certainly the mounted filesystem
            # rather than a directory about to be hidden under a mount.
            pc_dest=$(fact_lbu_dest)
            case $pc_dest in
                /*) [ -d "$(rootpath "$pc_dest")" ] || run mkdir -p "$(rootpath "$pc_dest")" ;;
            esac

            persist_clear_seed "$pc_dest"

            # lbu remounts read-write only when it was given a medium:
            #
            #     mnt="$LBU_BACKUPDIR"
            #     if [ -z "$mnt" ]; then
            #         mnt=/media/$media
            #         mount_once_rw "$mnt" || die "failed to mount $mnt"
            #     fi
            #
            # With LBU_BACKUPDIR it takes the early path and nothing remounts,
            # so on a read-only boot medium the commit dies at the copy with the
            # destination perfectly correct. apkovl turns any plain /media/<name>
            # into LBU_MEDIA precisely so lbu handles it; this is for the ones it
            # cannot — a subdirectory, or somewhere outside /media entirely.
            pc_ro=no pc_mp=''
            if mutate; then
                pc_bdir=$(conf_get "$(rootpath /etc/lbu/lbu.conf)" LBU_BACKUPDIR '')
                if [ -n "$pc_bdir" ] && pc_mp=$(persist_is_ro "$(rootpath "$pc_bdir")"); then
                    starting "remounting $pc_mp read-write"
                    persist_mount 60 -o remount,rw "$pc_mp" && pc_ro=yes
                fi
            fi

            # Bounded, like every script action. This one was not, and it is
            # the likeliest thing here to stop returning: it tars /etc and
            # writes it to a USB stick, silently, so a boot that is working and
            # a boot that is wedged look exactly alike from the console — which
            # leaves a power switch and a guess.
            pc_to=''
            if [ "${SPORE_COMMIT_TIMEOUT:-600}" != 0 ] &&
               command -v timeout >/dev/null 2>&1; then
                pc_to="timeout ${SPORE_COMMIT_TIMEOUT:-600}"
            fi

            # The longest silence in the whole run, and until now an
            # unannounced one: lbu tars /etc onto the medium and prints nothing
            # at all until it is finished or has failed.
            starting "committing the apkovl to $pc_dest"
            pc_rc=0
            # shellcheck disable=SC2086  # pc_to is a command prefix, or empty
            persist_try $pc_to lbu commit || pc_rc=$?
            if [ "$pc_ro" = yes ]; then
                # Put back whether or not the commit worked. A stick left
                # mounted rw is a corruption risk at the next power cut, and
                # the failure path is exactly where nobody looks.
                starting "remounting $pc_mp read-only"
                persist_mount 60 -o remount,ro "$pc_mp" || true
            fi

            if [ "$pc_rc" = 124 ]; then
                die "lbu commit did not finish within ${SPORE_COMMIT_TIMEOUT:-600}s
         and was stopped. It writes /etc to $pc_dest, so a medium that has
         become slow or is failing looks exactly like this. Try the write by
         hand to see where it stalls:
             lbu commit
         Set SPORE_COMMIT_TIMEOUT to allow longer, or 0 for no limit."
            elif [ "$pc_rc" != 0 ]; then
                die "lbu commit failed (status $pc_rc) writing to $pc_dest"
            fi
            # lbu returns once the write is issued, not once it has reached the
            # medium. On removable media a page-cached apkovl can survive a
            # clean shutdown and be lost to a power cut, leaving a truncated
            # archive that only fails at the next boot.
            run sync
            persist_verify
            say "committed to apkovl"
            ;;
        rootfs)
            pc_out=$(rootpath /var/lib/spore/spore)
            if mutate; then
                mkdir -p "$(dirname "$pc_out")"
                rm -rf "$pc_out"
                cp -a "$SPORE_DIR" "$pc_out"
            fi
            say "root is writable — nothing to commit; spore exported to /var/lib/spore/spore"
            ;;
    esac
}

# A broken trust store is silent until something fetches over HTTPS.
ca_warnings() {
    case $(fact_ca_store) in
        missing) warn "no CA trust store at /etc/ssl/certs/ca-certificates.crt.
         apk carries its own, so packages install while git, curl and every blob
         fetch fail with 'unable to get local issuer certificate'.
         Fix: apk add ca-certificates-bundle" ;;
        empty)   warn "the CA trust store at /etc/ssl/certs/ca-certificates.crt
         exists but holds no certificates. update-ca-certificates regenerates
         that file and can leave it empty.

         Note that \`openssl s_client\` will still verify happily: it reads the
         DIRECTORY /etc/ssl/certs, while git and curl read the single bundle
         FILE. A passing s_client does not mean this is fine.

         Fix: apk add --force-overwrite ca-certificates-bundle
         (do not run update-ca-certificates after — that is what empties it)
         Or point a tool at the directory: git config http.sslCAPath /etc/ssl/certs" ;;
    esac
}

# `lbu commit` with nowhere to write fails in a way that reads like a bug in
# spore rather than a missing line in lbu.conf.
lbu_warnings() {
    [ "$(persist_backend)" = lbu ] || return 0
    if [ "$(fact_lbu_dest)" = unset ]; then
        warn "this host is diskless but /etc/lbu/lbu.conf names no destination.
         \`spore persist\` has nowhere to write the apkovl, so nothing will
         survive a reboot. Set LBU_MEDIA to a mounted, writable device (a data
         partition is fine — the boot medium can stay read-only, since the
         initramfs finds the apkovl by scanning devices), or run setup-alpine
         and answer its 'store configs' question."
    fi
}

# A commit that cannot be read back is worse than no commit: it looks like
# success and fails at boot, when the machine is least able to tell you why.
persist_verify() {
    synthetic && return 0
    [ "$SPORE_NOEXEC" = 1 ] && return 0
    pv_dir=$(fact_lbu_dest)
    [ "$pv_dir" != unset ] && [ -d "$pv_dir" ] || return 0
    pv_f=$pv_dir/$(hostname 2>/dev/null).apkovl.tar.gz
    [ -f "$pv_f" ] || return 0
    if tar -tzf "$pv_f" >/dev/null 2>&1; then
        say "verified $pv_f ($(wc -c < "$pv_f") bytes)"
    else
        die "$pv_f was written but is not a readable archive.
         Do not reboot until this is resolved: the machine restores from this
         file and will come back without its configuration."
    fi
}

# The classic diskless trap.
persist_warnings() {
    [ "$(persist_backend)" = lbu ] || return 0
    if [ ! -d /var/cache/apk ] || [ ! -L /etc/apk/cache ]; then
        warn "diskless host with no apk cache on persistent media: /etc/apk/world will
         persist the intent to have a package, but the package files will be
         re-downloaded on every boot. See setup-apkcache."
    fi
}
