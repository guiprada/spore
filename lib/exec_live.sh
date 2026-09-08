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
            case $ep_act in
                pkg)       el_pkg       "$f1" ;;
                blob)      el_blob      "$f1" "$f2" "$f3" "$f4" "$f5" "$f6" ;;
                dir)       el_dir       "$f1" "$f2" ;;
                file)      el_file      "$f1" "$f2" "$f3" "$f4" ;;
                svc)       el_svc       "$f1" "$f2" "$f3" ;;
                firstboot) el_firstboot "$f1" "$f2" ;;
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

el_svc() {
    es_name=$1 es_rl=$2 es_state=$3
    es_link=$(rootpath "/etc/runlevels/$es_rl/$es_name")

    if [ "$es_state" = on ]; then
        if [ -e "$es_link" ] || [ -L "$es_link" ]; then unchanged "service $es_name ($es_rl)"; return 0; fi
        if ! mutate; then say "would enable service $es_name ($es_rl)"; return 0; fi
        run rc-update add "$es_name" "$es_rl"
        if synthetic; then
            mkdir -p "$(dirname "$es_link")"
            ln -sf "/etc/init.d/$es_name" "$es_link"
        fi
        changed "service $es_name ($es_rl)"
    else
        if [ ! -e "$es_link" ] && [ ! -L "$es_link" ]; then unchanged "service $es_name disabled"; return 0; fi
        if ! mutate; then say "would disable service $es_name ($es_rl)"; return 0; fi
        run rc-update del "$es_name" "$es_rl"
        if synthetic; then rm -f "$es_link"; fi
        changed "service $es_name disabled"
    fi
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

# Deferred work: run now under `apply`; under `build` this becomes a script in
# /etc/local.d so it runs at first germination instead.
el_firstboot() {
    efb_id=$1 efb_sha=$2
    efb_stamp=$(rootpath "/var/lib/spore/firstboot/$efb_id")
    if [ -f "$efb_stamp" ]; then unchanged "firstboot $efb_id"; return 0; fi
    if ! mutate; then say "would run firstboot $efb_id"; return 0; fi

    run sh "$(content_path "$efb_sha")"
    mkdir -p "$(dirname "$efb_stamp")"
    printf '%s\n' "$efb_sha" > "$efb_stamp"
    changed "firstboot $efb_id"
}
