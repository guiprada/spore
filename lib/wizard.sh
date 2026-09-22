# lib/wizard.sh — the guided path.
#
# `spore new` collapses the mechanical part of preparing a machine, but it still
# leaves you to find out which keys exist, in which file, and which of them the
# ssh module will refuse to build without. That is a lot of reading for the
# first machine, and the failures land at boot rather than at the keyboard.
#
# So this asks. Nothing here is privileged and nothing is destructive: it writes
# a machine directory and tells you the two commands that follow. Writing the
# disk is `spore media`, kept separate because it erases one.
#
# The spore it writes is minimal on purpose — the modules you answered questions
# about, and no others. An example full of volumes and a file server you did not
# ask for is a worse starting point than a short file you understand.

# The prompts assign into a variable you name rather than printing their answer.
# That is not a style preference. Read through `$( )` they ran in a subshell, and
# a subshell cannot stop the wizard — `die` there exits only itself — so when
# stdin ended every prompt went on silently handing back its default, for ever.
# Any loop that rejects its own default then spins until the terminal is killed,
# which is exactly what `while [ -z "$wz_addr" ]` with an empty default did.
wz_ask() {
    # wz_ask <var> <prompt> [default]
    if [ -n "${3-}" ]; then
        printf '%s%s%s [%s]: ' "$_c_bold" "$2" "$_c_reset" "$3" >&2
    else
        printf '%s%s%s: ' "$_c_bold" "$2" "$_c_reset" >&2
    fi
    if IFS= read -r wz_a; then :; else
        printf '\n' >&2
        die "input ended at \"$2\", so nothing was written.
             Answer at a terminal, or feed every answer on stdin."
    fi
    [ -n "$wz_a" ] || wz_a=${3-}
    eval "$1=\$wz_a"
}

wz_yn() {
    # wz_yn <var> <prompt> <y|n default>
    wz_d=$3
    while :; do
        wz_ask wz_r "$2 (y/n)" "$wz_d"
        case $wz_r in
            y|Y|yes|YES|Yes) eval "$1=yes"; return 0 ;;
            n|N|no|NO|No)    eval "$1=no";  return 0 ;;
            *) printf '  answer y or n\n' >&2 ;;
        esac
    done
}

wz_say()  { printf '%s\n' "$*" >&2; }
wz_head() { printf '\n%s%s%s\n' "$_c_bold" "$*" "$_c_reset" >&2; }

# --- picking from a list -----------------------------------------------------
#
# Several answers come from a fixed set, and every one of them was a free-text
# prompt with the set spelled out in the question. That is two problems. You have
# to type a value exactly from a description of it, and a near miss went
# somewhere different in each case: an unknown NTP client made it into the conf
# and died at plan time; anything that was not the word "static" silently became
# dhcp, so a typo configured a machine for the wrong network and said nothing.
#
# A numbered list answers both. It is also the shape the answer already had —
# "chrony, busybox, openntpd or none" is a list read out loud.
#
# Each choice is "value" or "value=label". A value may contain spaces, which is
# why they are separate arguments rather than one string.
wz_choice_value() { printf '%s' "${1%%=*}"; }

wz_choice_has() {
    wch_want=$1
    shift
    for wch_c in "$@"; do
        if [ "${wch_c%%=*}" = "$wch_want" ]; then return 0; fi
    done
    return 1
}

wz_choice_nth() {
    wcn_n=$1
    shift
    wcn_i=0
    for wcn_c in "$@"; do
        wcn_i=$((wcn_i + 1))
        if [ "$wcn_i" = "$wcn_n" ]; then printf '%s' "${wcn_c%%=*}"; return 0; fi
    done
    return 1
}

wz_choice_show() {
    # Its own line, always. A menu is several lines where every other prompt is
    # one, and run together with the answer above it they read as one blob.
    printf '\n' >&2
    wcs_i=0
    for wcs_c in "$@"; do
        wcs_i=$((wcs_i + 1))
        wcs_v=${wcs_c%%=*}
        wcs_l=${wcs_c#*=}
        [ "$wcs_l" != "$wcs_c" ] || wcs_l=''
        if [ -n "$wcs_l" ]; then
            printf '  %2d) %-16s %s\n' "$wcs_i" "$wcs_v" "$wcs_l" >&2
        else
            printf '  %2d) %s\n' "$wcs_i" "$wcs_v" >&2
        fi
    done
}

# _wz_pick <strict|open> <var> <prompt> <default> <choice>...
#
# Re-asking is safe here in a way it was not for the keyboard layout, and for a
# reason worth stating: every one of these sets is closed and the default is in
# it, so a blank line always answers the question. The loop cannot reject
# everything the way one over an open-ended set can, and wz_ask still dies on
# EOF, so it cannot spin on a pipe either.
_wz_pick() {
    wp_mode=$1 wp_var=$2 wp_prompt=$3 wp_def=$4
    shift 4
    # A default outside its own list makes the prompt unanswerable: blank takes
    # the default, the default is refused, and there is no third thing to type.
    # That is a bug on this side of the prompt, so it stops here.
    if [ "$wp_mode" = strict ] && ! wz_choice_has "$wp_def" "$@"; then
        die "wizard: the default '$wp_def' is not among the choices offered for
         \"$wp_prompt\" — answering it would be refused and blank is that answer."
    fi
    wz_choice_show "$@"
    while :; do
        wz_ask wp_a "$wp_prompt" "$wp_def"
        case $wp_a in
            ''|*[!0-9]*) : ;;
            *) if wp_hit=$(wz_choice_nth "$wp_a" "$@"); then
                   eval "$wp_var=\$wp_hit"
                   return 0
               fi
               # All digits is a pick from the list and nothing else. Without
               # this, open mode took an out-of-range number as the answer
               # itself and wrote SYSTEM_KEYMAP=99 — no layout is a number, and
               # a wrong index is a slip, not a value.
               wz_say "  there is no $wp_a) in the list"
               continue ;;
        esac
        if wz_choice_has "$wp_a" "$@"; then
            eval "$wp_var=\$wp_a"
            return 0
        fi
        if [ "$wp_mode" = open ] && [ -n "$wp_a" ]; then
            eval "$wp_var=\$wp_a"
            return 0
        fi
        wz_say "  '$wp_a' is not one of them — a number from the list, or the name"
    done
}

# One of these, and nothing else.
wz_pick() { _wz_pick strict "$@"; }

