# modules/desktop.sh — a graphical desktop.
#
# Alpine ships setup-desktop, and this does not call it. Three reasons, each
# found by reading it rather than by running it:
#
#   * it ends in `rc-update del acpid`, so its exit status is that delete's —
#     non-zero on a machine where acpid was never enabled, which is every
#     diskless one. The same shape as setup-ntp, which cost this project a
#     whole apply once already.
#   * it reaches setup-wayland-base and setup-devd, which `rc-service ... start`
#     services belonging to sysinit and the boot runlevel. Run from inside the
#     seed service — in the default runlevel, which is where this always runs —
#     OpenRC refuses those, because it will not re-enter a runlevel that has
#     finished.
#   * given no argument it calls setup-user, which prompts, and a prompt cannot
#     be answered on a machine that is booting itself.
#
# So the package sets below are upstream's, mirrored deliberately, the same way
# render_keymap does what setup-keymap does once it has a valid pair. Everything
# becomes a pkg or svc action, which means `spore plan` shows the whole desktop
# before it exists, `spore diff` can see it drift, and a later `build` gets it
# for free. The lists come from alpine-conf's setup-desktop, setup-xorg-base and
# setup-wayland-base; when they move upstream, they move here.
#
# One thing of upstream's is deliberately inverted rather than mirrored:
# `rc-update del acpid`. See desktop_plan_acpid.

DESKTOP_ENVS='xfce xfce-wayland gnome plasma mate sway lxqt'

desktop_meta() {
    MOD_DESC='a graphical desktop'
    MOD_REQUIRES='root init.openrc'
}

# The device manager. Alpine boots diskless with mdev + hwdrivers in sysinit;
# Xorg's libinput driver and elogind's seat management both want udev, which is
# why both of upstream's base scripts end in `setup-devd udev`. Expressed as
# actions, the switch is the same one setup-devd makes.
desktop_plan_udev() {
    plan_pkg eudev
    plan_pkg udev-init-scripts
    plan_pkg udev-init-scripts-openrc
    plan_svc udev sysinit on
    plan_svc udev-trigger sysinit on
    plan_svc udev-settle sysinit on
    plan_svc udev-postmount default on
    # Two managers for one /dev is worse than either, so the old one goes.
    plan_svc mdev sysinit off
    plan_svc hwdrivers sysinit off

    # sysinit ran long before anything here did, and OpenRC will not re-enter a
    # finished runlevel. The links are correct now; /dev is still mdev's until
    # the machine is restarted, which is why a desktop is never up on the boot
    # that installs it.
    plan_note "desktop: /dev moves from mdev to udev, and sysinit — where that
         happens — ran before this did. Input devices, seats and the display
         manager come up on the *next* boot, not this one. A first boot that
         ends at a text console has worked."
}

