# spore

Declarative, installation-less configuration for Alpine Linux.

A **spore** is a small, readable, git-able bundle. A machine is what a blank
Alpine becomes when it germinates one.

Two things share the name, and it is worth separating them once:

| | what it is | where it comes from |
|---|---|---|
| **the tool** | this program — `bin/spore`, `lib/`, `modules/` | cloned from here, identical everywhere, never edited |
| **a spore** | one machine's configuration — `spore.conf`, `modules/*.conf`, `keys/`, `secrets/` | yours, one per machine, the thing you edit |

Every command is the tool pointed at a spore:

```sh
~/spore-tool/bin/spore -s ~/coisas/spore plan
                       └─ tool          └─ the spore it acts on
```

`-s` always names the bundle, never this repository.

```sh
spore setup                            # asks, then offers to write the stick
spore media /dev/sdX alpine.iso        # partition and write a boot medium
spore try /dev/sdX                     # boot it in a VM, medium untouched
spore inspect /dev/sdX                 # what is on it, and what it logged
spore install DIR /dev/sdX             # put the machine on it

spore apply          # converge this host to the spore
spore persist        # make it survive a reboot
spore status         # declared vs actual
```

There is no *install* verb. `apply` converges to a declared state, so applying to
a fresh box and re-applying to a running one are the same operation.

## Why

Alpine already invented this idea. An **apkovl** is a machine-as-data — a tarball
that turns a blank RAM-booted box into a specific machine. It has three limits:
it is opaque, it covers only `/etc`, and it only works diskless.

A spore is an apkovl without those limits: text instead of a tarball, any path
instead of `/etc`, and every host instead of only diskless ones.

## From a stock Alpine

The whole point is that a blank box becomes a specific machine, so getting spore
onto a blank box is part of the product rather than a preamble to it. On a
freshly booted Alpine:

```sh
setup-interfaces && rc-service networking start
setup-apkrepos -c -f          # a mirror, and community, in one step
apk add git
git clone https://github.com/guiprada/spore /root/spore
cd /root/spore && ./tests/run.sh
```

**If HTTPS fails for git but not for apk, suspect the trust store.**
`ca-certificates-bundle` ships in the Alpine base, so a clean install is usually
fine. But apk carries its own store, so a *damaged* bundle lets packages install
happily while git, curl and every blob fetch die with `unable to get local issuer
certificate` — which reads like a network fault and sends you looking in the
wrong place. `spore doctor` reports the store's state explicitly for that reason.

If the store is present but *empty*, that is usually `update-ca-certificates`,
which regenerates the bundle and can leave it with nothing in it. Reinstall the
bundle rather than regenerating it again:

```sh
apk add --force-overwrite ca-certificates-bundle
```

The confusing part, worth knowing before you spend an evening on it: `openssl
s_client` reads the **directory** `/etc/ssl/certs/`, while git and curl read the
single **bundle file** `/etc/ssl/certs/ca-certificates.crt`. So an empty bundle
gives you `verify return:1` from openssl and `unable to get local issuer
certificate` from git, at the same time, on the same box. A passing `s_client` is
not evidence the store is healthy — count the certificates in the bundle
instead, which is what `spore doctor` does.

## The model

```
spore ──[ planner ]──> action list ──[ executor ]──> effect
         pure, no I/O   plain data      ├─ live     → apply
         no root        serializable    ├─ print    → --dry-run
         runs anywhere  diffable        └─ staging  → build (not yet)
```

The planner never touches the system; executors are dumb. `status`, `diff` and
`remove` are all generic over the plan, so modules do not implement them.

A root that is not `/` is **synthetic**: the host's own tools (`apk`,
`rc-update`, `lbu`) are not run, and the executor writes the state they would
have produced. That is what makes the whole apply path testable without an
Alpine box — and it is the shape the staging executor will need.

### Actions

| action | live | staging (`build`, planned) |
|---|---|---|
| `netup` | bring the interface up, before anything reaches the network | n/a |
| `bootstrap` | run before any package (enable a repo, point the apk cache) | run in the staging chroot |
| `pkg` | `apk add` | append to `etc/apk/world` |
| `blob` | fetch, verify sha256, install | fetch into boot-media cache |
| `dir` / `file` | write under `/` | write under the staging tree |
| `secret` | decrypt and substitute, `umask 077` | deferred to first boot |
| `svc` | `rc-update add`, then start if not running | symlink into `etc/runlevels/` |
| `firstboot` | run now | emit to `/etc/local.d/` |
| `persist` | (declaration) | already in the overlay |