# --- keyboard layouts, from the same data Alpine builds them from -------------
#
# setup-keymap asks twice — layout, then variant — against the real set, which
# it gets by installing kbd-bkeymaps and listing /usr/share/bkeymaps. None of
# that is available here: this runs on a workstation, days before the machine
# exists.
#
# But the set is derivable, because Alpine derives it. main/kbd/APKBUILD reads
# /usr/share/X11/xkb/rules/base.lst — the X keyboard data this workstation also
# has — takes every line of its "! variant" section as one <layout>-<variant>
# map, gives every layout named there a plain <layout> map as well, and installs
# each as bkeymaps/<layout>/<name>.bmap.gz. That pair, <layout> and <name>, is
# exactly what SYSTEM_KEYMAP holds.
#
# So the same transformation, over the same file, offers the same list. What it
# cannot promise is the version: the target's set comes from whichever
# xkeyboard-config Alpine built against, and this workstation has its own. A
# pair that is right here and missing there is caught on the machine by
# render_keymap, which names the ones that do exist. That is a message rather
# than a guess, which is why this can afford to be a list rather than a warning.
WZ_XKB_RULES=${WZ_XKB_RULES-}

wz_xkb_file() {
    if [ -n "$WZ_XKB_RULES" ]; then
        [ -f "$WZ_XKB_RULES" ] && printf '%s' "$WZ_XKB_RULES"
        return 0
    fi
    for wxf_f in /usr/share/X11/xkb/rules/base.lst \
                 /usr/share/X11/xkb/rules/evdev.lst; do
        if [ -f "$wxf_f" ]; then printf '%s' "$wxf_f"; return 0; fi
    done
    return 0
}

# Only the layouts that appear in the variant section: the APKBUILD generates a
# plain <layout> map inside that loop, so a layout with no variants gets no map
# at all and offering it would be offering something that is not there.
wz_xkb_layouts() {
    awk '
        /^! layout/  { sec = "l"; next }
        /^! variant/ { sec = "v"; next }
        /^!/         { sec = "";  next }
        sec == "l" && NF { c = $1; $1 = ""; sub(/^[ \t]+/, ""); d[c] = $0; next }
        sec == "v" && NF { l = $2; sub(/:$/, "", l); has[l] = 1; next }
        END { for (l in has) printf "%s\t%s\n", l, (l in d ? d[l] : l) }
    ' "$1" | sort
}

# Named the way the map file is, because that is what SYSTEM_KEYMAP carries:
# bkeymaps/br/br-nodeadkeys.bmap.gz is the pair "br br-nodeadkeys".
wz_xkb_variants() {
    awk -v want="$2" '
        /^! variant/ { sec = 1; next }
        /^!/         { sec = 0; next }
        sec && NF {
            l = $2; sub(/:$/, "", l)
            if (l != want) next
            d = $0; sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+:[ \t]*/, "", d)
            printf "%s-%s\t%s\n", want, $1, d
        }
    ' "$1"
}

wz_xkb_columns() {
    wxc_w=$(stty size 2>/dev/null | cut -d' ' -f2) || wxc_w=''
    case $wxc_w in ''|*[!0-9]*) wxc_w=80 ;; esac
    [ "$wxc_w" -ge 40 ] || wxc_w=80
    cut -f1 "$1" | awk -v w="$wxc_w" '
        { a[n++] = $0; if (length($0) > m) m = length($0) }
        END {
            m += 2
            cols = int(w / m); if (cols < 1) cols = 1
            for (i = 0; i < n; i++) {
                printf "%-*s", m, a[i]
                if ((i + 1) % cols == 0) printf "\n"
            }
            if (n % cols) printf "\n"
        }
    ' >&2
}

# wz_keymap <var> — sets it to "<layout> <variant>", or empty for "leave it".
wz_keymap() {
    wk_var=$1
    wk_rules=$(wz_xkb_file)
    if [ -z "$wk_rules" ]; then
        # No X keyboard data here — a headless workstation, or a mac. The short
        # list is all that is left, and it is still better than a bare prompt.
        wz_say 'No X keyboard data on this machine to list layouts from, so this'
        wz_say 'is the short list. Any other "<layout> <variant>" pair can be'
        wz_say 'typed and is checked on the target.'
        wz_pick_open "$wk_var" 'Keyboard' 'us us' \
            'us us=US English' \
            'br br-abnt2=Brazilian, ABNT2' \
            'gb gb=UK English' \
            'de de-nodeadkeys=German' \
            'fr fr=French' \
            'es es=Spanish' \
            'pt pt-latin1=Portuguese' \
            'it it=Italian' \
            '-=leave the layout alone'
        [ "$(eval "printf '%s' \"\$$wk_var\"")" = - ] && eval "$wk_var=''"
        return 0
    fi

    wk_list=$SPORE_WORK/xkb-layouts
    wz_xkb_layouts "$wk_rules" > "$wk_list"
    wz_say 'Alpine builds its keymaps out of the same X keyboard data this'
    wz_say 'workstation has, so these are the layouts the machine will have.'
    wz_say 'Type a code, or part of a name to search for one. A dash leaves the'
    wz_say 'layout alone; a full "<layout> <variant>" pair skips the next question.'
    printf '\n' >&2
    wz_xkb_columns "$wk_list"

    # What the last search printed, so a number can answer it.
    wk_prev=''
    while :; do
        wz_ask wk_a 'Layout' 'us'
        if [ "$wk_a" = - ]; then eval "$wk_var=''"; return 0; fi
        case $wk_a in
            ''|*[!0-9]*) : ;;
            *) if [ -n "$wk_prev" ]; then
                   wk_layout=$(printf '%s\n' "$wk_prev" | sed -n "${wk_a}p" | cut -f1)
                   if [ -n "$wk_layout" ]; then break; fi
                   wz_say "  there is no $wk_a) in the list"
               else
                   wz_say "  '$wk_a' is not a layout, and there is no list to number"
               fi
               continue ;;
        esac
        wk_prev=''
        # A whole pair in one answer, which is what setup-keymap also accepts
        # and what everyone who already knows the answer will type.
        case $wk_a in
            *' '*) eval "$wk_var=\$wk_a"; return 0 ;;
        esac
        if awk -F'\t' -v c="$wk_a" '$1 == c { f = 1 } END { exit !f }' "$wk_list"; then
            wk_layout=$wk_a
            break
        fi
        # Not a code, so read it as a search. "portuguese" is a far more likely
        # thing to know than "pt", and a list of 83 codes does not tell you
        # which one you want.
        wk_hits=$(awk -F'\t' -v q="$wk_a" '
            BEGIN { q = tolower(q) }
            tolower($0) ~ q { print }
        ' "$wk_list" 2>/dev/null) || wk_hits=''
        wk_n=0
        [ -z "$wk_hits" ] || wk_n=$(printf '%s\n' "$wk_hits" | grep -c .)
        if [ "$wk_n" = 0 ]; then
            wz_say "  no layout code or name matches '$wk_a'"
            continue
        fi
        if [ "$wk_n" = 1 ]; then
            wk_layout=$(printf '%s' "$wk_hits" | cut -f1)
            wz_say "  $wk_layout — $(printf '%s' "$wk_hits" | cut -f2)"
            break
        fi
        wz_say "  $wk_n layouts match '$wk_a':"
        printf '%s\n' "$wk_hits" | awk -F'\t' '
            { printf "   %2d) %-10s %s\n", NR, $1, $2 }
        ' >&2
        wk_prev=$wk_hits
    done

    # The variants are a closed set and a short one, so this half is a plain
    # menu. The plain layout is first and is the default, because it is what
    # "br" on its own has always meant.
    wk_vars=$SPORE_WORK/xkb-variants
    wz_xkb_variants "$wk_rules" "$wk_layout" > "$wk_vars"
    set -- "$wk_layout=the layout's own default"
    while IFS="$SPORE_TAB" read -r wk_v wk_d; do
        [ -n "$wk_v" ] || continue
        set -- "$@" "$wk_v=$wk_d"
    done < "$wk_vars"
    wz_pick wk_variant 'Variant' "$wk_layout" "$@"
    eval "$wk_var=\"\$wk_layout \$wk_variant\""
}

