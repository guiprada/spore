# lib/exec_live.sh — the live executor.
#
# Consumes a plan and produces effects under $SPORE_ROOT. When $SPORE_ROOT is not
# `/` the root is *synthetic*: external tools (apk, rc-update) are not run, so the
# executor writes the state those tools would have produced. That rule is what
# makes the whole path testable without Alpine — and it is the seed of the
# staging executor `build` will need.

exec_plan() {
    for ep_t in $SPORE_ACTION_ORDER; do
        plan_lines_of_type "$ep_t" > "$SPORE_WORK/pass.tsv"
        while IFS="$SPORE_TAB" read -r ep_mod ep_act f1 f2 f3 f4 f5 f6; do
            [ -n "$ep_act" ] || continue
            SPORE_ACTION="$ep_act $f1 (module $ep_mod)"
            case $ep_act in
                netup)     el_script    netup "$f1" "$f2" ;;
                bootstrap) el_script    bootstrap "$f1" "$f2" ;;
                pkg)       el_pkg       "$f1" ;;
                blob)      el_blob      "$f1" "$f2" "$f3" "$f4" "$f5" "$f6" ;;
                dir)       el_dir       "$f1" "$f2" ;;
                file)      el_file      "$f1" "$f2" "$f3" "$f4" ;;
                secret)    el_secret    "$f1" "$f2" "$f3" "$f4" ;;
                svc)       el_svc       "$f1" "$f2" "$f3" ;;
                firstboot) el_script    firstboot "$f1" "$f2" ;;
                *) warn "unknown action: $ep_act" ;;
            esac
        done < "$SPORE_WORK/pass.tsv"
    done
}

el_pkg() {
    ep_world=$(rootpath /etc/apk/world)
    if command -v apk >/dev/null 2>&1 && ! synthetic; then
        if apk info -e "$1" >/dev/null 2>&1; then unchanged "package $1"; return 0; fi
    elif [ -f "$ep_world" ] && grep -qx -- "$1" "$ep_world"; then
        unchanged "package $1"; return 0
    fi
    if ! mutate; then say "would install package $1"; return 0; fi

    starting "package $1"
    run apk add --no-progress "$1"
    if synthetic; then
        mkdir -p "$(dirname "$ep_world")"
        printf '%s\n' "$1" >> "$ep_world"
    fi
    changed "package $1"
}

el_dir() {
    ed_dst=$(rootpath "$1")
    if [ -d "$ed_dst" ]; then unchanged "dir $1"; return 0; fi
    if ! mutate; then say "would create dir $1"; return 0; fi
    mkdir -p "$ed_dst"
    chmod "$2" "$ed_dst"
    changed "dir $1"
}

el_file() {
    ef_path=$1 ef_mode=$2 ef_owner=$3 ef_sha=$4
    ef_dst=$(rootpath "$ef_path")
    ef_src=$(content_path "$ef_sha")

    if [ -f "$ef_dst" ] && [ "$(sha256_file "$ef_dst")" = "$ef_sha" ]; then
        unchanged "file $ef_path"; return 0
    fi
    if ! mutate; then say "would write file $ef_path"; return 0; fi

    mkdir -p "$(dirname "$ef_dst")"
    # Keep the true original exactly once; later runs must not bury it.
    if [ -e "$ef_dst" ] && [ ! -e "$ef_dst.spore-orig" ]; then
        cp -p "$ef_dst" "$ef_dst.spore-orig"
    fi
    cp "$ef_src" "$ef_dst"
    chmod "$ef_mode" "$ef_dst"
    if [ "$ef_owner" != root:root ] && ! synthetic && [ "$(fact_root)" = yes ]; then
        run chown "$ef_owner" "$ef_dst"
    fi
    changed "file $ef_path"
}

