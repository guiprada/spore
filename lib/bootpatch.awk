# lib/bootpatch.awk — make an extracted ISO's boot config match the medium.
#
# Alpine's grub.cfg finds its root by the ISO9660 volume label, a string with
# spaces and longer than the eleven characters a FAT label can hold. Once the
# image is extracted onto a FAT partition that search can never match, and grub
# reports "no such device" on every boot.
#
# The serial console is the other half: a boot that can only be photographed
# cannot be pasted, and that is most of why a machine failing quietly stays
# quiet.
{
    line = $0
    if (line ~ /search/)
        gsub(/(--label|--fs-label|-l)[ \t]+("[^"]*"|'[^']*'|[^ \t]+)/, "--label " LBL, line)
    if (line ~ /^[ \t]*(linux|linuxefi|linux16|kernel|append|APPEND)[ \t]/ && line !~ /console=ttyS0/)
        line = line " console=tty0 console=ttyS0,115200"
    print line
}