# --- timezones, from the workstation's own tzdata ----------------------------
#
# setup-timezone walks /usr/share/zoneinfo: list the top level, descend into
# whatever the answer names, repeat until the answer is a file. It has tzdata
# to hand because it runs on the target and installs it first.
#
# Here tzdata is on the workstation instead, and it carries something better
# than a directory tree: zone1970.tab is the canonical list — 312 zones rather
# than the 450 files, which include legacy aliases, posixrules and Factory —
# and each row has the country codes and a description. So "sao", "brazil" and
# "BR" can all find America/Sao_Paulo, which descending a tree cannot.
#
# The version caveat is the keymap's: the target's tzdata is its own, and a zone
# that is here and missing there is reported by setup-timezone on the machine,
# by name. So the list is a list and not a gate.
WZ_ZONEINFO=${WZ_ZONEINFO-}

wz_tz_dir() {
    if [ -n "$WZ_ZONEINFO" ]; then
        [ -d "$WZ_ZONEINFO" ] && printf '%s' "$WZ_ZONEINFO"
        return 0
    fi
    [ -d /usr/share/zoneinfo ] && printf '%s' /usr/share/zoneinfo
    return 0
}

# zone<TAB>country-codes<TAB>description. The codes are their own field because
# two letters is a country and not a substring: searching "BR" across whole
# lines matches Gibraltar and Bratislava too, which is every Brazilian zone
# plus forty others — a list too long to show and no answer at all.
wz_tz_table() {
    wtt_root=$1
    [ -f "$wtt_root/UTC" ] && printf 'UTC\t\tCoordinated Universal Time\n'
    for wtt_f in "$wtt_root/zone1970.tab" "$wtt_root/zone.tab"; do
        [ -f "$wtt_f" ] || continue
        awk -F'\t' '
            /^#/ { next }
            NF >= 3 && $3 != "" {
                printf "%s\t%s\t%s\n", $3, $1, (NF >= 4 ? $4 : "")
            }
        ' "$wtt_f" | sort -u
        return 0
    done
    # No table shipped: the tree, minus the files in it that are not zones.
    ( cd "$wtt_root" 2>/dev/null || exit 0; find . -type f 2>/dev/null ) |
        sed 's|^\./||' | awk '
            /^(posix|right)\// { next }
            /\.(tab|zi|list)$/ { next }
            /^(leapseconds|localtime|posixrules|Factory|UTC)$/ { next }
            { printf "%s\t\t\n", $0 }
        ' | sort -u
}

