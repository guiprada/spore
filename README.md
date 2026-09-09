# spore

Declarative, installation-less configuration for Alpine Linux.

A **spore** is a small, readable, git-able bundle. A machine is what a blank
Alpine becomes when it germinates one.

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
| `svc` | `rc-update add` | symlink into `etc/runlevels/` |
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

```sh
spore seal dufs-auth                  # reads the value from stdin
spore seal ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key
spore secrets                         # what this spore carries
```

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

On a diskless host `apply` warns loudly that nothing survives a reboot until you
`persist`. `doctor` also warns about the classic trap: `/etc/apk/world` persists
the *intent* to have a package, but without an apk cache on persistent media the
package files are re-downloaded every boot.

## Modules

| module | does | needs |
|---|---|---|
| `repos` | enable community; point the apk cache at persistent media | root |
| `ssh` | OpenSSH, keys, root/password policy | OpenRC |
| `dufs` | `apk add dufs`, render `/etc/dufs/config.yaml`, TLS, setcap | OpenRC |
| `users` | accounts, doas rules, persist `/home` | root |
| — | secrets are handled by the core, not a module | `age` on the target |
| `net` | hostname (anywhere), interfaces and DNS | NET_ADMIN for the latter |
| `firewall` | awall policy generated from every module's declared ports | NET_ADMIN, OpenRC |

**Prefer a package over a blob, always.** dufs is in Alpine community (`arch=all`),
and its package ships an OpenRC service that already uses `supervise-daemon` and a
dedicated `dufs:dufs` user. So the module installs the package and writes
`/etc/dufs/config.yaml` — it does not generate a service. The blob mechanism stays
for things that genuinely are not packaged; using it where a package exists means
inheriting none of the distro's init script, user, or upgrades.

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

## Tests

```sh
./tests/run.sh
```

123 checks, no Alpine and no container required: plan assertions, a synthetic-root
apply, the external commands that would have run, idempotence, dry-run,
status/diff drift detection, a host-shape matrix, blob checksum verification over
`file://`, per-arch blob resolution, the bootstrap-before-packages ordering
invariant, both persist backends, and the secrets path end to end with real age
keys — byte-exact round-trip of a private key, no plaintext in the plan, and a
`diff` that withholds content. `dash -n` covers syntax; `shellcheck -s sh`
runs when installed.

### What the tests cannot cover

The real behaviour of `apk`, `lbu`, `rc-update` and `awall` needs actual Alpine.
The suite asserts those are invoked correctly; it cannot assert they do what they
are supposed to. Verify on a real target before trusting a spore with a box you
cannot physically reach — especially `awall activate`.

## Not yet

`build` (bake an apkovl offline so a box boots already configured) · the fleet
layer (`diff hostA hostB`, profile inheritance,
`push` over ssh).

`build` is the reason the planner is pure. It is one more executor over an action
list that already exists, plus a `tar` — not a redesign.
