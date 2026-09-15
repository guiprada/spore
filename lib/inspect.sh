# lib/inspect.sh — what happened on that medium.
#
# The evidence after a failed boot is all on the data partition: the log the seed
# wrote, whether an apkovl was ever committed, and which version of the tool is
# actually baked into the overlay. Getting at it meant mount, cat, umount, three
# paths typed by hand — so it did not get looked at, and four rounds of this were
# spent inferring from symptoms instead of reading it.

inspect_stale() {
    # Is the seed on this medium the one this tool would build? A fix made on the
    # workstation reaches the machine only through `spore install`, and a boot
    # that still fails the same way is otherwise indistinguishable from a fix
    # that did not land.
    #
    # Every file the seed carries, not four of them. Sampling lib/seed.sh,
    # lib/plan.sh, modules/net.sh and bin/spore said "matches this tool" about a
    # medium whose persist.sh was two commits old — and persist.sh was the file
    # the question was about. A staleness check you cannot trust is worse than
    # none, because the next thing you do is re-read a log that cannot have
    # changed.
    is_seed=$1
    is_differ=''
    is_count=0

    # bin, lib and modules: the tool tree the seed copies. Not seed-run, which
    # seed_build writes rather than copies and which therefore has nothing here
    # to be compared against — a change to it is a change to lib/seed.sh, and
    # that is compared.
    tar -tzf "$is_seed" 2>/dev/null |
        sed -n 's|^\./usr/local/lib/spore/||p' |
        grep -E '^(bin|lib|modules)/.*[^/]$' |
        sort > "$SPORE_WORK/seed.files" 2>/dev/null || true
    ( cd "$SPORE_PREFIX" 2>/dev/null &&
      find bin lib modules -type f 2>/dev/null | sort ) > "$SPORE_WORK/here.files" 2>/dev/null || true

    while IFS= read -r is_f; do
        [ -n "$is_f" ] || continue
        is_count=$((is_count + 1))
        if [ ! -f "$SPORE_PREFIX/$is_f" ]; then
            is_differ="$is_differ $is_f(gone-here)"
            continue
        fi
        is_there=$(tar -xzOf "$is_seed" "./usr/local/lib/spore/$is_f" 2>/dev/null |
                   sha256sum 2>/dev/null | cut -d' ' -f1)
        is_here=$(sha256_file "$SPORE_PREFIX/$is_f" 2>/dev/null || true)
        [ "$is_there" = "$is_here" ] || is_differ="$is_differ $is_f"
    done < "$SPORE_WORK/seed.files"

    # And the other way round. A file added since this seed was built is simply
    # absent from it, and comparing only what the seed has would never notice —
    # which is how a whole new module reaches nothing.
    while IFS= read -r is_f; do
        [ -n "$is_f" ] || continue
        grep -qxF "$is_f" "$SPORE_WORK/seed.files" 2>/dev/null ||
            is_differ="$is_differ $is_f(not-in-seed)"
    done < "$SPORE_WORK/here.files"

    if [ "$is_count" = 0 ]; then
        printf 'the seed carries no copy of the tool at all'
        return 0
    fi

    is_differ=${is_differ# }
    # Long enough to name the culprit, short enough to read.
    is_n=0
    for is_w in $is_differ; do is_n=$((is_n + 1)); done
    if [ "$is_n" -gt 8 ]; then
        is_differ="$(printf '%s' "$is_differ" | cut -d" " -f1-8) and $((is_n - 8)) more"
    fi
    printf '%s' "$is_differ"
}

# A live seed on the boot partition is exactly what you want until the machine
# has committed, and a coin toss afterwards. Alpine's initramfs-init:
#
#     if [ -z "$KOPT_apkovl" ]; then
#         # Not manually set, use the apkovl found by nlplug
#         if [ -e "$ROOT"/tmp/apkovls ]; then
#             ovl=$(head -n 1 "$ROOT"/tmp/apkovls)
#
# `nlplug-findfs -a` writes every apkovl it finds across every block device, and
# init takes the first line. So a seed on one partition and a committed overlay
# on the other is two apkovls, and which machine comes up is probe order — the
# first partition, usually.
#
# Neither outcome is broken, but they are different machines. Booted from the
# seed, /etc/spore/.seeded is absent and the whole spore is applied again,
# packages and all; booted from the committed overlay, the seed service finds
# the stamp and goes straight through.
#
# And the log says which of them it was, so this does not have to guess. /var/log
# is on the RAM root, so the copy saved beside the spore is the last boot and
# only the last boot: a full apply in it means that boot came up from a seed,
# because the committed overlay carries /etc/spore/.seeded and the seed service
# stops at it before applying anything.
inspect_seed_race() {
    isr_boot=$1 isr_data=$2 isr_dev=${3:-/dev/sdX}
    [ -f "$isr_boot/spore-seed.apkovl.tar.gz" ] || return 0
    find "$isr_data" -maxdepth 1 -name '*.apkovl.tar.gz' ! -name 'spore-seed.*' \
        2>/dev/null | grep -q . || return 0

    isr_last=''
    if [ -f "$isr_data/spore-seed.log" ]; then
        if grep -q 'already converged; nothing to do' "$isr_data/spore-seed.log"; then
            isr_last="
         The last boot used the committed overlay: it found the stamp and
         stopped before applying anything. So the scan has been landing on the
         right one — which is probe order, not a setting."
        elif grep -q 'changed,.*already correct' "$isr_data/spore-seed.log"; then
            isr_last="
         The last boot did not use it: its log is a full apply, and that only
         happens when there was no stamp to find, so that boot came up from a
         seed and did the whole spore again."
        fi
    fi

    warn "there is also a committed overlay on the data partition, so this medium
         holds two apkovls and the initramfs takes whichever it finds first.$isr_last
         To hand the machine over to its own overlay:
             sudo ${SPORE_SELF:-spore} retire $isr_dev
         Keep the seed instead until you have seen the machine boot without it:
         it is the only thing that recovers this medium if the initramfs turns
         out not to be able to read the data partition. \`spore install\` writes
         a fresh one whenever it runs."
}

inspect_data() {
    id_dir=$1
    id_dev=${2-}

    printf '\non the data partition\n\n' >&2
    # shellcheck disable=SC2012  # a listing for a human, not a pipeline
    ls -la "$id_dir" 2>/dev/null | sed 's/^/  /' >&2

    if [ -f "$id_dir/spore/spore.conf" ]; then
        printf '\nthe spore\n\n' >&2
        printf '  host      %s\n' "$(conf_get "$id_dir/spore/spore.conf" HOST '?')" >&2
        printf '  modules   %s\n' "$(conf_get "$id_dir/spore/spore.conf" MODULES '?')" >&2
        printf '  identity  %s\n' \
            "$([ -f "$id_dir/identity" ] && printf 'present' || printf 'MISSING — sealed secrets cannot be decrypted')" >&2
        id_secrets=$(find "$id_dir/spore/secrets" -name '*.age' 2>/dev/null | wc -l | tr -d ' ')
        printf '  secrets   %s sealed\n' "${id_secrets:-0}" >&2
        id_keys=$(find "$id_dir/spore/keys" -name '*.authorized_keys' 2>/dev/null | wc -l | tr -d ' ')
        printf '  keys      %s\n' "${id_keys:-0}" >&2
    else
        warn "no spore/ here. The machine had nothing to apply."
    fi

    if [ -f "$id_dir/spore-seed.apkovl.tar.gz" ]; then
        printf '\nthe seed\n\n' >&2
        id_stale=$(inspect_stale "$id_dir/spore-seed.apkovl.tar.gz")
        if [ -n "$id_stale" ]; then
            printf '  %sbuilt from a different version of this tool%s\n' "$_c_red" "$_c_reset" >&2
            printf '  differing: %s\n' "$id_stale" >&2
            printf '  A fix made here reaches the machine only through spore install.\n' >&2
        else
            printf '  %smatches this tool%s\n' "$_c_green" "$_c_reset" >&2
        fi
    elif [ -f "$id_dir/spore-seed.superseded.tar.gz" ]; then
        # Not missing: retired. A commit sets the seed aside, because lbu will
        # not write into a directory holding an apkovl it did not write, and two
        # apkovls on one filesystem means the initramfs boots whichever it finds
        # first. Reporting that as "nothing would have run" describes the
        # opposite of what happened.
        printf '\nthe seed\n\n' >&2
        printf '  %sset aside after a commit%s — spore-seed.superseded.tar.gz\n' \
            "$_c_green" "$_c_reset" >&2
        printf '  Its job was to get the first boot to apply the spore, and it did.\n' >&2
        # And no further than that. Which apkovl the machine boots next is not
        # decided here: the initramfs scans every block device, and this is one
        # of them. Saying "it now boots from its own committed overlay" read as
        # a verdict on the machine when it was only a fact about this directory
        # — and it was wrong whenever a seed was still sitting on the boot
        # partition, which is where install always puts a second copy. The
        # boot-partition section below is where both halves are known.
        printf '  Nothing on this partition competes with the committed overlay now.\n' >&2
    else
        warn "no spore-seed.apkovl.tar.gz here, so nothing would have run at all."
    fi

    # The one thing that proves it got all the way through.
    printf '\ncommitted\n\n' >&2
    if id_ovl=$(find "$id_dir" -maxdepth 1 -name '*.apkovl.tar.gz' \
                     ! -name 'spore-seed.*' 2>/dev/null | head -1) && [ -n "$id_ovl" ]; then
        printf '  %s%s%s — it converged and committed at least once\n' \
            "$_c_green" "$(basename "$id_ovl")" "$_c_reset" >&2
    else
        printf '  nothing. The machine never finished an apply --persist here.\n' >&2
    fi

    printf '\nthe log\n\n' >&2
    if [ -f "$id_dir/spore-seed.log" ]; then
        # A log older than the seed beside it is from a boot that ran different
        # code. It reads exactly like fresh evidence, and a whole round can go
        # into explaining a failure that has already been replaced.
        if [ -f "$id_dir/spore-seed.apkovl.tar.gz" ] &&
           [ "$id_dir/spore-seed.apkovl.tar.gz" -nt "$id_dir/spore-seed.log" ]; then
            printf '  %sthis log is older than the seed next to it%s — it is from a boot\n' \
                "$_c_red" "$_c_reset" >&2
            printf '  before the last install, so it says nothing about the current code.\n\n' >&2
            # And the commonest reason it stays old is not that nobody booted.
            # `spore try` runs the medium under -snapshot unless told `write`,
            # so the machine writes its log and qemu discards it on exit — the
            # medium is never touched, by design, and this file can therefore
            # sit unchanged through any number of reinstalls and boots. The
            # boot console is captured to a file on the host instead, and that
            # is the one with the answer in it.
            printf '  If you booted it with %s try%s, that is expected: writes go to a\n' \
                "$SPORE_SELF" "$_c_reset" >&2
            printf '  snapshot and are thrown away, so nothing here can change. Read\n' >&2
            printf '  spore-boot.log where you ran it, or boot with:\n' >&2
            printf '      sudo %s try %s write\n' "$SPORE_SELF" "${id_dev:-/dev/sdX}" >&2
            printf '  Otherwise boot the machine again before reading what follows.\n\n' >&2
        fi
        sed 's/^/  /' "$id_dir/spore-seed.log" >&2
    else
        printf '  no spore-seed.log.\n' >&2
        printf '  The seed never reached the point of writing one, which means its\n' >&2
        printf '  service did not start. Boot with a console and look for\n' >&2
        printf '  "spore: looking for a spore to germinate" — if that line is absent,\n' >&2
        printf '  the overlay did not load or OpenRC did not run the service.\n' >&2
    fi
    inspect_vm_log "$id_dir"
    printf '\n' >&2
}

# The other log, the one on this side. `spore try` captures the guest's console
# to spore-boot.log here, and under -snapshot that is the only record a VM boot
# leaves — the medium's own log cannot change, by design. Looking at the medium
# and being told nothing happened, while the answer sits in the working
# directory, is a trap this command laid for its own user repeatedly.
inspect_vm_log() {
    ivl_dir=$1
    ivl_log=${SPORE_TRY_LOG:-$PWD/spore-boot.log}
    [ -f "$ivl_log" ] || return 0
    # Only when it is the fresher of the two: an old boot log next to a current
    # medium log would be the same confusion pointing the other way.
    if [ -f "$ivl_dir/spore-seed.log" ] && [ "$ivl_dir/spore-seed.log" -nt "$ivl_log" ]; then
        return 0
    fi
    printf '\nthe last VM boot\n\n' >&2
    printf '  %s is newer than the log on the medium.\n' "$ivl_log" >&2
    try_report "$ivl_log"
}

# inspect_medium <device|directory>
inspect_medium() {
    im2_target=$1
    [ -e "$im2_target" ] || die "no such device or directory: $im2_target"

    if [ -d "$im2_target" ]; then
        inspect_data "$im2_target"
        return 0
    fi

    [ -b "$im2_target" ] || die "$im2_target is neither a block device nor a directory"
    [ "$(id -u)" = 0 ] || die "reading $im2_target needs root:
             sudo $SPORE_SELF inspect $im2_target"
    media_has_medium "$im2_target" || die "$im2_target has no medium in it"

    im2_p2=$(media_part "$im2_target" 2)
    [ -b "$im2_p2" ] ||
        die "$im2_p2 does not exist, so this is not a spore medium.
        Make one:  spore media $im2_target alpine-standard-*.iso"

    mkdir -p "$SPORE_WORK/look"
    # Read-only throughout: this is for looking at a medium that already went
    # wrong once, and it must not be the thing that changes it.
    mount -o ro "$im2_p2" "$SPORE_WORK/look" ||
        die "cannot mount $im2_p2 — unmount it elsewhere first, or it is not ext4"
    SPORE_UNMOUNT="$SPORE_WORK/look"

    printf '%s\n' "$im2_target" >&2
    inspect_data "$SPORE_WORK/look" "$im2_target"

    # The boot partition matters only for whether the seed could be found there.
    im2_p1=$(media_part "$im2_target" 1)
    mkdir -p "$SPORE_WORK/look1"
    if [ -b "$im2_p1" ] && mount -o ro "$im2_p1" "$SPORE_WORK/look1" 2>/dev/null; then
        SPORE_UNMOUNT="$SPORE_WORK/look1 $SPORE_UNMOUNT"
        printf 'on the boot partition\n\n' >&2
        # Alpine keeps its kernel modules in a squashfs here, not in the RAM
        # root, and the initramfs identifies this medium by .alpine-release. If
        # either did not survive the ISO extraction, the machine boots with only
        # the drivers the kernel and initramfs carry — enough for USB and ext4,
        # not enough for a network card — and the symptom is a box with no
        # interface at all, which reads like anything but a boot medium problem.
        im2_rel=no
        [ -f "$SPORE_WORK/look1/.alpine-release" ] && im2_rel=yes
        im2_ml=$(find "$SPORE_WORK/look1/boot" -maxdepth 1 -name 'modloop-*' \
                 2>/dev/null | wc -l | tr -d ' ')
        im2_kern=$(find "$SPORE_WORK/look1/boot" -maxdepth 1 -name 'vmlinuz-*' \
                   2>/dev/null | wc -l | tr -d ' ')
        printf '  .alpine-release %s, %s modloop, %s kernel\n' \
            "$im2_rel" "${im2_ml:-0}" "${im2_kern:-0}" >&2
        if [ "$im2_rel" = no ] || [ "${im2_ml:-0}" = 0 ]; then
            warn "without both of those the initramfs cannot mount the modloop, so
         the machine comes up with no kernel modules and so no network card at
         all. Re-run \`spore media\` from the ISO."
        fi
        if [ -f "$SPORE_WORK/look1/spore-seed.apkovl.tar.gz" ]; then
            printf '  spore-seed.apkovl.tar.gz — the initramfs can certainly read this one\n' >&2
            inspect_seed_race "$SPORE_WORK/look1" "$SPORE_WORK/look" "$im2_target"
        else
            printf '  no seed here. If the machine boots without running spore, the\n' >&2
            printf '  initramfs could not read the data partition; put a copy here:\n' >&2
            printf '      sudo %s install <dir> %s\n' "$SPORE_SELF" "$im2_target" >&2
        fi
        # Whether media's rewrite actually reached this medium. A boot that
        # still says "no such device" and still shows no kernel output is
        # otherwise indistinguishable from a rewrite that never ran, matched
        # nothing, or patched a file the firmware does not read.
        im2_cfgs=0 im2_serial=0 im2_isolabel=0
        find "$SPORE_WORK/look1" -maxdepth 5 -type f \
             \( -name '*.cfg' -o -name '*.conf' \) 2>/dev/null > "$SPORE_WORK/espcfgs" || true
        while IFS= read -r im2_c; do
            [ -n "$im2_c" ] || continue
            grep -qE '(^|[ \t])(linux|linuxefi|linux16|kernel|append|APPEND)[ \t]' "$im2_c" 2>/dev/null ||
                grep -q 'search' "$im2_c" 2>/dev/null || continue
            im2_cfgs=$((im2_cfgs + 1))
            grep -q 'console=ttyS0' "$im2_c" 2>/dev/null && im2_serial=$((im2_serial + 1))
            grep -qE 'search.*(alpine-std|alpine-ext|[0-9]+\.[0-9]+\.[0-9]+ )' "$im2_c" 2>/dev/null &&
                im2_isolabel=$((im2_isolabel + 1))
        done < "$SPORE_WORK/espcfgs"
        # The seed writes its log beside whichever partition carrying the seed
        # it could mount — the FAT one needs no module, so it is often the only
        # one reachable when the failure is that nothing else could be read.
        if [ -f "$SPORE_WORK/look1/spore-seed.log" ]; then
            printf '\n  the log, from here:\n\n' >&2
            sed 's/^/    /' "$SPORE_WORK/look1/spore-seed.log" >&2
            printf '\n' >&2
        fi
        printf '  boot configs: %s found, %s with a serial console' "$im2_cfgs" "$im2_serial" >&2
        [ "$im2_isolabel" -gt 0 ] && printf ', %s still searching for the ISO label' "$im2_isolabel" >&2
        printf '\n' >&2
        if [ "$im2_cfgs" -gt 0 ] && [ "$im2_serial" = 0 ]; then
            warn "none of them carry console=ttyS0, so this medium was written
         before that rewrite existed, or the rewrite matched nothing. Re-run
         \`spore media\` and watch for the line naming how many it changed."
        fi
        if [ "$im2_cfgs" = 0 ]; then
            warn "no boot configuration files here at all. This image's grub
         config is embedded in its EFI binary, which nothing on this side can
         rewrite — the failing label search cannot be fixed by editing files."
        fi

        for im2_stray in "$SPORE_WORK/look1"/*.apkovl.tar.gz; do
            case $im2_stray in */spore-seed.apkovl.tar.gz|*'*'*) continue ;; esac
            warn "$(basename "$im2_stray") is also here, from the ISO. The initramfs
         loads the first apkovl it finds, so this one may be winning."
        done
        printf '\n' >&2
    fi
    spore_cleanup
}