# Two letters are tried as a country code first, and only fall back to a
# substring when no country has them — so "BR" is Brazil and "zz" is still a
# search.
wz_tz_search() {
    wts_hits=$(awk -F'\t' -v q="$2" '
        BEGIN { q = tolower(q) }
        q ~ /^[a-z][a-z]$/ {
            n = split(tolower($2), c, ",")
            for (i = 1; i <= n; i++) if (c[i] == q) { print; next }
        }
    ' "$1")
    if [ -n "$wts_hits" ]; then printf '%s\n' "$wts_hits"; return 0; fi
    awk -F'\t' -v q="$2" 'BEGIN { q = tolower(q) } tolower($0) ~ q' "$1"
}

wz_tz_label() {
    printf '%s' "$2${2:+${3:+ — }}$3"
}

# --- package mirrors ---------------------------------------------------------
#
# setup-apkrepos fetches https://mirrors.alpinelinux.org/mirrors.txt, numbers
# the hostnames, and takes a number, a URL, 'r' for a random one or 'f' to time
# them all and keep the quickest. The list is live, which is the only way it can
# be right — mirrors come and go — and this is one of the few places where the
# workstation is a better place to ask from than the target: it has a network
# now, and the machine being built does not exist yet.
#
# What it cannot do is measure the target's network. `f` times this workstation's
# route to each mirror, which is a good proxy when the machine will live on the
# same desk and a poor one when it will not, so it says which it is measuring.
WZ_MIRRORS_URL=${WZ_MIRRORS_URL-https://mirrors.alpinelinux.org/mirrors.txt}

# A path is read, a URL is fetched. The path case is how the tests pin the list,
# and also how someone with their own list of mirrors uses it.
wz_fetch() {
    if [ -f "$1" ]; then cat "$1"; return $?; fi
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 20 -- "$1" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --timeout=20 -- "$1" 2>/dev/null
    else
        return 1
    fi
}

wz_mirror_host() { wmh=${1#*://}; printf '%s' "${wmh%%/*}"; }

# The same probe setup-apkrepos times: an index that every mirror carries. It is
# a latency measurement and not a fetch of anything this machine will install,
# which is why the architecture in it does not have to be the target's.
wz_mirror_time() {
    wmt_u=${1%/}/edge/main/x86_64/APKINDEX.tar.gz
    if command -v curl >/dev/null 2>&1; then
        curl -fsS -o /dev/null -m 5 -w '%{time_total}' -I -- "$wmt_u" 2>/dev/null
    else
        return 1
    fi
}

wz_mirror_fastest() {
    wmf_best='' wmf_bt=''
    while IFS= read -r wmf_u; do
        [ -n "$wmf_u" ] || continue
        wmf_t=$(wz_mirror_time "$wmf_u") || wmf_t=''
        case $wmf_t in
            ''|*[!0-9.]*) printf '  %-38s no answer\n' "$(wz_mirror_host "$wmf_u")" >&2
                          continue ;;
        esac
        printf '  %-38s %ss\n' "$(wz_mirror_host "$wmf_u")" "$wmf_t" >&2
        if [ -z "$wmf_bt" ] ||
           awk -v a="$wmf_t" -v b="$wmf_bt" 'BEGIN { exit !(a < b) }'; then
            wmf_bt=$wmf_t wmf_best=$wmf_u
        fi
    done < "$1"
    [ -n "$wmf_best" ] || return 1
    printf '%s' "$wmf_best"
}

# wz_mirror <var> — empty means "keep whatever the image came with".
wz_mirror() {
    wm_var=$1
    wz_say 'Package mirror. Blank keeps whatever the image came with, which is'
    wz_say 'the global CDN — it always works and is often slow from far away.'

    wm_list=$SPORE_WORK/mirrors
    if ! wz_fetch "$WZ_MIRRORS_URL" 2>/dev/null |
         sed -n 's/[[:space:]]*$//; /^[a-z][a-z0-9+.-]*:\/\//p' > "$wm_list" ||
       [ ! -s "$wm_list" ]; then
        wz_say ''
        wz_say "Could not fetch the mirror list from $WZ_MIRRORS_URL."
        wz_say 'Blank keeps the CDN, or type the base URL of a mirror —'
        wz_say 'https://mirror.ufpr.br/alpine, no release or repository on the end.'
        wz_ask "$wm_var" 'Mirror URL' ''
        return 0
    fi

    wm_n=$(grep -c . "$wm_list")
    printf '\n' >&2
    awk '{ printf "   %2d) %s\n", NR, $0 }' "$wm_list" |
        sed 's|\(https\?://\)||; s|/[[:space:]]*$||' >&2
    printf '\n' >&2
    wz_say "A number from those $wm_n, part of a hostname to search, a URL of"
    wz_say "your own, or 'f' to time them all and take the quickest. Blank keeps"
    wz_say 'the CDN the image already points at.'

    while :; do
        wz_ask wm_a 'Mirror' ''
        [ -n "$wm_a" ] || { eval "$wm_var=''"; return 0; }
        case $wm_a in
            f|F)
                wz_say ''
                wz_say 'Timing each one from this workstation. That is the route from'
                wz_say 'here, not from wherever the machine will end up — the same'
                wz_say 'answer when it lives on this desk, and a guess when it does not.'
                if wm_fast=$(wz_mirror_fastest "$wm_list"); then
                    wz_say ""
                    wz_say "  quickest: $(wz_mirror_host "$wm_fast")"
                    wm_fast=${wm_fast%/}

                    eval "$wm_var=\$wm_fast"
                    return 0
                fi
                wz_say '  no mirror answered; leaving it as it was'
                continue ;;
            */*)
                # A URL of their own. Stripped of any trailing slash, because
                # repos.sh appends /$branch/main and two slashes in a repository
                # line is the sort of thing apk reports about the wrong file.
                wm_a=${wm_a%/}
                eval "$wm_var=\$wm_a"
                return 0 ;;
        esac
        case $wm_a in
            ''|*[!0-9]*) : ;;
            *) wm_u=$(sed -n "${wm_a}p" "$wm_list")
               if [ -n "$wm_u" ]; then wm_u=${wm_u%/}; eval "$wm_var=\$wm_u"; return 0; fi
               wz_say "  there is no $wm_a) in the list"
               continue ;;
        esac
        wm_hits=$(grep -i -- "$wm_a" "$wm_list" 2>/dev/null) || wm_hits=''
        wm_hn=0
        [ -z "$wm_hits" ] || wm_hn=$(printf '%s\n' "$wm_hits" | grep -c .)
        if [ "$wm_hn" = 1 ]; then
            wz_say "  $(wz_mirror_host "$wm_hits")"
            wm_hits=${wm_hits%/}

            eval "$wm_var=\$wm_hits"
            return 0
        fi
        if [ "$wm_hn" -gt 1 ]; then
            wz_say "  $wm_hn mirrors match '$wm_a' — its number, or more of the name:"
            printf '%s\n' "$wm_hits" | while IFS= read -r wm_h; do
                printf '     %2s) %s\n' \
                    "$(grep -n -x -F -- "$wm_h" "$wm_list" | cut -d: -f1)" \
                    "$(wz_mirror_host "$wm_h")" >&2
            done
            continue
        fi
        wz_say "  no mirror matches '$wm_a', and it is not a URL"
    done
}

# wz_timezone <var>
wz_timezone() {
    wt_var=$1
    wt_root=$(wz_tz_dir)
    if [ -z "$wt_root" ]; then
        wz_say 'No tzdata on this machine to list zones from, so this one is'
        wz_say 'typed. A zone name like America/Sao_Paulo, Europe/Lisbon or UTC;'
        wz_say 'it is checked on the target by setup-timezone.'
        wz_ask "$wt_var" 'Timezone' 'UTC'
        return 0
    fi

    wt_list=$SPORE_WORK/zones
    wz_tz_table "$wt_root" > "$wt_list"
    wt_regions=$(cut -f1 "$wt_list" | grep '/' | cut -d/ -f1 | sort -u)

    wz_say 'Type a zone like America/Sao_Paulo, or part of a city, country or'
    wz_say 'country code to search for one — "sao", "brazil" and "BR" all find'
    wz_say 'the same zone. A region on its own lists what is in it. UTC is a'
    wz_say 'fine answer for a machine that does not care.'
    printf '\n' >&2
    printf '%s\n' "$wt_regions" | tr '\n' ' ' | fold -s -w 72 | sed 's/^/  /' >&2
    printf '\n' >&2

    # What the last search printed, so a number can answer it. A list you have
    # to read back a name out of is a list, not a selector.
    wt_prev=''
    while :; do
        wz_ask wt_a 'Timezone' 'UTC'
        [ -n "$wt_a" ] || continue
        case $wt_a in
            *[!0-9]*) : ;;
            *) if [ -n "$wt_prev" ]; then
                   wt_z=$(printf '%s\n' "$wt_prev" | sed -n "${wt_a}p" | cut -f1)
                   if [ -n "$wt_z" ]; then
                       eval "$wt_var=\$wt_z"
                       return 0
                   fi
                   wz_say "  there is no $wt_a) in the list"
               else
                   wz_say "  '$wt_a' is not a zone, and there is no list to number"
               fi
               continue ;;
        esac
        wt_prev=''
        if awk -F'\t' -v z="$wt_a" '$1 == z { f = 1 } END { exit !f }' "$wt_list"; then
            eval "$wt_var=\$wt_a"
            return 0
        fi
        # A region on its own: show what is in it and ask again, which is how
        # setup-timezone descends.
        if printf '%s\n' "$wt_regions" | grep -qx -- "$wt_a"; then
            wz_say "  zones in $wt_a:"
            awk -F'\t' -v r="$wt_a/" 'index($1, r) == 1 { print substr($1, length(r) + 1) }' \
                "$wt_list" | tr '\n' ' ' | fold -s -w 68 | sed 's/^/     /' >&2
            continue
        fi
        wt_hits=$(wz_tz_search "$wt_list" "$wt_a" 2>/dev/null) || wt_hits=''
        wt_n=0
        [ -z "$wt_hits" ] || wt_n=$(printf '%s\n' "$wt_hits" | grep -c .)
        if [ "$wt_n" = 1 ]; then
            wt_z=$(printf '%s' "$wt_hits" | cut -f1)
            wt_lbl=$(wz_tz_label "" "$(printf '%s' "$wt_hits" | cut -f2)" \
                                   "$(printf '%s' "$wt_hits" | cut -f3)")
            wz_say "  $wt_z${wt_lbl:+ — $wt_lbl}"
            eval "$wt_var=\$wt_z"
            return 0
        fi
        if [ "$wt_n" -gt 1 ] && [ "$wt_n" -le 24 ]; then
            wz_say "  $wt_n zones match '$wt_a':"
            printf '%s\n' "$wt_hits" | awk -F'\t' '
                { d = $2 (($2 != "" && $3 != "") ? " — " : "") $3
                  printf "   %2d) %-28s %s\n", NR, $1, d }
            ' >&2
            wt_prev=$wt_hits
            continue
        fi
        if [ "$wt_n" -gt 24 ]; then
            wz_say "  $wt_n zones match '$wt_a' — too many to list; be more specific"
            continue
        fi
        # Not a zone here and not a search that found one. Taken anyway when it
        # has the shape of a zone name, because this workstation's tzdata is not
        # the target's: setup-timezone there reports one that does not exist, by
        # name, which is a better place to be told than a prompt that refuses.
        case $wt_a in
            */*)
                wz_say "  '$wt_a' is not in this workstation's tzdata — taking it"
                wz_say "  anyway; the machine checks it when it applies."
                eval "$wt_var=\$wt_a"
                return 0 ;;
        esac
        wz_say "  no zone, city or country matches '$wt_a'"
    done
}

# The list is a shortcut, not the whole set. For the keyboard layout the real
# set lives in kbd-bkeymaps on the target and is not knowable from here, so an
# answer that is not on the list is taken as typed — a prompt that refused it
# would be a prompt you could not get past, which this file has been caught by
# once already.
wz_pick_open() { _wz_pick open "$@"; }

# The same thing `spore passwd` does, because it is the same thing: ask twice
# with the echo off, hash it, encrypt the hash. What the wizard adds is only
# that a refusal here is not fatal — the rest of the guided run is still worth
# finishing, and the password can be set afterwards with the command.
wz_seal_password() {
    secret_seal_password "$1" || warn "no password set for $1. Set one later with:
         spore -s $SPORE_DIR passwd $1"
}

wizard() {
    wz_dir=${1:-}

    cat >&2 <<'INTRO'

spore setup — prepare one machine.

Answers go into a directory you keep and edit; nothing here touches a disk.
Press Enter to take the default in brackets.
INTRO

    # --- identity ------------------------------------------------------------
    wz_head 'The machine'
    while :; do
        wz_ask wz_host 'Hostname' 'alpine'
        case $wz_host in
            ''|*[!A-Za-z0-9_-]*) wz_say '  letters, digits, - and _ only' ;;
            *) break ;;
        esac
    done
    # Where it goes is not asked. A directory named on the command line is a
    # destination, so it is checked now rather than after fifteen questions;
    # without one the machine goes straight onto the disk, and there is nothing
    # on this workstation for it to collide with.
    [ -z "$wz_dir" ] || wz_claim_dir "$wz_dir"

    # --- console -------------------------------------------------------------
    wz_head 'Console'
    # Two questions, as setup-keymap asks them, against the set Alpine will
    # actually have — see wz_keymap for where that list comes from.
    wz_keymap wz_keymap
    wz_say ''
    wz_timezone wz_tz
    wz_say ''
    wz_say 'Time sync. A machine with no battery-backed clock boots in 1970, and'
    wz_say 'a clock that far out makes every certificate look not-yet-valid.'
    wz_pick wz_ntp 'NTP client' chrony \
        'chrony=the usual one; a daemon that keeps it right' \
        'busybox=already installed, smaller, less accurate' \
        'openntpd=from OpenBSD' \
        'none=no time sync at all'

    # --- network -------------------------------------------------------------
    wz_head 'Network'
    wz_say 'Interface name. auto takes whichever card the machine turns out to'
    wz_say 'have, which is almost always right from here: predictable naming gives'
    wz_say 'eth0 on one box and enp3s0 on the next, and a name that does not exist'
    wz_say 'means no network at all on a machine nobody is standing in front of.'
    wz_ask wz_iface 'Interface' 'auto'
    # Strict, because this one used to fail silently in the worst direction:
    # anything that was not the literal word "static" fell through to dhcp, so a
    # typo configured the machine for a different network and said nothing.
    wz_pick wz_mode 'Address' dhcp \
        'dhcp=ask the network' \
        'static=an address this spore carries'
    wz_addr='' wz_mask='' wz_gw='' wz_dns=''
    case $wz_mode in
        static)
            while [ -z "$wz_addr" ]; do wz_ask wz_addr 'IP address' ''; done
            wz_ask wz_mask 'Netmask' '255.255.255.0'
            wz_ask wz_gw 'Gateway' ''
            # Not the gateway. It was the default here, and it is the obvious
            # answer — the box that routes usually resolves too. When it does
            # not, everything else works, the gateway answers a ping, and the
            # only thing that complains is apk, blaming the mirror for a name
            # it could not look up. That took twelve boots to see.
            wz_say ''
            wz_say 'A gateway is often also a resolver, and often is not. If it is not,'
            wz_say 'nothing says so: the route works, the gateway pings, and only apk'
            wz_say 'complains — about the mirror. 1.1.1.1 always answers; add the'
            wz_say 'gateway first if it is a resolver you would rather use.'
            wz_ask wz_dns 'DNS servers, space separated' '1.1.1.1'
            ;;
        *) wz_mode=dhcp ;;
    esac
    wz_say ''
    wz_mirror wz_mirror

    # --- account -------------------------------------------------------------
    wz_head 'Account'
    wz_say 'root already exists and is not created here. This is the account you'
    wz_say 'log in as.'
    # Whoever is running this, unless that is root or something a username
    # cannot be — offering back a default the next line will reject is how a
    # prompt becomes unanswerable.
    wz_sug=$(bootstrap_user)
    case $wz_sug in ''|root|*[!a-z0-9_-]*) wz_sug='' ;; esac
    while :; do
        wz_ask wz_user 'Username' "$wz_sug"
        case $wz_user in
            ''|root|*[!a-z0-9_-]*) wz_say '  lowercase letters, digits, - and _; not root' ;;
            *) break ;;
        esac
    done
    wz_yn wz_doas "May $wz_user use doas to become root?" y

    wz_key=$(bootstrap_pubkey)
    if [ -n "$wz_key" ]; then
        wz_ask wz_key 'Public key to install' "$wz_key"
    else
        wz_say ''
        wz_say 'No public key found in your ~/.ssh. Without one, and with root'
        wz_say 'login and password auth off, nothing can reach this machine over'
        wz_say 'the network. Make one with: ssh-keygen -t ed25519'
        wz_ask wz_key 'Public key to install (blank to skip)' ''
    fi
    if [ -n "$wz_key" ] && [ ! -f "$wz_key" ]; then
        die "no such file: $wz_key"
    fi

    # --- ssh -----------------------------------------------------------------
    wz_head 'Remote access'
    if [ -n "$wz_key" ]; then
        wz_yn wz_ssh 'Enable ssh?' y
    else
        wz_say 'ssh cannot be enabled without a key for the account: nothing'
        wz_say 'would be able to log in, and spore refuses to build that.'
        wz_ssh=no
    fi
    wz_port=22
    [ "$wz_ssh" = yes ] && wz_ask wz_port 'ssh port' 22

    # --- files ---------------------------------------------------------------
    wz_head 'Files'
    wz_say 'A web file server over every disk this machine did not boot from:'
    wz_say 'plug one in, it appears. The machine mounts them by UUID, because'
    wz_say 'letters move between boots, and it refuses to share anything carrying'
    wz_say 'a spore or an apkovl — that would put this identity file on the web.'
    wz_yn wz_share 'Share attached disks?' n
    wz_dufs_tls=no wz_dufs_write=no wz_dufs_port=443 wz_share_root=/media/storage
    if [ "$wz_share" = yes ]; then
        wz_ask wz_share_root 'Mount them under' '/media/storage'
        wz_ask wz_dufs_port  'Port' 443
        wz_say ''
        wz_say 'Read-only serves what is there. Read-write also accepts uploads and'
        wz_say 'deletions from anyone who can reach the port.'
        wz_yn wz_dufs_write 'Allow writing?' n
        wz_say ''
        wz_say 'Without TLS the traffic — and any password below — crosses the'
        wz_say 'network in the clear. The certificate is generated on the machine at'
        wz_say 'first boot and never travels in the spore.'
        wz_yn wz_dufs_tls 'HTTPS with a self-signed certificate?' y
    fi

    # --- desktop -------------------------------------------------------------
    wz_head 'Desktop'
    wz_say 'A graphical desktop, rather than a text console. Alpine boots'
    wz_say 'diskless by reinstalling every package in its world file into RAM,'
    wz_say 'every boot — for a file server that is nothing, for a desktop it is'
    wz_say 'the whole desktop each time. spore plan says what that costs.'
    wz_desktop=no wz_desktop_env=''
    wz_yn wz_desktop 'Install a desktop?' n
    if [ "$wz_desktop" = yes ]; then
        wz_say ''
        wz_pick wz_desktop_env 'Which' xfce \
            'xfce=light, and behaves like a desktop' \
            'xfce-wayland=the same on wayland, with a greeter' \
            'sway=lighter still; no greeter, started from a console' \
            'mate=gtk, in the shape of the old gnome 2' \
            'lxqt=qt, light' \
            'gnome=large; a diskless box pays for it on every boot' \
            'plasma=large; likewise'
    fi

    # --- write ---------------------------------------------------------------
    # Built in a staging area first, so where it ends up is still an open
    # question at this point: onto a disk, or into a directory if there is no
    # disk to hand. Answering fifteen questions and then losing them to a
    # failed mount would be its own kind of insult.
    wz_stage=$SPORE_WORK/machine
    mkdir -p "$wz_stage/spore/modules" "$wz_stage/spore/keys" \
             "$wz_stage/spore/secrets" "$wz_stage/spore/files" ||
        die "cannot create $wz_stage"
    SPORE_DIR=$wz_stage/spore

    cat > "$SPORE_DIR/spore.conf" <<CONF
