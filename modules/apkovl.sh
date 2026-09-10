# modules/apkovl.sh — where the apkovl goes.
#
# On a diskless box `lbu commit` is the only thing that makes anything survive,
# and it writes wherever /etc/lbu/lbu.conf points. A stock Alpine points nowhere:
# every key in that file ships commented out, and `setup-lbu` is what normally
# fills one in — a console step, on a machine whose whole point is that nobody
# visits its console.
#
# So a seed-booted machine converges perfectly, commits to nothing, and comes
# back blank on the next boot. Nothing reports it: apply succeeds, the hook
# stamps itself done, and the loss only shows up as a machine that keeps
# forgetting. Declaring the destination in the spore is what closes that.

apkovl_meta() {
    MOD_DESC='where lbu commits the apkovl'
    MOD_REQUIRES='boot.media'
}

apkovl_plan() {
    ap_dir=$(mconf APKOVL_BACKUPDIR '')
    ap_media=$(mconf APKOVL_MEDIA '')

    if [ -n "$ap_dir" ] && [ -n "$ap_media" ]; then
        die "apkovl: set APKOVL_BACKUPDIR or APKOVL_MEDIA, not both.
         LBU_BACKUPDIR wins outright in lbu, so the other would be read, look
         configured, and never be written to."
    fi

    if [ -z "$ap_dir" ] && [ -z "$ap_media" ]; then
        # Beside the spore, by default. That partition is the one place we know
        # is mounted and writable, because we just read the spore off it —
        # anything else is a guess about how this particular machine mounts its
        # disks, and a wrong guess here is silent.
        ap_dir=$(dirname "$SPORE_DIR")
        case $ap_dir in
            /|/var/lib/spore|'') ap_dir='' ;;
        esac

        if [ -z "$ap_dir" ]; then
            # Deferring to a host configured by hand is fine. Deferring to one
            # that was not means committing into the void, which is the failure
            # this module exists to make impossible.
            if [ "$(fact_lbu_dest)" = unset ]; then
                die "apkovl: this host is diskless, /etc/lbu/lbu.conf names no
         destination, this spore does not name one, and the spore is not on a
         partition to sit beside. Committing would write nowhere at all: the
         machine converges on every boot and keeps none of it, with nothing
         reporting the loss.
         Set APKOVL_BACKUPDIR=/path (absolute, on a filesystem mounted when
         apply finishes) or APKOVL_MEDIA=name (for /media/name)."
            fi
            plan_note "apkovl: this spore names no destination, so the host's own
         is kept ($(fact_lbu_dest))."
            return 0
        fi
        plan_note "apkovl: committing beside the spore, at $ap_dir. Set
         APKOVL_BACKUPDIR or APKOVL_MEDIA to put it elsewhere."
    fi

    if [ -n "$ap_dir" ]; then
        case $ap_dir in
            /*) : ;;
            *)  die "apkovl: APKOVL_BACKUPDIR must be an absolute path, not '$ap_dir'" ;;
        esac
        ap_block="LBU_BACKUPDIR=$ap_dir"
    else
        # lbu builds the path as /media/$LBU_MEDIA, so a path here would produce
        # /media//media/data and fail somewhere far from the cause.
        case $ap_media in
            */*|'') die "apkovl: APKOVL_MEDIA is a name under /media, not a path.
         For /media/data, set APKOVL_MEDIA=data." ;;
        esac
        ap_block="LBU_MEDIA=$ap_media"
    fi

    # An owned block, not a rewrite: Alpine's lbu.conf carries the commented
    # documentation for every other key, and a hand-set ENCRYPTION or PASSWORD
    # belongs to the machine, not to us.
    plan_dir /etc/lbu 0755
    plan_file /etc/lbu/lbu.conf 0644 \
        "$(render_marked_block /etc/lbu/lbu.conf lbu "$ap_block")"
}
