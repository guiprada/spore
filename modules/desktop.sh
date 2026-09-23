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
        plan_pkg elogind
        plan_pkg polkit-elogind
        plan_svc cgroups default on
        plan_svc dbus default on
    fi
    desktop_plan_udev

    case $dt_de in
        xfce)
            for dt_p in xfce4 elogind gvfs lightdm lightdm-gtk-greeter \
                        polkit-elogind xfce4-screensaver xfce4-terminal font-dejavu; do
                plan_pkg "$dt_p"
            done
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
            plan_svc elogind default on
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
desktop_plan_dm() {
    plan_pkg dbus
    plan_svc dbus default on
    plan_svc "$1" default enable
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
# Both halves are worth saying because each has a different fix, and neither is
# obvious from a boot that eventually works.
desktop_plan_diskless() {
    [ "$(fact_persist)" = lbu ] || return 0
    dpd_de=$1
    # The headline package, so the command below is one somebody can paste. The
    # environment names are setup-desktop's, not apk's: `apk add xfce` is not a
    # thing.
    case $dpd_de in
        xfce|xfce-wayland) dpd_pkg=xfce4 ;;
        mate)              dpd_pkg=mate-desktop-environment ;;
        lxqt)              dpd_pkg=lxqt-desktop ;;
        plasma)            dpd_pkg=plasma-desktop-meta ;;
        *)                 dpd_pkg=$dpd_de ;;
    esac
    plan_note "desktop: this is a diskless host, so Alpine's initramfs installs
         everything in /etc/apk/world into the RAM root at every boot — the
         whole desktop, every time, not just the once. That costs twice, and
         each half has its own fix. Boot time: without a package cache on the
         boot medium these are downloaded again on every boot, so set
         REPOS_APK_CACHE in repos.conf to a path on the medium. Memory: the
         installed tree sits in tmpfs for as long as the machine is up, so the
         desktop costs its own installed size in RAM before anything runs. To
         see what that is before committing to it, on any Alpine box:
         apk add --simulate $dpd_pkg
         A desktop on a disk pays neither, and if this machine has one, that is
         the better place for it."
    [ "$dpd_de" = gnome ] || [ "$dpd_de" = plasma ] || return 0
    plan_note "desktop: $dpd_de is much the largest of these, and a diskless
         boot pays for it in full every time. xfce or sway is the same idea for
         a fraction of the boot."
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