FORMAT=1
HOST=$wz_host
MODULES="repos system net users ssh apkovl$([ "$wz_share" = yes ] && printf ' storage dufs')$([ "$wz_desktop" = yes ] && printf ' desktop')"
# The private key that decrypts this spore's secrets. Relative, so it resolves
# against the spore itself — the same line is correct here and on the target.
SECRETS_IDENTITY=../identity
CONF

    {
        printf 'REPOS_COMMUNITY=yes\n'
        if [ -n "$wz_mirror" ]; then
            printf 'REPOS_MIRROR=%s\n' "$wz_mirror"
        else
            printf '# REPOS_MIRROR=https://mirror.ufpr.br/alpine\n'
        fi
    } > "$SPORE_DIR/modules/repos.conf"

    {
        printf '# As setup-keymap takes them: "<layout> <variant>".\n'
        # Absent, not empty: "leave the layout alone" should read that way in
        # the file too, rather than as a setting someone forgot to fill in.
        if [ -n "$wz_keymap" ]; then
            printf 'SYSTEM_KEYMAP=%s\n' "\"$wz_keymap\""
        else
            printf '# SYSTEM_KEYMAP="br br-abnt2"\n'
        fi
        printf 'SYSTEM_TIMEZONE=%s\n' "$wz_tz"
        printf 'SYSTEM_NTP=%s\n' "$wz_ntp"
    } > "$SPORE_DIR/modules/system.conf"

    {
        printf 'NET_HOSTNAME=%s\n' "$wz_host"
        printf 'NET_IFACE=%s\n'    "$wz_iface"
        printf 'NET_MODE=%s\n'     "$wz_mode"
        if [ "$wz_mode" = static ]; then
            printf 'NET_ADDRESS=%s\n' "$wz_addr"
            printf 'NET_NETMASK=%s\n' "$wz_mask"
            [ -n "$wz_gw" ]  && printf 'NET_GATEWAY=%s\n' "$wz_gw"
            [ -n "$wz_dns" ] && printf 'NET_DNS=%s\n' "\"$wz_dns\""
        fi
    } > "$SPORE_DIR/modules/net.conf"

    {
        printf '# An account is only reachable over ssh if keys/<user>.authorized_keys\n'
        printf '# exists here. spore checks, and refuses to enable ssh if nothing could\n'
        printf '# log in.\n'
        printf 'USERS=%s\n' "\"$wz_user\""
        printf 'USERS_DOAS=%s\n' "$([ "$wz_doas" = yes ] && printf '"%s"' "$wz_user" || printf '""')"
        printf '\n'
        printf '# Passwords travel sealed, never in cleartext:\n'
        printf '#   spore -s <spore> passwd %s\n' "$wz_user"
        printf '#   spore -s <spore> passwd root\n'
    } > "$SPORE_DIR/modules/users.conf"

    {
        printf 'SSH_ENABLED=%s\n' "$wz_ssh"
        printf 'SSH_PORT=%s\n' "$wz_port"
        printf 'SSH_PERMIT_ROOT_LOGIN=no\n'
        printf 'SSH_PASSWORD_AUTH=no\n'
    } > "$SPORE_DIR/modules/ssh.conf"

    {
        printf '# Where lbu commits the apkovl — the only thing that makes a\n'
        printf '# diskless machine remember anything. Unset means beside the spore,\n'
        printf '# on the partition it was found on, which is what you want here.\n'
        printf '# APKOVL_BACKUPDIR=/media/storage/data\n'
    } > "$SPORE_DIR/modules/apkovl.conf"

    if [ "$wz_share" = yes ]; then
        {
            printf '# Every attached filesystem this machine did not boot from is\n'
            printf '# mounted here at each boot, named by UUID — letters move.\n'
            printf 'STORAGE_AUTO=yes\n'
            printf 'STORAGE_AUTO_NAME=uuid\n'
            printf 'STORAGE_ROOT=%s\n' "$wz_share_root"
            printf '# Devices, UUIDs or labels to leave alone:\n'
            printf '# STORAGE_AUTO_EXCLUDE="backup-drive"\n'
            printf '\n'
            # "Allow writing" and "a write lands" are two different settings.
            # Answering yes to the first without knowing about the second is a
            # server that offers an upload button and refuses every upload.
            if [ "$wz_dufs_write" = yes ]; then
                printf '# The server writes as its own account, so the top of each shared\n'
                printf '# disk is handed to it. Without this the filesystem refuses every\n'
                printf '# upload, whatever the server is configured to allow.\n'
                printf 'STORAGE_OWNER=dufs\n'
                printf '# The top of each disk, and only that: a disk that arrives with\n'
                printf '# directories on it keeps them, and they stay read-only to the\n'
                printf '# server. There is no setting to take those over, because this runs\n'
                printf '# on every boot against whatever is plugged in. The service prints\n'
                printf '# the one-off command when it meets such a disk.\n'
            else
                printf '# Read-only, so the mounts keep the ownership their disks carry.\n'
                printf '# If you make the server writable, set STORAGE_OWNER to its account\n'
                printf '# or the filesystem will refuse every upload:\n'
                printf '# STORAGE_OWNER=dufs\n'
            fi
        } > "$SPORE_DIR/modules/storage.conf"

        {
            printf 'DUFS_ENABLED=yes\n'
            printf 'DUFS_SERVE=%s\n' "$wz_share_root"
            printf 'DUFS_BIND=0.0.0.0\n'
            printf 'DUFS_PORT=%s\n' "$wz_dufs_port"
            if [ "$wz_dufs_write" = yes ]; then
                printf 'DUFS_ALLOW_ALL=yes\n'
            else
                printf '# Read-only. DUFS_ALLOW_ALL=yes also accepts uploads and deletes.\n'
            fi
            if [ "$wz_dufs_tls" = yes ]; then
                printf '\n'
                printf '# Generated on the machine at first boot; never travels in the spore.\n'
                printf 'DUFS_TLS_CERT=/etc/dufs/tls/server.crt\n'
                printf 'DUFS_TLS_KEY=/etc/dufs/tls/server.key\n'
                printf 'DUFS_TLS_SELFSIGNED=yes\n'
            fi
            printf '\n'
            printf '# A password, sealed rather than written here:\n'
            printf '#   spore -s <spore> seal dufs-auth   (type e.g. admin:s3cret@/:rw)\n'
            printf '#   DUFS_AUTH_SECRET=dufs-auth\n'
        } > "$SPORE_DIR/modules/dufs.conf"
    fi

    if [ "$wz_desktop" = yes ]; then
        {
            printf '# The environment, as alpine-conf names them. Its package sets are\n'
            printf '# mirrored into plan actions, so "spore plan" lists the whole desktop\n'
            printf '# before any of it exists.\n'
            printf 'DESKTOP_ENV=%s\n' "$wz_desktop_env"
            printf '\n'
            printf '# A browser is a large package and not everyone wants this one.\n'
            printf '# DESKTOP_BROWSER=none  leaves it out entirely.\n'
            printf 'DESKTOP_BROWSER=firefox\n'
            printf '\n'
            printf '# Anything else, space separated:\n'
            printf '# DESKTOP_EXTRA="mpv gimp"\n'
            printf '\n'
            printf '# Who gets the video, input, audio, netdev and seat groups. Unset\n'
            printf '# means whoever USERS names in users.conf, which is the answer that\n'
            printf '# cannot disagree with itself.\n'
            printf '# DESKTOP_USERS="%s"\n' "$wz_user"
        } > "$SPORE_DIR/modules/desktop.conf"
    fi

    : > "$SPORE_DIR/packages"

    [ -n "$wz_key" ] && cp "$wz_key" "$SPORE_DIR/keys/$wz_user.authorized_keys"

    # --- keys and passwords --------------------------------------------------
    wz_keyed=no
    if command -v age-keygen >/dev/null 2>&1 && command -v "$SPORE_AGE" >/dev/null 2>&1; then
        (umask 077; age-keygen -o "$wz_stage/identity" 2>/dev/null) &&
            age-keygen -y "$wz_stage/identity" > "$SPORE_DIR/secrets/recipients" 2>/dev/null &&
            wz_keyed=yes
        chmod 600 "$wz_stage/identity" 2>/dev/null || true
        [ "$wz_keyed" = yes ] || rm -f "$SPORE_DIR/secrets/recipients" "$wz_stage/identity"
    fi

    if [ "$wz_keyed" = yes ] && [ -t 0 ]; then
        wz_head 'Passwords'
        wz_say 'Sealed into the spore and applied at first boot, so nothing has to'
        wz_say 'be typed at the machine. Empty skips.'
        # The prompt itself belongs to secret_ask_password, which prints
        # "Password for <who>: " and then "Again: ". Saying the same thing first
        # put that line on the screen twice and read as being asked twice — so
        # anything added here is context for the answer, never a prompt shaped
        # like the one that follows it.
        if [ "$wz_doas" = yes ]; then
            wz_say ''
            wz_say "doas prompts for $wz_user's own password, so without one it cannot work."
        fi
        wz_say ''
        wz_seal_password "$wz_user"
        wz_say ''
        wz_say 'And root — console rescue only; ssh will not accept it.'
        wz_seal_password root
    elif [ "$wz_keyed" = no ]; then
        warn "age is not installed, so this spore cannot carry secrets and no
         passwords were set. Install age and start again."
    fi

    # --- what now ------------------------------------------------------------
    wz_head "$wz_host is ready"
    printf '\n' >&2
    cat >&2 <<SUMMARY
  $wz_mode on $wz_iface$([ "$wz_mode" = static ] && printf ' (%s)' "$wz_addr")
  account $wz_user$([ "$wz_doas" = yes ] && printf ' with doas')$([ -n "$wz_key" ] && printf ', key installed' || printf ', %sno key%s' "$_c_yellow" "$_c_reset")
  ssh $wz_ssh$([ "$wz_ssh" = yes ] && printf ' on port %s' "$wz_port")
  keymap $wz_keymap, timezone $wz_tz, ntp $wz_ntp
  mirror ${wz_mirror:-whatever the image came with}