# Rendered under umask 077 into the workspace, compared, then moved. The
# plaintext is never logged, never announced, and never enters the content store.
el_secret() {
    esc_path=$1 esc_mode=$2 esc_owner=$3 esc_sha=$4
    esc_dst=$(rootpath "$esc_path")

    if ! mutate; then say "would write secret $esc_path"; return 0; fi

    esc_tmp=$SPORE_WORK/secret.out
    (umask 077; secret_render "$(content_path "$esc_sha")" > "$esc_tmp")

    if [ -f "$esc_dst" ] && [ "$(sha256_file "$esc_dst")" = "$(sha256_file "$esc_tmp")" ]; then
        rm -f "$esc_tmp"
        unchanged "secret $esc_path"
        return 0
    fi

    mkdir -p "$(dirname "$esc_dst")"
    (umask 077; cat "$esc_tmp" > "$esc_dst")
    chmod "$esc_mode" "$esc_dst"
    rm -f "$esc_tmp"
    if [ "$esc_owner" != root:root ] && ! synthetic && [ "$(fact_root)" = yes ]; then
        run chown "$esc_owner" "$esc_dst"
    fi
    changed "secret $esc_path"
}

# Declared state for a service is "running", not merely "enabled at boot".
# Enabling only would let apply report success on a service that is not up, with
# the failure surfacing at the next reboot instead. The running check needs a
# real init, so it is skipped under a synthetic root — one of the few paths only
# a real box exercises.
el_svc() {
    es_name=$1 es_rl=$2 es_state=$3
    es_link=$(rootpath "/etc/runlevels/$es_rl/$es_name")

    if [ "$es_state" = on ]; then
        if [ -e "$es_link" ] || [ -L "$es_link" ]; then
            unchanged "service $es_name ($es_rl)"
        elif ! mutate; then
            say "would enable service $es_name ($es_rl)"
        else
            run rc-update add "$es_name" "$es_rl"
            if synthetic; then
                mkdir -p "$(dirname "$es_link")"
                ln -sf "/etc/init.d/$es_name" "$es_link"
            fi
            changed "service $es_name ($es_rl)"
        fi

        if ! synthetic; then
            if rc-service "$es_name" status >/dev/null 2>&1; then
                unchanged "service $es_name running"
            elif ! mutate; then
                say "would start service $es_name"
            else
                # Enabling is the durable half and has already happened above.
                # Starting is best-effort on purpose: this often runs from
                # inside a service in the default runlevel, where OpenRC will
                # refuse anything whose dependencies belong to an earlier one —
                # "cannot start chronyd as fsck would not start". The service is
                # in the runlevel and comes up on the next boot regardless, so
                # dying here would trade a working machine for a timing detail.
                es_started=no
                if rc-service "$es_name" start; then
                    es_started=yes
                elif rc-service --nodeps "$es_name" start; then
                    # "cannot start dufs as localmount would not start" does not
                    # mean localmount is not up. It is: the boot runlevel ran it
                    # minutes ago. It means localmount is not in *this* runlevel's
                    # graph, and OpenRC will not re-enter a runlevel that has
                    # finished — so it refuses rather than checks.
                    #
                    # -D skips that check (rc-service(8): "ignores dependencies
                    # when running the service"). It is the right tool for this
                    # one case and the wrong one in general, so it is a fallback
                    # and never the first attempt: if a dependency really is
                    # missing, the daemon fails, and the verification below
                    # reports it as not running rather than as started.
                    #
                    # Without this, a machine that had just installed a file
                    # server served nothing until somebody rebooted it, and the
                    # log said so in a line nobody had a reason to read.
                    es_started=yes
                    say "$es_name started with its dependency check skipped —
         they belong to the boot runlevel, which finished before this ran."
                fi
                if [ "$es_started" = no ]; then
                    warn "$es_name is enabled but would not start now.
         OpenRC refuses a service whose dependencies belong to a runlevel that
         has already passed, which is usual when applying from inside the boot
         it is configuring, and starting it without that check did not work
         either. It starts on the next boot. If it still does not:
             rc-service $es_name start"
                    changed "service $es_name enabled, starts next boot"
                    return 0
                fi
                # OpenRC reports success once the process is launched. A daemon
                # that exits a moment later still counts as a successful start,
                # so trusting the exit code claims success on a dead service.
                # Verify, with a brief grace period for slow starters.
                es_up=no
                for es_try in 1 2 3; do
                    if rc-service "$es_name" status >/dev/null 2>&1; then
                        es_up=yes
                        break
                    fi
                    sleep 1
                done
                if [ "$es_up" != yes ]; then
                    warn "$es_name reported a successful start but is not running.
         OpenRC returns success once the process is launched; a daemon that
         exits immediately still counts. It is enabled, so the next boot will
         try again. To see why it died:
             rc-service $es_name status
             /etc/init.d/$es_name describe"
                    changed "service $es_name enabled, but not running"
                    return 0
                fi
                changed "service $es_name started"
            fi
        fi
        return 0
    fi

    if ! synthetic && rc-service "$es_name" status >/dev/null 2>&1; then
        if mutate; then
            run rc-service "$es_name" stop
            changed "service $es_name stopped"
        else
            say "would stop service $es_name"
        fi
    fi
    if [ ! -e "$es_link" ] && [ ! -L "$es_link" ]; then
        unchanged "service $es_name disabled"
        return 0
    fi
    if ! mutate; then
        say "would disable service $es_name ($es_rl)"
        return 0
    fi
    run rc-update del "$es_name" "$es_rl"
    if synthetic; then rm -f "$es_link"; fi
    changed "service $es_name disabled"
}

