# lib/render.sh — config file rendering.
#
# Priority when touching an existing config: a drop-in directory if the package
# supports one, otherwise a block this tool owns. Never a blind sed.

SPORE_MARK_BEGIN='# BEGIN spore'
SPORE_MARK_END='# END spore'

# render_marked_block <path> <marker> <content>
# Prints the full new file: existing content with any previous block of the same
# marker stripped, then the block appended. Re-rendering an unchanged block
# reproduces the file byte for byte, which is what makes it idempotent.
render_marked_block() {
    rmb_path=$1 rmb_marker=$2 rmb_content=$3
    rmb_begin="$SPORE_MARK_BEGIN:$rmb_marker"
    rmb_end="$SPORE_MARK_END:$rmb_marker"
    rmb_real=$(rootpath "$rmb_path")

    if [ -f "$rmb_real" ]; then
        awk -v b="$rmb_begin" -v e="$rmb_end" '
            $0 == b { skip = 1 }
            !skip   { print }
            $0 == e { skip = 0 }
        ' "$rmb_real"
    fi
    printf '%s\n%s\n%s\n' "$rmb_begin" "$rmb_content" "$rmb_end"
}

# Alpine patches `Include /etc/ssh/sshd_config.d/*.conf` in near the TOP of
# sshd_config (include-config-dir.patch), and OpenSSH takes the first value it
# sees for a directive — so a drop-in overrides the main file rather than being
# overridden by it. That makes the drop-in branch the correct one on Alpine; the
# marked-block fallback is for anything that ships without the patch.
sshd_include_supported() {
    ssi_f=$(rootpath /etc/ssh/sshd_config)
    [ -f "$ssi_f" ] &&
        grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$ssi_f"
}