SUMMARY

    # A machine goes on a disk. Keeping a second copy on the workstation only
    # raises the question of which one is real — the spore is the portable thing,
    # so it lives where it runs from. A directory is the fallback for when there
    # is no disk in your hand yet, and for anyone who asked for one by name.
    if [ -z "$wz_dir" ] && wz_disk "$wz_stage" "$wz_host"; then
        [ -n "$wz_key" ] || warn "nothing can log in over the network: ssh is off
         because no key was installed."
        return 0
    fi

    wz_land "$wz_stage" "$wz_host"
}

# Move the staged machine into a directory and say what is left to do.
wz_land() {
    wl_stage=$1
    wl_host=$2

    # ~/spores, not ~/machines: a directory in someone's home should say which
    # program put it there, and these are spores.
    if [ -z "$wz_dir" ]; then
        wl_home=$(bootstrap_home)
        wz_dir=${wl_home:+$wl_home/spores}
        wz_dir=${wz_dir:-.}/$wl_host
        wz_claim_dir "$wz_dir"
    fi
    mkdir -p "$(dirname "$wz_dir")" || die "cannot create $(dirname "$wz_dir")"
    mv "$wl_stage" "$wz_dir" || die "cannot write $wz_dir"
    wz_dir=$(CDPATH='' cd -- "$wz_dir" && pwd)

    cat >&2 <<SUMMARY

Saved to $wz_dir — it is not on a disk yet.

  sudo spore media /dev/sdX alpine-standard-*.iso
  sudo spore install $wz_dir /dev/sdX
SUMMARY

    if [ -z "$wz_key" ]; then
        warn "no key was installed, so ssh is off and this machine will only be
         reachable at its console. Put a public key at
         $wz_dir/spore/keys/$wz_user.authorized_keys and set SSH_ENABLED=yes."
    fi
}