Three phase distinctions matter. `netup` runs before everything, because a
machine that provisions itself has to have an address before it can fetch a
single package — and bootstrap actions run in the order modules were listed, so
`repos` ahead of `net` in `MODULES` would otherwise put `apk update` first and
fail as a DNS error. Reachability must not depend on the order of a line in a
config file. `bootstrap` runs *before* packages, because enabling
the community repository has to precede the `apk add` that depends on it.
`firstboot` runs *after* everything, and holds work that genuinely cannot be
planned statically — generating an ssh host key, or a TLS certificate — which is
deferred rather than faked.

## A spore

```
myhost.spore/
├── spore.conf        FORMAT=1  HOST=  MODULES="ssh dufs net firewall"
├── modules/*.conf    per-module KEY=VALUE
├── files/            literal overlay tree, mirrors /
├── keys/             public keys and other non-overlay inputs
├── blobs.conf        name arch url sha256 dest mode member
└── packages          extra apk packages
```

Config is **parsed, never sourced** — sourcing a spore would be arbitrary code
execution and would make validation impossible.

**Settings vs data.** Modules declare `MOD_OWNS` (settings → the spore) apart
from `MOD_DATA` (payload → a mount). Mixing them is what makes a portable config
stop being portable, so they are kept apart from the start.

