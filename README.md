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
| `bootstrap` | run before any package (enable a repo, point the apk cache) | run in the staging chroot |
| `pkg` | `apk add` | append to `etc/apk/world` |
| `blob` | fetch, verify sha256, install | fetch into boot-media cache |
| `dir` / `file` | write under `/` | write under the staging tree |
| `secret` | decrypt and substitute, `umask 077` | deferred to first boot |
| `svc` | `rc-update add`, then start if not running | symlink into `etc/runlevels/` |
| `firstboot` | run now | emit to `/etc/local.d/` |
| `persist` | (declaration) | already in the overlay |

Two phase distinctions matter. `bootstrap` runs *before* packages, because enabling
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
| `repos` | enable community; point the apk cache at persistent media | root |
| `ssh` | OpenSSH, keys, root/password policy | OpenRC |
| `dufs` | `apk add dufs`, render `/etc/dufs/config.yaml`, TLS, setcap | OpenRC |
| `users` | accounts, doas rules, persist `/home` | root |
| `storage` | mount declared volumes under a serve root | root |
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

## Zero-touch first boot

Build the overlay once — it is generic, carries no configuration, and needs no
spore to build:

```sh
git clone https://github.com/guiprada/spore && cd spore
./bin/spore seed
```

Then put two things on the data partition:

```
<data>/spore-seed.apkovl.tar.gz     generic, never edited
<data>/spore/                       plain text, yours
```

```sh
cp spore-seed.apkovl.tar.gz /mnt/data/
cp -r examples/example.spore /mnt/data/spore
$EDITOR /mnt/data/spore/spore.conf
```

Boot a stock Alpine with that disk attached. The initramfs finds the overlay by
scanning block devices — the boot medium is never written to — and the hook
scans the same way for a `spore/` directory, applies it, and commits. Progress
goes to `/var/log/spore-seed.log`.

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

208 checks, no Alpine and no container required: plan assertions, a synthetic-root
apply, the external commands that would have run, idempotence, dry-run,
status/diff drift detection, a host-shape matrix, blob checksum verification over
`file://`, per-arch blob resolution, the bootstrap-before-packages ordering
invariant, both persist backends, and the secrets path end to end with real age
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