# Claim a directory as the destination, replacing a machine already there only
# when told to. Answering yes to a prompt is not consent to delete an arbitrary
# path, so anything that is not already a machine is refused outright.
wz_claim_dir() {
    wc_d=$1
    [ -e "$wc_d" ] || return 0

    [ -f "$wc_d/spore/spore.conf" ] ||
        die "$wc_d already exists and is not a machine directory.
        Name somewhere else:  spore setup <directory>"

    wz_say ''
    wz_say "There is already a machine at $wc_d. Starting again replaces it —"
    if [ -f "$wc_d/identity" ]; then
        wz_say 'including its identity, so every password and host key sealed'
        wz_say 'into it becomes undecryptable.'
    fi
    wz_yn wc_go 'Replace it?' n
    [ "$wc_go" = yes ] ||
        die "left $wc_d alone.
        To change one thing, edit the file rather than starting again:
            \$EDITOR $wc_d/spore/modules/<module>.conf
            sudo spore install $wc_d /dev/sdX"
    rm -rf "$wc_d"
}

# The newest Alpine ISO lying around, so the common case is one Enter.
wz_find_iso() {
    wf_best=''
    for wf_d in "$(bootstrap_home)/Downloads" "$(bootstrap_home)" .; do
        [ -d "$wf_d" ] || continue
        for wf_i in "$wf_d"/alpine-*.iso; do
            [ -f "$wf_i" ] || continue
            if [ -z "$wf_best" ] || [ "$wf_i" -nt "$wf_best" ]; then
                wf_best=$wf_i
            fi
        done
        if [ -n "$wf_best" ]; then
            printf '%s' "$wf_best"
            return 0
        fi
    done
    return 0
}