**Secrets travel sealed, never in cleartext.** A spore carries its secrets as
[age](https://github.com/FiloSottile/age) ciphertext in `secrets/<name>.age`,
alongside the public `secrets/recipients`. Both are safe to commit. The private
identity lives on the host and is the one thing a spore cannot carry — it is what
unlocks everything the spore does carry.

Create the keypair first — `seal` encrypts *to* the recipients:

```sh
age-keygen -o identity                        # private; never inside the spore
mkdir -p myhost.spore/secrets
age-keygen -y identity > myhost.spore/secrets/recipients
```

`SECRETS_IDENTITY` may be relative, and resolves against the spore rather than
the working directory — so the identity can sit beside a spore that a
seed-booted machine mounts at a path nothing could have hardcoded:

```
SECRETS_IDENTITY=../identity
```

```sh
spore seal dufs-auth                  # reads the value from stdin
spore seal ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key
spore secrets                         # what this spore carries
```

An account's password can be sealed too, which is what makes a genuinely
console-free build possible:

```sh
openssl passwd -6 | spore -s myhost.spore seal gui.password
```

`root.password` works the same way and is the one that matters for reachability:
root is never listed in `USERS` because it already exists, and a stock Alpine
boots it with no password at all.

```sh
openssl passwd -6 | spore -s myhost.spore seal root.password
```

It is decrypted on the target at first boot and applied with `chpasswd -e`, so
the hash never enters the plan — only the path to the ciphertext does. The
firstboot stamp is the hash of its script, so the ciphertext's own checksum is
embedded in it: rotate the sealed password and the action runs again, rather than
being silently ignored.

Reference a sealed secret from a module and it is substituted **on the host at
write time**:

```
DUFS_AUTH_SECRET=dufs-auth
SSH_HOST_KEY_SECRETS="ssh_host_ed25519_key"
```

Plaintext never enters the plan. The content store holds a template with
`@@SECRET:name@@` markers; the executor decrypts under `umask 077` straight to
the destination. `plan` shows the marker, `diff` reports that a secret differs
without printing it, and a file that carries a secret is written 0600/0640 rather
than world-readable.

Sealing the ssh host keys means a rebuilt box keeps its identity, so clients never
see `REMOTE HOST IDENTIFICATION HAS CHANGED`.

## Hosts differ, honestly

Modules declare what they need. Unmet requirements are reported, never
half-applied:

```
  firewall: n/a here (no NET_ADMIN)
```

The same spore on a VM and an unprivileged LXC yields the maximal correct subset
of each. Facts are overridable (`SPORE_FACT_NETADMIN=no`), which is how the test
suite drives host shapes that do not exist on the machine running it.

## Persistence

| host | backend |
|---|---|
| diskless (`/` on tmpfs + `lbu`) | `lbu include` owned paths outside `/etc`, then `lbu commit` |
| disk / VM / container | nothing to commit; the spore is exported to `/var/lib/spore/spore` |

**The boot medium does not have to be writable.** Alpine's initramfs locates the
apkovl with `nlplug-findfs`, which scans attached block devices for
`*.apkovl.tar.gz` rather than only inspecting the medium it booted from. So a
read-only ISO partition plus a writable data partition holding the apkovl, the
apk cache and the served data is a better arrangement than a writable boot
medium: the system is identical on every boot, cannot drift, and cannot be
corrupted by losing power mid-write. Point `LBU_MEDIA` (or `LBU_BACKUPDIR`) at
the data partition and `doctor` will confirm with `apkovl to /media/<name>`.

One caveat: the initramfs takes the *first* apkovl it finds, so with two such
devices plugged in the choice is arbitrary. `apkovl=<device>:<path>` on the
kernel command line pins it.

Prefer `apply --persist` over applying and persisting as separate steps: the gap
between "it works" and "it survives" is where an unexpected reboot costs you the
work. `persist` syncs after committing and then reads the archive back, because
`lbu` returns once the write is *issued* — on removable media a page-cached
apkovl can be lost to a power cut, leaving a truncated file that only fails at
the next boot. Committing on every apply also means `lbu` accumulates numbered
backups to fall back on; a single commit leaves you nothing.

On a diskless host `apply` warns loudly that nothing survives a reboot until you
`persist`, and `doctor` warns if `lbu.conf` names no destination at all — which
would otherwise fail at `persist` time looking like a bug in spore rather than a
missing line of configuration. `doctor` also warns about the classic trap: `/etc/apk/world` persists
the *intent* to have a package, but without an apk cache on persistent media the
package files are re-downloaded every boot.

## Modules

| module | does | needs |
|---|---|---|
| `repos` | enable community; set a mirror; point the apk cache at persistent media | root |
| `ssh` | OpenSSH, keys, root/password policy | OpenRC |
| `dufs` | `apk add dufs`, render `/etc/dufs/config.yaml`, TLS, setcap | OpenRC |
| `users` | accounts, doas rules, persist `/home` | root |
| `system` | keyboard layout, timezone and time sync, via Alpine's own setup-* tools | root |
| `storage` | mount declared volumes under a serve root | root |
| `apkovl` | where `lbu commit` writes — without it a diskless box forgets everything | diskless |
| — | secrets are handled by the core, not a module | `age` on the target |
| `net` | hostname (anywhere), interfaces and DNS | NET_ADMIN for the latter |
| `firewall` | awall policy generated from every module's declared ports | NET_ADMIN, OpenRC |

**Prefer a package over a blob for the binary.** dufs is in Alpine community
(`arch=all`), so it comes from apk. The blob mechanism stays for things that
genuinely are not packaged.

**But declare the service rather than inheriting it.** On Alpine 3.24 the dufs
package ships no init script, so `rc-update add dufs` fails outright; whether one
exists is a packaging detail that varies by branch. The module generates its own
unit — `supervise-daemon`, a dedicated user, reading `/etc/dufs/config.yaml` via
`-c` — so the same spore produces the same running service on every Alpine
version. That is the whole premise, and it is worth more here than reusing
whatever the distro happens to provide.

Two quirks worth knowing, both learned the hard way rather than guessed:
binding a port below 1024 as a non-root user needs
`setcap cap_net_bind_service=+ep`, and `lbu commit` fails unless the boot media is
remounted read-write first.

Enabling a service opens its port: `firewall` builds its policy from what the
other modules declared, so there is no second place to remember.

Firewall **activation is opt-in** (`FW_ACTIVATE=no` by default). Applying
firewall rules to a remote box is exactly the operation that can lock you out of
it, so the policy is written and enabled but not activated until you say so.

### Closed by default

`SSH_ENABLED=no`, `SSH_PERMIT_ROOT_LOGIN=no`, `SSH_PASSWORD_AUTH=no`, and
`PermitEmptyPasswords no` unconditionally. doas is off unless an account is
listed in `USERS_DOAS`, and passwordless doas only if you ask for it by name.

Two configurations are **refused at plan time**, not built and left for the
network to reveal:

- nothing could log in — root login off, password auth off, and no account in
  the spore carries a key;
- a password-less root exposed — `PermitRootLogin yes` with
  `PasswordAuthentication yes` while root has no password.

That second one is a question about *when*, not *whether*. A machine booting
with no root password is perfectly normal — a stock Alpine does exactly that.
What it must not do is be reachable in that state. So the spore can set root's
password itself:

```sh
openssl passwd -6 | spore -s ~/spores/galadriel/spore seal root.password
```

Sealed, it is applied in the **firstboot** pass, and every firstboot action runs
before any service is enabled — so the password is in place before sshd exists.
The ssh module counts a sealed `root.password` as a password root will have,
which is what turns that refusal into a working configuration. The same applies
to any account: `<user>.password` sealed the same way completes unattended
provisioning, so `doas permit persist` has something to prompt for and nobody
has to visit the console.

Both refusals are checked from the workstation too — see `spore install` above,
which forces the target's shape so they fire while the disk is still in your
hand.

### Adding one

Modules emit actions; they never act.

```sh
mymod_meta() {
    MOD_DESC='what it is'
    MOD_REQUIRES='init.openrc'    # net.admin, boot.media, root
    MOD_DATA='/srv/payload'       # never enters the spore
    MOD_PORTS='8080/tcp'          # the firewall picks this up
}

mymod_plan() {
    plan_pkg  something
    plan_file /etc/conf.d/mymod 0644 "$(mymod_render)"
    plan_svc  mymod default on
}
```

Drop it in `modules/`, add the name to `MODULES=`. Owned paths are derived from
the actions, so they cannot drift out of sync with what the module writes.

Two modules claiming the same path is refused at plan time rather than settled by
emit order.

### Storage

Volumes are declared in `volumes.conf`, keyed by a stable identifier — the
interactive "which disk?" of a setup wizard has no place in something meant to
produce the same machine twice.

```
# <name>  <spec>  <fstype>  <options|->
archive  LABEL=archive     ext4   -
photos   UUID=A1B2-C3D4    exfat  -
bootusb  bind:/media/usb   -      -
```

`/dev/sdb1` renumbers when you plug things in differently; UUID and LABEL do not.
`bind:` mounts an existing path, which is how the boot medium gets served without
exposing it as a raw device.

Three things it will not let you get wrong:

- **`nofail` on every entry.** A disk that is not plugged in must never stop a box
  from booting.
- **vfat/exfat/ntfs get `umask`, not `chown`.** Those filesystems carry no Unix
  ownership, so permissions come from the mount. `STORAGE_OWNER` is applied only
  to filesystems that can actually hold it, and the chown tolerates failure.
  (Numeric `STORAGE_FAT_UID`/`GID` only — busybox `mount` does not translate
  names for the vfat kernel options, so `uid=dufs` would be rejected. `umask=000`
  already grants access, which makes them optional.)
- **fstab is an owned block, never a rewrite.** The root filesystem and anything
  else already in there is not the spore's to touch, and re-applying does not
  duplicate the block.

A volume whose name would escape the serve root, or whose spec is not a
recognised identifier, is refused at plan time rather than written into fstab.

## Making the boot medium

```sh
spore setup          # asks, writes the machine, offers to write the stick
```

That is the whole thing. `setup` asks its questions and then writes the machine
onto the stick — running `media` and `install` for you, mounting and unmounting
on its own. **There is no second copy on the workstation.** The spore on the disk
is the machine; keeping a copy beside it only raises the question of which one is
real, and the whole premise is that the thing is portable data that lives where it
runs from.

To change a machine later, mount its data partition and edit the file:

```sh
sudo mount /dev/sdX2 /mnt
$EDITOR /mnt/spore/modules/net.conf
```

then `spore apply --persist` on the machine itself.

Say no to the stick — because you have not made one yet — and the answers are
saved to `~/spores/<host>` rather than lost, with the two commands to write it
later:

```sh
sudo spore media /dev/sdX alpine-standard-*.iso
sudo spore install ~/spores/<name> /dev/sdX
```

`install` takes the whole device and finds its own partitions. Three commands by
hand is three chances to name the wrong path, and forgetting the `umount` is how
a stick gets pulled while the write is still in the page cache. Mounted
directories still work — `spore install DIR /mnt/data /mnt/esp` — for a disk that
is already mounted or is not laid out this way.

Naming the boot partition as well puts a copy of the seed overlay there. The
initramfs has to mount a filesystem before it can find an apkovl on it, and what
it can mount depends on how that ISO's initramfs was built — a FAT boot partition
it can certainly read, an ext4 data partition only probably. Both copies come out
of the same build in the same run, so whichever it reaches first is the same
overlay and they cannot drift apart.

`setup` asks roughly what `setup-alpine` asks — hostname, keyboard layout,
timezone, time sync, network, package mirror, account, key and ssh — then writes
a spore carrying only the modules you answered for — no volumes
and no file server you did not ask about. `media` erases the disk you name, so it
prints it, refuses one this machine is mounted from, and makes you type the path
back. Everything below is what those two do, for when you would rather do it by
hand.

One stick, two partitions: a read-only Alpine and a writable data area. The
system is identical on every boot and cannot drift; everything that changes
lives on the other partition.

```
p1  ESP    FAT32  label ALPINE   the Alpine ISO, extracted, never written again
p2  data   ext4   label DATA     spore/, identity, the apkovl, the served data
```

**The image's boot config is rewritten to match the medium.** Alpine's
`grub.cfg` finds its root with `search --label "alpine-std 3.24.1 x86_64"` — the
ISO9660 volume label. A FAT label is eleven characters and holds no spaces, so
once the image is extracted onto the ESP that search can never match, and grub
reports `no such device` on every boot. `media` points it at the label the
partition actually has, and adds a serial console to the kernel line while it is
there.

**ext4 for the data partition, not vfat.** vfat carries no Unix ownership, so
the identity that decrypts every secret in the spore cannot be mode 0600 — it is
readable by anyone holding the stick. `spore install` warns when it cannot set
the mode, which is the same thing said later and less usefully.

On a workstation, with the stick at `/dev/sdX` — **check `lsblk` first, this
erases the device**:

```sh
sudo umount /dev/sdX* 2>/dev/null
sudo sgdisk --zap-all /dev/sdX                       # GPT and MBR both
sudo sgdisk -n 1:0:+1G  -t 1:ef00 -c 1:ALPINE /dev/sdX
sudo sgdisk -n 2:0:0    -t 2:8300 -c 2:DATA   /dev/sdX
sudo partprobe /dev/sdX; sudo udevadm settle
sudo mkfs.vfat -F 32 -n ALPINE /dev/sdX1
sudo mkfs.ext4 -L DATA /dev/sdX2
```

Then the Alpine side — extract, do not `dd`. `dd` writes the hybrid ISO over the
whole device, which leaves no room for a data partition and makes the desktop
mount the raw device, so partition mounts then fail with `resource busy`:

```sh
sudo mount -o loop alpine-standard-*.iso /mnt/iso
sudo mount /dev/sdX1 /mnt/esp
sudo cp -a /mnt/iso/. /mnt/esp/
sudo umount /mnt/iso /mnt/esp
```

And the spore side:

```sh
sudo mount /dev/sdX2 /mnt/data
./bin/spore install ~/spores/coisas /mnt/data
sudo umount /mnt/data
```

### Boot it here first

```sh
sudo spore try /dev/sdX
```

A VM boots the same medium in seconds, with the console in front of you. It
writes the whole boot to `spore-boot.log` in the current directory, because a
console you can only photograph is a console you cannot paste — and that is most
of why this project spent so long inferring from symptoms what one line of
console output says outright. `media` puts `console=ttyS0` on the kernel command
line for the same reason; on real hardware it changes nothing, since tty0 stays
primary, but it makes a headless box able to say what happened.

It cannot speak for the target's hardware — its network card, its disks, its
firmware — but it answers the question that is expensive every other way: does
the seed run, and does the spore apply. Without `write` the guest's changes go to
a temporary file and the medium is not touched; `sudo spore try /dev/sdX write`
lets it commit its apkovl for real, which provisions the stick without ever
plugging it into the target.

Two things it handles that catch people out. OVMF is required and looked up
across the paths distributions use, because the medium is EFI-only and a BIOS
guest finds nothing bootable — which reads as a bad stick. And the guest's
network is a NAT, so a spore configured for 192.168.1.50 would come up with no
route and fail at the first `apk`; `try` reads the address off the medium and
puts the NAT on the same numbering, so what runs is the spore you wrote.

```sh
apt install qemu-system-x86 ovmf
```

### When it comes up wrong

```sh
sudo spore inspect /dev/sdX
```

Everything worth knowing after a failed boot is on the data partition, and
reading it by hand meant mount, cat, umount with three paths typed correctly — so
it did not get read, and whole evenings went into inferring from symptoms
instead. `inspect` prints it: what spore is on the medium, whether the identity
is there, whether an apkovl was ever committed, the seed's own log verbatim, and
a stray apkovl on the boot partition that may be winning over yours.

It also answers the question that symptoms cannot: **whether the seed on that
medium is the one this tool would build.** A fix made on the workstation reaches
the machine only through `spore install`, and a boot that fails the same way
afterwards is otherwise indistinguishable from a fix that never landed.

### On the target

Boot it with UEFI. If the firmware will not offer the stick, it is almost always
Secure Boot rather than the partitioning — check that before re-making anything.

Two partitions is not the only arrangement. Alpine's initramfs scans every
attached block device for the apkovl, so **two separate devices work as well**:
a stick with the ISO written by `dd` exactly as Alpine documents, and a second
stick, SD card or internal disk carrying the spore. That trades a USB port for
never having to think about partitioning, and the ISO stick is then interchangeable
between machines.

## Zero-touch first boot

Two commands on a workstation, from a clone of this repo. Neither needs Alpine.

```sh
./bin/spore new galadriel ~/spores/galadriel
$EDITOR ~/spores/galadriel/spore/modules/*.conf
./bin/spore install ~/spores/galadriel /media/$USER/DATA
```

Boot a stock Alpine with that disk attached and it becomes `galadriel`. The
initramfs finds the overlay by scanning block devices — the boot medium is never
written to — and the hook scans the same way for a `spore/` directory, applies
it, and commits. Progress goes to `/var/log/spore-seed.log`.

`new` builds the directory: the example spore renamed to the host, an age
keypair with its recipients file, and **your own public key** taken from
`~/.ssh/` (or `$SPORE_PUBKEY`) — because with root login and password auth both
off, which is the default, a machine with no key in its spore is a machine
nobody can reach.

`install` writes it, and refuses rather than guesses:

- **It plans the spore the way the target will**, forcing OpenRC, root, and a
  root account that boots with no password — which is what a stock Alpine does.
  On a workstation `ssh`, `users` and `dufs` are all skipped for want of OpenRC
  or root, so their plan-time refusals — *nothing could log in*, *that is an
  unauthenticated root shell on the network* — never fire. Forcing the target's
  shape is what makes them fire here, while the disk is still in your hand. A
  sealed `root.password` is counted separately, so a spore that sets one is not
  refused for the state it starts in.
- **It checks the target is a mount point**, by comparing its device number
  against its parent's. Copying onto an unmounted directory fills the
  workstation's own disk instead of the removable one, and you find out when the
  target fails to boot.
- **It builds the seed overlay fresh**, rather than copying one. The overlay
  carries the tool itself, so a stale one boots the target on an older spore than
  the one you just edited.
- **It replaces an existing spore on the disk**, rather than copying a second one
  inside it — but only after confirming what is there is a spore.

The pieces are still ordinary files, and doing it by hand still works:

```
<data>/spore-seed.apkovl.tar.gz     generic, never edited  (spore seed)
<data>/spore/                       plain text, yours      (examples/example.spore)
<data>/identity                     age private key, 0600
```

On vfat there is no ownership to enforce, so the identity that decrypts every
secret in the spore is readable by anyone holding the disk. `install` says so
when it cannot set the mode.

Nothing about this needs a working Alpine to prepare: the overlay is built from a
clone on any machine, and the thing you edit stays plain text on disk rather than
sealed inside a tarball. The hook stamps only on success, so a failed
convergence retries on the next boot instead of leaving a half-built machine that
reports itself finished.

This is not `build`: the machine still converges itself a minute into its first
boot by running the same `apply` path as everywhere else, rather than coming up
already configured with nothing left to run.

## Tests

```sh
./tests/run.sh
```

366 checks, no Alpine and no container required: plan assertions, a synthetic-root
apply, the external commands that would have run, idempotence, dry-run,
status/diff drift detection, a host-shape matrix, blob checksum verification over
`file://`, per-arch blob resolution, the bootstrap-before-packages ordering
invariant, both persist backends, `new`/`install` including every refusal, a
root password sealed into the spore landing before sshd is enabled, the apkovl
destination being declared and created before the commit rather than after, and
the secrets path end to end with real age
keys — byte-exact round-trip of a private key, no plaintext in the plan, and a
`diff` that withholds content. Storage is covered against a pre-existing fstab,
so the test proves the root filesystem entry survives. `dash -n` covers syntax; `shellcheck -s sh`
runs when installed.

### What the tests cannot cover

The real behaviour of `apk`, `lbu`, `rc-update` and `awall` needs actual Alpine.
The suite asserts those are invoked correctly; it cannot assert they do what they
are supposed to. Starting and stopping services is the one path skipped entirely
under a synthetic root, since it needs a real init to be meaningful. Verify on a real target before trusting a spore with a box you
cannot physically reach — especially `awall activate`.

## Not yet

`build` (bake an apkovl offline so a box boots already configured) · the fleet
layer (`diff hostA hostB`, profile inheritance,
`push` over ssh).

`build` is the reason the planner is pure. It is one more executor over an action
list that already exists, plus a `tar` — not a redesign.