desktop_plan() {
    dt_de=$(mconf DESKTOP_ENV '')
    if [ -z "$dt_de" ] || [ "$dt_de" = none ]; then
        plan_note "desktop: DESKTOP_ENV is unset, so nothing graphical is
         installed. One of: $DESKTOP_ENVS."
        return 0
    fi
    case " $DESKTOP_ENVS " in
        *" $dt_de "*) : ;;
        *) die "desktop: DESKTOP_ENV is one of $DESKTOP_ENVS — not '$dt_de'" ;;
    esac

    # setup-desktop takes $BROWSER and defaults it to firefox. A browser is a
    # large package and not everyone wants that one, so it is named rather than
    # assumed, and 'none' is allowed — which upstream's ${BROWSER:-firefox}
    # cannot express.
    dt_browser=$(mconf DESKTOP_BROWSER firefox)
    dt_extra=$(mconf DESKTOP_EXTRA '')

    case $dt_de in
        xfce|mate|lxqt) dt_stack=xorg ;;
        *)              dt_stack=wayland ;;
    esac

    if [ "$dt_stack" = xorg ]; then
        # setup-xorg-base
        for dt_p in xorg-server xf86-input-libinput xinit mesa-dri-gallium; do
            plan_pkg "$dt_p"
        done
    else
        # setup-wayland-base. cgroups is not in the runlevel set a diskless
        # Alpine boots with, and elogind wants it.
        desktop_plan_elogind
    fi
    desktop_plan_udev

    case $dt_de in
        xfce)
            for dt_p in xfce4 elogind gvfs lightdm lightdm-gtk-greeter \
                        polkit-elogind xfce4-screensaver xfce4-terminal font-dejavu; do
                plan_pkg "$dt_p"
            done
            desktop_plan_elogind
            desktop_plan_dm lightdm
            desktop_plan_gtk_dark ;;
        xfce-wayland)
            for dt_p in xfce4 adwaita-icon-theme elogind greetd-gtkgreet gvfs \
                        labwc polkit-elogind xfce4-screensaver xfce4-terminal; do
                plan_pkg "$dt_p"
            done
            desktop_plan_dm greetd
            desktop_plan_gtk_dark
            desktop_plan_greetd ;;
        mate)
            for dt_p in mate-desktop-environment gvfs lightdm lightdm-gtk-greeter \
                        polkit dbus dbus-x11 font-dejavu; do
                plan_pkg "$dt_p"
            done
            desktop_plan_dm lightdm ;;
        lxqt)
            for dt_p in lxqt-desktop lximage-qt obconf-qt pavucontrol-qt arandr \
                        sddm font-dejavu dbus dbus-x11 openbox elogind \
                        polkit-elogind gvfs udisks2 adwaita-qt oxygen; do
                plan_pkg "$dt_p"
            done
            desktop_plan_elogind
            desktop_plan_dm sddm ;;
        gnome)
            # Upstream expands `apk info --depends gnome gnome-apps-core` so each
            # package lands in world explicitly. That needs the target's network
            # at the moment the list is built, which a plan made on a workstation
            # does not have — so the meta-packages are planned instead. Same
            # software; apk may drop a piece later as an unused dependency where
            # upstream's expansion would keep it.
            plan_pkg gnome
            plan_pkg gnome-apps-core
            desktop_plan_dm gdm ;;
        plasma)
            plan_pkg plasma-desktop-meta
            plan_pkg kde-applications-base
            desktop_plan_dm sddm ;;
        sway)
            for dt_p in brightnessctl font-dejavu foot grim i3status sway swaybg \
                        swayidle swaylockd util-linux-login wl-clipboard wmenu xwayland; do
                plan_pkg "$dt_p"
            done
            # No display manager upstream, and none here: sway is started from a
            # tty by the account that logs in.
            plan_note "desktop: sway has no display manager. Log in on a text
         console and run \`sway\`; there is no greeter to reach it through." ;;
    esac

    if [ -n "$dt_browser" ] && [ "$dt_browser" != none ]; then
        case $dt_browser in
            *[!A-Za-z0-9_.+-]*) die "desktop: DESKTOP_BROWSER is a package name, or none" ;;
        esac
        plan_pkg "$dt_browser"
    fi
    for dt_p in $dt_extra; do
        plan_pkg "$dt_p"
    done

    desktop_plan_acpid
    desktop_plan_groups
    desktop_plan_diskless "$dt_de"
}

# The power button.
#
# setup-desktop ends in `rc-update del acpid`, outside its case, so it fires for
# every environment. The reasoning is sound where it applies: a desktop session
# has its own power manager — xfce4-power-manager is in the xfce set above — and
# two things acting on one button press is worse than one.
#
# But it only applies inside a running session. At the text console, at the
# greeter before anyone has logged in, and on sway, which ships no power manager
# at all, nothing is listening and the button does nothing. The way you then turn
# the machine off is by holding it down, and on a diskless host that is how you
# lose the overlay you have not committed yet. A machine whose power button does
# nothing is not a machine with one fewer feature; it is one you can only
# shut down uncleanly.
#
# So acpid goes in. Alpine's /etc/acpi/handler.sh already does the right thing
# with it — `button/power:PWRF` powers off, or suspends if the machine has a lid,
# so a laptop is not surprised. The init script is an ordinary default-runlevel
# service (`need dev localmount`, `after hwdrivers modules`).
desktop_plan_acpid() {
    plan_pkg acpid
    plan_svc acpid default on
    plan_note "desktop: acpid is installed, so the power button shuts the
         machine down from the console and from the greeter, where the desktop's
         own power manager is not running yet. Inside a session both are
         listening; if that double-acts on your hardware, drop this one with
         \`rc-update del acpid default\` and let the desktop keep it."
}

# Every display manager Alpine packages declares dbus as a hard dependency, in
# those words, in its own init script:
#
#     community/lightdm/lightdm.initd   need localmount dbus
#     community/sddm/sddm.initd         need dbus localmount
#     community/gdm/gdm.initd           need dbus
#
# so a display manager in a runlevel where dbus is in none is a display manager
# that does not come up. setup-desktop adds dbus for mate, for lxqt and for
# xfce-wayland — and not for xfce, whose display manager is the same lightdm as
# mate's, with the same `need dbus`. That asymmetry is upstream's, this module
# mirrored it faithfully, and it cost a machine its greeter: the desktop
# installed, X worked, `startx` opened xfce, and the boot ended at a text
# console with nothing anywhere saying why.
#
# Pairing the two in one place is the point. The next branch someone adds gets
# dbus because it asked for a display manager, not because they remembered.
# The package too, and not only because something else would probably drag it
# in. On a diskless machine /etc/apk/world *is* the machine — the initramfs
# apk-adds every line of it into the RAM root on every boot — so a service whose
# package is only there as somebody else's dependency is a service that is one
# `apk del` away from a runlevel link pointing at nothing. The init script
# arrives with it: dbus-openrc is an install_if subpackage, so apk pulls it in
# wherever dbus and openrc are both installed, which here is always.
#
# The second thing a display manager needs is to be last.
#
# coisas froze at the greeter twice with the same symptom, and the first time
# sshd answered and the second time nothing did. That difference was never the
# network: `networking` is in the *boot* runlevel (modules/net.sh), so the
# address exists before the default runlevel is entered at all. sshd is not.
# sshd and the display manager are both plain members of `default`, and neither
# init script mentions the other — lightdm.initd is `need localmount dbus`,
# sshd.initd is `use logger dns`, `after entropy`, `need net`.
#
# Two services in one runlevel with no ordering between them are not started at
# the same time, and are not started in a defined order either:
#
#     etc/rc.conf     #rc_parallel="NO"   — commented out, so: one at a time
#     librc.c         ls_dir() readdir()s the runlevel directory and never
#                     sorts what it collects
#     librc-depend.c  rc_deptree_depends() -> visit_service() is a DFS that
#                     keeps the input order for anything unrelated
#
# So which of the two goes first is the order the kernel hands back for
# /etc/runlevels/default — a tmpfs directory rebuilt from the overlay tarball
# on every boot. The machine's only way back in was decided by directory order,
# and on a machine whose greeter wedges the console that is the difference
# between a diagnosis and a power cycle. It is also why this read as a
# regression: nothing about the network changed, the coin landed the other way.
#
# `after sshd`, then — soft, so a machine with ssh disabled or broken still
# gets its desktop, and it costs nothing when sshd is in no runlevel.
#
# In /etc/rc.conf.d and not /etc/conf.d/<dm>, because greetd and sddm each ship
# an /etc/conf.d file of their own (their APKBUILDs install $pkgname.confd) and
# this would overwrite it. gendepends.sh sources /etc/rc.conf.d/*.conf for every
# service after that service's own conf.d, and _depend reads rc_<service>_after
# before the unscoped rc_after — so a service-scoped variable, in a file spore
# owns outright, orders exactly one service and collides with nothing.
desktop_plan_dm() {
    plan_pkg dbus
    plan_svc dbus default on
    plan_svc "$1" default enable
    if mconf_bool DESKTOP_BLACKBOX yes; then desktop_plan_blackbox; fi
    plan_dir /etc/rc.conf.d 0755
    plan_file /etc/rc.conf.d/spore-display-manager.conf 0644 \
"# Written by spore. OpenRC sources this for every service; the variable is
# scoped to one, so that is all it orders.
#
# A greeter that wedges takes the console with it. sshd is the way back in, and
# it has to be listening before anything can take the screen away. Both are
# plain members of the default runlevel and OpenRC starts those one at a time
# in readdir order, so without this line which comes first is not decided here.
rc_${1}_after=\"sshd\""
    plan_note "desktop: $1 is ordered after sshd, so the way back in is up
         before anything touches the screen. A greeter that hangs then costs
         you the console and not the machine."
}

# A machine that dies with its console takes its evidence with it.
#
# /var/log is tmpfs on a diskless box, so an X log describing a hang exists
# only until the power goes. coisas froze at its greeter three times and
# /var/log/lightdm/x-0.log has still never been read: ssh answered on the first
# freeze and not the second, and the recorder typed at a prompt to catch the
# third wrote nothing at all. That last one is the instructive failure —
# lightdm declares `need localmount`, localmount remounts per fstab, and the
# medium went back to read-only underneath the recorder while every one of its
# writes went to /dev/null. An empty directory, discovered an hour later.
#
# So it is written down here instead of typed, with those three failures
# designed out:
#
#   The medium is found, not named. /media/sdc2 on one boot, /media/usb on the
#   next; a directory under /media holding a committed overlay is neither.
#
#   Read-write is re-taken at every tick rather than once at the start,
#   because something else in this runlevel will take it away again.
#
#   A recorder that cannot record says so to syslog rather than returning 0.
#
# It does not `need localmount`, deliberately: that is the chain the display
# manager drags in, and already running when it fires is the entire point.
# `before display-manager` is how elogind orders itself ahead of the same
# thing, and every display manager here declares `provide display-manager`.
#
# Bounded, because this is a diagnostic and not a logging system: it records
# for DESKTOP_BLACKBOX_SECONDS and stops, which on the default is ninety lines
# of a few bytes each, and it keeps exactly one previous boot beside it.
desktop_blackbox_script() {
    printf "secs='%s'\n" "$1"
    cat <<'SBB'
tick=2

# Overridable so the decisions below can be exercised against a real directory
# rather than only against a machine that is already broken. Nothing sets it on
# a machine; /media is the whole point there.
: "${SPORE_BLACKBOX_MEDIA:=/media}"

med=''
for d in "$SPORE_BLACKBOX_MEDIA"/*; do
    [ -d "$d" ] || continue
    for o in "$d"/*.apkovl.tar.gz; do
        [ -f "$o" ] || continue
        med=$d
        break
    done
    [ -n "$med" ] && break
done
if [ -z "$med" ]; then
    logger -t spore-blackbox "no directory under $SPORE_BLACKBOX_MEDIA holds an
overlay, so there is nowhere on this machine that survives a power cut.
Nothing recorded."
    exit 0
fi

out=$med/spore-blackbox

# At every tick, not once. localmount remounts per fstab when the display
# manager pulls it in, which is after this started.
hold_rw() { mount -o remount,rw "$med" 2>/dev/null || true; }

hold_rw
rm -rf "$out.1" 2>/dev/null
[ -d "$out" ] && mv "$out" "$out.1" 2>/dev/null
mkdir -p "$out/lightdm" 2>/dev/null

# The check the hand-rolled one did not have.
if ! touch "$out/vitals" 2>/dev/null; then
    logger -t spore-blackbox "cannot write to $out, so nothing is being
recorded. The medium is read-only and remounting it did not take."
    exit 0
fi

now() { cut -d. -f1 /proc/uptime; }

snap() {
    hold_rw
    dmesg > "$out/dmesg" 2>/dev/null
    ps > "$out/ps" 2>/dev/null
    cp -a /var/log/lightdm/. "$out/lightdm/" 2>/dev/null
    cp /var/log/messages "$out/messages" 2>/dev/null
    sync
}

end=$(( $(now) + secs ))
n=0
while [ "$(now)" -lt "$end" ]; do
    hold_rw
    {
        printf 'up=%s ' "$(now)"
        awk '/^MemAvailable:/ { printf "memavail=%sk ", $2 }
             /^MemFree:/      { printf "memfree=%sk ", $2 }' /proc/meminfo
        printf 'load=%s runq=%s ' "$(cut -d' ' -f1 /proc/loadavg)" \
                                  "$(cut -d' ' -f4 /proc/loadavg)"
        df -Pk / | awk 'NR == 2 { printf "root=%s/%sk ", $3, $2 }'
        printf 'xlogs=%s\n' "$(find /var/log/lightdm -type f 2>/dev/null | wc -l)"
    } >> "$out/vitals" 2>/dev/null
    sync
    n=$((n + 1))
    [ $((n % 15)) = 0 ] && snap
    sleep "$tick"
done
snap
logger -t spore-blackbox "recorded $n tick(s) to $out"
SBB
}

desktop_plan_blackbox() {
    db_secs=$(mconf DESKTOP_BLACKBOX_SECONDS 180)
    case $db_secs in
        ''|*[!0-9]*) plan_note "desktop: DESKTOP_BLACKBOX_SECONDS is a number of
         seconds, not '$db_secs'. Using 180."
                     db_secs=180 ;;
    esac

    plan_file /usr/local/sbin/spore-blackbox 0755 "#!/bin/sh
# Managed by spore. Records to the boot medium, which is the only thing on a
# diskless machine that survives the power going off.
set -u
$(desktop_blackbox_script "$db_secs")"

    plan_file /etc/init.d/spore-blackbox 0755 "#!/sbin/openrc-run
# Managed by spore.
description=\"Record vitals to the boot medium while the desktop comes up\"

depend() {
    # No \`need localmount\` on purpose: that is the chain the display manager
    # drags in, and this has to be recording before it fires.
    before display-manager
}

start() {
    ebegin \"spore: black box recording to the boot medium\"
    start-stop-daemon --start --background --make-pidfile \\
        --pidfile /run/spore-blackbox.pid --exec /usr/local/sbin/spore-blackbox
    eend \$?
}

stop() {
    start-stop-daemon --stop --quiet --pidfile /run/spore-blackbox.pid 2>/dev/null
    return 0
}"
    plan_svc spore-blackbox default on

    plan_note "desktop: a black box records to the boot medium for ${db_secs}s from
         each boot — memory, load, root usage and the number of X logs, every
         two seconds, plus dmesg and /var/log/lightdm — and keeps the previous
         boot beside it. It is there because a greeter that wedges takes
         /var/log with it when the power goes. Read it with the medium in
         another machine: <medium>/spore-blackbox/vitals. Turn it off with
         DESKTOP_BLACKBOX=no once the desktop is boring."
}

# elogind installed and not running is worse than elogind absent.
#
# `polkit-elogind` is polkit built against elogind: its backend for "who is
# logged in, at which seat, are they active" is org.freedesktop.login1, which
# is elogind and nothing else. A greeter asks that question the moment it draws
# — the shutdown and restart buttons on it are polkit checks — so a machine
# with the elogind packages on it and no elogind running has a greeter talking
# to a bus with nobody on the other end of that name, on every paint.
#
# The init script says what it needs and where it goes, in four lines:
#
#     community/elogind/elogind.initd
#         depend() {
#                 need dbus cgroups
#                 # Make sure we start before any other display manager
#                 before display-manager
#         }
#
# `before display-manager`, and every display manager here declares
# `provide display-manager` — so the ordering is upstream's and free. What is
# not free is being in a runlevel at all, and setup-desktop only does that for
# one branch of its own case statement:
#
#     lxqt   apk add … elogind polkit-elogind …   rc-update add elogind
#     xfce   apk add … elogind polkit-elogind …   (nothing)
#
# which is the dbus asymmetry again, one branch further down, and this module
# mirrored it faithfully a second time. On coisas that was the difference
# between `startx` opening xfce in a second — which it does, the GPU is fine —
# and a greeter that draws, blinks its password cursor, and takes the machine
# down with it over the next minute.
#
# cgroups because `need cgroups` and a diskless Alpine has it in no runlevel;
# OpenRC would pull it in as a dependency anyway, and it is named here so that
# `rc-status` shows a machine that is telling the truth about itself.
#
# dbus for the same reason it is in desktop_plan_dm — `need dbus` — and the
# duplicate costs nothing, because identical plan lines are emitted once.
desktop_plan_elogind() {
    plan_pkg elogind
    plan_pkg polkit-elogind
    plan_pkg dbus
    plan_svc dbus default on
    plan_svc cgroups default on
    plan_svc elogind default on
}

# setup-desktop writes this for the gtk desktops and nothing reads it back, so
# it is an ordinary owned file rather than a firstboot action.
desktop_plan_gtk_dark() {
    plan_file /etc/gtk-3.0/settings.ini 0644 '[Settings]
gtk-application-prefer-dark-theme=1'
}

# greetd needs two lines appended to files its own package ships, and one group
# membership. Appending to somebody else's file is a firstboot action, guarded
# the way upstream guards it, because rewriting the file would throw away
# whatever the package put there.
desktop_plan_greetd() {
    plan_firstboot desktop-greetd 'set -e
if [ -d /etc/conf.d ] && ! grep -q "^rc_need" /etc/conf.d/greetd 2>/dev/null; then
    echo "rc_need=\"seatd dbus\"" >> /etc/conf.d/greetd
    echo "spore: told greetd it needs seatd and dbus"
fi
if [ -d /etc/greetd ] && ! grep -q xfce4-wayland /etc/greetd/environments 2>/dev/null; then
    echo xfce4-wayland >> /etc/greetd/environments
    echo "spore: added xfce4-wayland to the greeter session list"
fi
if grep -q "^seat:" /etc/group 2>/dev/null; then
    id -nG greetd 2>/dev/null | grep -qw seat || adduser greetd seat
fi'
}

# Firstboot actions run in the order their modules are listed in MODULES, and
# `adduser <user> <group>` needs the account to be there already. Listed the
# wrong way round, this module's action finds nothing to add and adds nothing —
# and on a diskless machine there is no second chance at it: the stamps live on
# the RAM root, so every firstboot action runs on a seed boot and none of them
# run once the machine is on its own committed overlay. The desktop would
# install perfectly and refuse the only account meant to use it.
#
# The order is in a file on this workstation, so the answer belongs here and not
# on the machine.
desktop_check_order() {
    case " $SPORE_MODULE_LIST " in
        *" users "*) : ;;
        *) return 0 ;;
    esac
    for dco_m in $SPORE_MODULE_LIST; do
        case $dco_m in
            users) return 0 ;;
            desktop)
                die "desktop: MODULES lists desktop before users, and the
         accounts have to exist before this can put them in the video, input
         and seat groups. Nothing would fail on the machine — the desktop would
         come up and refuse the one account meant to use it.

         In spore.conf, list users first:
             MODULES=\"$(printf '%s' "$SPORE_MODULE_LIST" | sed 's/desktop//; s/users/users desktop/; s/  */ /g; s/^ //; s/ $//')\"" ;;
        esac
    done
}

# A desktop nobody can use is the failure upstream warns about at the end of
# setup-desktop, and it warns after installing a gigabyte of it. An account made
# by `adduser -D` is in none of the groups a seat needs, so this is not only
# about there being an account — it is about that account being able to open the
# screen it is looking at.
#
# The list comes from users.conf rather than being asked for twice: naming the
# same accounts in two files is a way for them to disagree.
desktop_plan_groups() {
    desktop_check_order
    dpg_users=$(mconf DESKTOP_USERS '')
    dpg_from=DESKTOP_USERS
    if [ -z "$dpg_users" ]; then
        dpg_users=$(conf_get "$SPORE_DIR/modules/users.conf" USERS '')
        dpg_from=users.conf
    fi
    if [ -z "$dpg_users" ]; then
        plan_note "desktop: no accounts to put in the video, input, audio and
         seat groups — USERS is empty in users.conf and DESKTOP_USERS is unset.
         The desktop installs and nobody can log into it. root cannot: display
         managers refuse it."
        return 0
    fi
    case $dpg_users in
        *[!A-Za-z0-9_\ .-]*) die "desktop: $dpg_from is a space-separated list of account names" ;;
    esac
    plan_note "desktop: $dpg_users joins the video, input, audio, netdev and
         seat groups (from $dpg_from), which is what lets an account opened by
         \`adduser -D\` reach the screen and the keyboard."
    plan_firstboot desktop-groups "set -u
for u in $dpg_users; do
    if ! id \"\$u\" >/dev/null 2>&1; then
        # Never silently: an account that is not here yet gets no groups, and a
        # desktop that refuses its only login looks like a broken desktop.
        echo \"spore: '\$u' does not exist, so it joins no groups and will not\" >&2
        echo \"spore: be able to use this desktop. Is it in USERS in users.conf?\" >&2
        continue
    fi
    for g in video input audio netdev seat; do
        grep -q \"^\$g:\" /etc/group 2>/dev/null || continue
        case \" \$(id -nG \"\$u\" 2>/dev/null) \" in
            *\" \$g \"*) continue ;;
        esac
        if adduser \"\$u\" \"\$g\" 2>/dev/null; then
            echo \"spore: added \$u to \$g\"
        else
            echo \"spore: could not add \$u to \$g\" >&2
        fi
    done
done"
}

# The thing that decides whether a diskless desktop is a good idea, and it is
# not a warning about disk space.
#
# Alpine's initramfs re-reads /etc/apk/world out of the apkovl and runs
# `apk add` for every line of it, into the tmpfs root, on every single boot
# (initramfs-init: pkgs="$pkgs $(cat "$sysroot"/etc/apk/world)" … apk add --root
# $sysroot … $pkgs). For a file server that is a handful of packages nobody
# notices. A desktop is hundreds, and gnome is over a thousand — so every boot
# reinstalls the whole desktop, and the installed tree lives in RAM for as long
# as the machine is up.
#
# Said once, and only while it is still true. This used to print both halves on
# every apply and end by recommending a disk — to somebody who had read it a
# dozen times, had weighed it, and had chosen diskless on purpose. A note that
# re-argues a settled decision is not information, it is nagging, and it makes
# the notes that *are* news harder to see.
#
# So: the packages half disappears once REPOS_BOOT_REPO is set, because then it
# is handled and there is nothing to say. The memory half is no longer an
# instruction to go and measure something — report_ram_root measures it at the
# end of the apply, exactly, on this machine. And the recommendation is gone.
# Diskless is a supported way to run a desktop here; what the tool owes you is
# the number, not an opinion you have already heard.
desktop_plan_diskless() {
    [ "$(fact_persist)" = lbu ] || return 0
    dpd_de=$1
    dpd_repo=$(conf_get "$SPORE_DIR/modules/repos.conf" REPOS_BOOT_REPO '')
    if [ -z "$dpd_repo" ]; then
        plan_note "desktop: this is a diskless host, so Alpine's initramfs
         reinstalls everything in /etc/apk/world into the RAM root at every
         boot, with apk run --no-network. Nothing here has a boot repository
         to install from, so the next boot comes up with the world file and
         the runlevels naming a desktop that is not on the machine.
         Set REPOS_BOOT_REPO in repos.conf to a relative path on the medium."
    fi
    plan_note "desktop: the installed desktop sits in tmpfs for as long as this
         machine is up, so it costs its own size in RAM before anything runs.
         The apply measures what is left and says so at the end — free space on
         / is free memory here, and they are the same number."
    [ "$dpd_de" = gnome ] || [ "$dpd_de" = plasma ] || return 0
    plan_note "desktop: $dpd_de is much the largest of these, so that figure
         will be the tightest with it."
}

# Whether anything graphical is actually running is not something the plan can
# answer: the display manager is enabled on the boot that installs it and starts
# on the next one.
desktop_status_extra() {
    dse_de=$(mconf DESKTOP_ENV '')
    [ -n "$dse_de" ] && [ "$dse_de" != none ] || return 0
    dse_cards=''
    for dse_c in /sys/class/drm/card[0-9]*; do
        [ -e "$dse_c" ] || continue
        dse_cards="$dse_cards ${dse_c##*/}"
    done
    if [ -n "$dse_cards" ]; then
        printf 'drm:%s\n' "$dse_cards"
    else
        printf 'drm: no kernel display driver bound\n'
    fi
    if [ -d /run/udev ]; then
        printf 'udev: running\n'
    else
        printf 'udev: not running (sysinit runs it; reboot after the first apply)\n'
    fi
}