# Everything from here needs root. The answers were gathered and the directory
# written as the ordinary user on purpose — a machine directory owned by root is
# one you cannot edit afterwards, and editing it afterwards is the whole loop.
wz_disk() {
    wd_dir=$1
    wd_host=$2

    wz_head 'The disk'
    wz_say 'A machine lives on the disk it boots from — that is where this one'
    wz_say 'goes. Answer no and it is saved here instead, to write later.'
    wz_yn wd_go 'Write a USB stick now?' y
    [ "$wd_go" = yes ] || return 1

    wd_sudo=''
    if [ "$(id -u)" != 0 ]; then
        command -v sudo >/dev/null 2>&1 ||
            { warn "sudo is not installed, so the disk cannot be written from here."; return 1; }
        wd_sudo=sudo
    fi

    wz_say ''
    lsblk -dno PATH,SIZE,TRAN,MODEL 2>/dev/null | sed 's/^/  /' >&2 ||
        wz_say '  (lsblk is not installed — you will have to know the path)'
    wz_say ''
    wz_say 'The removable one. Everything on it is destroyed.'
    # Asked again on a typo rather than abandoning the step. Getting a device
    # path slightly wrong is the most ordinary mistake here, and it should cost
    # a retry, not the answers to fifteen questions.
    while :; do
        wz_ask wd_dev 'Device (blank to skip)' ''
        [ -n "$wd_dev" ] || return 1
        if [ ! -b "$wd_dev" ]; then
            warn "$wd_dev is not a block device — pick one from the list above."
            continue
        fi
        # A partition where a disk belongs would be repartitioned as if it were
        # one, which is not what anybody means by it.
        if [ "$(lsblk -dno TYPE "$wd_dev" 2>/dev/null)" = part ]; then
            warn "$wd_dev is a partition. Name the whole disk instead — the one
         without the trailing number."
            continue
        fi
        if ! media_has_medium "$wd_dev"; then
            warn "$wd_dev has nothing in it — the node exists but reports size 0.
         An empty card-reader slot looks exactly like this. The real one has a
         size in the list above."
            continue
        fi
        break
    done

    wz_say ''
    wd_found=$(wz_find_iso)
    while :; do
        wz_ask wd_iso 'Alpine ISO (blank to skip)' "$wd_found"
        [ -n "$wd_iso" ] || return 1
        [ -f "$wd_iso" ] && break
        warn "no such file: $wd_iso"
        # Never offer back a default that was just rejected: pressing Enter on
        # it would ask the same unanswerable question for ever.
        wd_found=''
    done

    # media does its own listing and makes the path be typed back, so the
    # confirmation lives there rather than being asked twice.
    wz_say ''
    "$wd_sudo" "$SPORE_PREFIX/bin/spore" media "$wd_dev" "$wd_iso" ||
        { warn 'the medium was not written; nothing else was done'; return 1; }

    wz_say ''
    "$wd_sudo" "$SPORE_PREFIX/bin/spore" install "$wd_dir" "$wd_dev" ||
        { warn 'the medium is made, but this machine is not on it yet.'; return 1; }

    cat >&2 <<DONE

$wd_host is on $wd_dev. Boot it.

Or boot it here first, in a VM, without touching the medium:

  sudo spore try $wd_dev

To change it later, mount the data partition and edit the files there —
the spore on the disk is the machine, there is no other copy:

  sudo mount ${wd_dev}2 /mnt
  \$EDITOR /mnt/spore/modules/net.conf

then on the machine itself:  spore apply --persist
DONE
    return 0
}
