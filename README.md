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
| `pkg` | `apk add` | append to `etc/apk/world` |
| `blob` | fetch, verify sha256, install | fetch into boot-media cache |
| `dir` / `file` | write under `/` | write under the staging tree |
| `svc` | `rc-update add` | symlink into `etc/runlevels/` |
| `firstboot` | run now | emit to `/etc/local.d/` |
| `persist` | (declaration) | already in the overlay |

`firstboot` is the phase distinction that matters: work that genuinely cannot be
planned statically — generating an ssh host key — is deferred rather than faked.

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

**Secrets are never carried.** Host keys are generated on arrival; passwords come
from the host. A spore is safe to commit.

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
| `ssh` | OpenSSH, keys, root/password policy | OpenRC |
| `dufs` | dufs file server, pinned musl binary, generated OpenRC service | OpenRC |
| `net` | hostname (anywhere), interfaces and DNS | NET_ADMIN for the latter |
| `firewall` | awall policy generated from every module's declared ports | NET_ADMIN, OpenRC |

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

87 checks, no Alpine and no container required: plan assertions, a synthetic-root
apply, the external commands that would have run, idempotence, dry-run,
status/diff drift detection, a host-shape matrix, blob checksum verification over
`file://`, and both persist backends. `dash -n` covers syntax; `shellcheck -s sh`
runs when installed.

### What the tests cannot cover

The real behaviour of `apk`, `lbu`, `rc-update` and `awall` needs actual Alpine.
The suite asserts those are invoked correctly; it cannot assert they do what they
are supposed to. Verify on a real target before trusting a spore with a box you
cannot physically reach — especially `awall activate`.

## Not yet

`build` (bake an apkovl offline so a box boots already configured) · `age`
-encrypted secrets · the fleet layer (`diff hostA hostB`, profile inheritance,
`push` over ssh).

`build` is the reason the planner is pure. It is one more executor over an action
list that already exists, plus a `tar` — not a redesign.