el_blob() {
    eb_name=$1 eb_url=$2 eb_sha=$3 eb_dest=$4 eb_mode=$5 eb_member=$6
    eb_stamp=$(rootpath "/var/lib/spore/blobs/$eb_name")
    eb_dst=$(rootpath "$eb_dest")

    if [ -f "$eb_stamp" ] && [ "$(cat "$eb_stamp")" = "$eb_sha" ] && [ -e "$eb_dst" ]; then
        unchanged "blob $eb_name"; return 0
    fi
    if ! mutate; then say "would install blob $eb_name -> $eb_dest"; return 0; fi

    runlog "blob-install $eb_name $eb_url $eb_sha $eb_dest"
    if synthetic || [ "$SPORE_NOEXEC" = 1 ]; then
        mkdir -p "$(dirname "$eb_dst")"; : > "$eb_dst"; chmod "$eb_mode" "$eb_dst"
    else
        blob_install "$eb_name" "$eb_url" "$eb_sha" "$eb_dest" "$eb_mode" "$eb_member"
    fi
    mkdir -p "$(dirname "$eb_stamp")"
    printf '%s\n' "$eb_sha" > "$eb_stamp"
    changed "blob $eb_name"
}

# Scripted work, stamped so it runs once. `bootstrap` runs before packages;
# `firstboot` is deferred work that runs now under `apply` and, under `build`,
# becomes a script in /etc/local.d that runs at first germination instead.
# No action may hang the boot. One that never returns takes the machine with
# it, before anything can be written down about why — which is exactly what
# setup-keymap's EOF loop did, and the cost of that was a week of reading a log
# from the last boot that finished. Generous, because a legitimate action can be
# genuinely slow; finite, because none of them can be infinite. Set to 0 to
# disable, for an action that really does take longer than this.
: "${SPORE_SCRIPT_TIMEOUT:=600}"

# Stdin is deliberately not redirected. Closing it does not stop a tool that
# prompts — a `while` loop around a read treats EOF as an empty answer and asks
# again, so /dev/null turns a program that blocks into one that spins. Better it
# waits, where a human at a console can still answer, and the deadline below
# ends it when there is nobody.
el_run_script() {
    ers_file=$1
    if [ "${SPORE_SCRIPT_TIMEOUT:-0}" != 0 ] && command -v timeout >/dev/null 2>&1; then
        run timeout "$SPORE_SCRIPT_TIMEOUT" sh "$ers_file"
    else
        run sh "$ers_file"
    fi
}

el_script() {
    es_kind=$1 es_id=$2 es_sha=$3
    es_stamp=$(rootpath "/var/lib/spore/$es_kind/$es_id")
    if [ -f "$es_stamp" ] && [ "$(cat "$es_stamp")" = "$es_sha" ]; then
        unchanged "$es_kind $es_id"; return 0
    fi
    if ! mutate; then say "would run $es_kind $es_id"; return 0; fi

    starting "$es_kind $es_id"
    el_run_script "$(content_path "$es_sha")"
    mkdir -p "$(dirname "$es_stamp")"
    printf '%s\n' "$es_sha" > "$es_stamp"
    changed "$es_kind $es_id"
}
