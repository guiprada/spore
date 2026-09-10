# lib/core.sh — logging, workspace, mutation guards.
#
# Two guards carry the whole design:
#   run()     every external command; suppressed under --dry-run, recorded for tests
#   rootpath() every filesystem path; prefixed by $SPORE_ROOT so the executor can be
#             pointed at a temp dir (tests) or a staging tree (future `build`)

SPORE_VERSION=0.1.0

: "${SPORE_ROOT:=/}"
: "${SPORE_DRYRUN:=0}"
: "${SPORE_NOEXEC:=0}"
: "${SPORE_RUN_LOG:=}"
: "${SPORE_COLOR:=auto}"

SPORE_TAB=$(printf '\t')

_c_reset='' _c_dim='' _c_bold='' _c_red='' _c_green='' _c_yellow=''
if [ "$SPORE_COLOR" = always ] || { [ "$SPORE_COLOR" = auto ] && [ -t 2 ]; }; then
    _c_reset=$(printf '\033[0m')
    _c_dim=$(printf '\033[2m')
    _c_bold=$(printf '\033[1m')
    _c_red=$(printf '\033[31m')
    _c_green=$(printf '\033[32m')
    _c_yellow=$(printf '\033[33m')
fi

log()  { printf '%s\n' "$*" >&2; }
say()  { printf '  %s\n' "$*" >&2; }
die() {
    # Report progress before leaving: a run that aborts halfway is exactly when
    # you most want to know how far it got.
    if [ $((SPORE_N_CHANGED + SPORE_N_UNCHANGED)) -gt 0 ]; then
        printf '\n  %s changed, %s already correct, then stopped\n' \
            "$SPORE_N_CHANGED" "$SPORE_N_UNCHANGED" >&2
    fi
    printf '%serror:%s %s\n' "$_c_red" "$_c_reset" "$*" >&2
    exit 1
}
warn() { printf '%swarning:%s %s\n' "$_c_yellow" "$_c_reset" "$*" >&2; }

SPORE_N_CHANGED=0
SPORE_N_UNCHANGED=0
changed()   { SPORE_N_CHANGED=$((SPORE_N_CHANGED + 1));   printf '  %s+ %s%s\n' "$_c_green" "$*" "$_c_reset" >&2; }
unchanged() { SPORE_N_UNCHANGED=$((SPORE_N_UNCHANGED + 1)); printf '  %s. %s%s\n' "$_c_dim" "$*" "$_c_reset" >&2; }
skipped()   { printf '  %s~ %s%s\n' "$_c_yellow" "$*" "$_c_reset" >&2; }

# --- workspace ---------------------------------------------------------------

spore_workspace() {
    if [ -z "${SPORE_WORK:-}" ]; then
        SPORE_WORK=$(mktemp -d "${TMPDIR:-/tmp}/spore.XXXXXX") || die "cannot create workspace"
        SPORE_WORK_OWNED=1
    fi
    mkdir -p "$SPORE_WORK/content"
    SPORE_PLAN=$SPORE_WORK/plan.tsv
    : > "$SPORE_WORK/persist.list"
    : > "$SPORE_WORK/notes"
}

spore_cleanup() {
    if [ "${SPORE_WORK_OWNED:-0}" = 1 ] && [ -n "${SPORE_WORK:-}" ]; then
        rm -rf "$SPORE_WORK"
    fi
    return 0
}

# --- guards ------------------------------------------------------------------

# Join an absolute target path onto $SPORE_ROOT.
rootpath() {
    case "$SPORE_ROOT" in
        /|'') printf '%s' "$1" ;;
        *)    printf '%s%s' "${SPORE_ROOT%/}" "$1" ;;
    esac
}

sha256_file() { sha256sum "$1" | cut -d' ' -f1; }

# False under --dry-run, so callers announce instead of acting.
mutate() { [ "$SPORE_DRYRUN" != 1 ]; }

# A root that is not / is *synthetic*: the host's own tools (apk, rc-update, lbu)
# must not be run against the real system, so the executor writes the state those
# tools would have produced instead. That single rule is what makes the whole
# apply path testable off-Alpine, and it is the seed of the staging executor
# `build` will need.
synthetic() { [ "$SPORE_ROOT" != / ]; }

runlog() {
    if [ -n "$SPORE_RUN_LOG" ]; then
        printf '%s\n' "$*" >> "$SPORE_RUN_LOG"
    fi
}

# Every external command goes through here.
run() {
    runlog "$*"
    if [ "$SPORE_DRYRUN" = 1 ]; then
        say "would run: $*"
        return 0
    fi
    if [ "$SPORE_NOEXEC" = 1 ] || synthetic; then
        return 0
    fi
    if "$@"; then
        return 0
    fi
    die "${SPORE_ACTION:+while $SPORE_ACTION: }command failed: $*"
}

fetch_url() {
    # busybox wget has no file:// support, and a blob on mounted media is a
    # legitimate thing to reference — copy directly rather than shelling out.
    case $1 in
        file://*) cp -- "${1#file://}" "$2"; return $? ;;
    esac
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$2" -- "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" -- "$1"
    else
        die "neither curl nor wget available to fetch $1"
    fi
}
