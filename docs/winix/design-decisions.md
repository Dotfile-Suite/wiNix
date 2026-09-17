# winix design decisions

Short on purpose. This records why, not what — the code says what.

## Why this repo is a fork, not a rewrite

We first designed a from-scratch NixOS module: one Windows VM per app,
qcow2 backing-file overlays as per-app deltas, hand-rolled libvirt domain
generation, our own unattended-install automation. That plan is still
readable in the Claude session that produced it, but we did not build it.

Reason: WinApps already solves the hard parts — RDP RemoteApp compositing,
shared-folder redirection, and (via the `docker`/`podman` flavor) automated
unattended Windows install — as a working, field-tested shell-script tool.
Rebuilding that to get a Nix interface was solving an already-solved
problem for no real gain. Forking and adding a thin Nix layer on top gets
the same user-facing result (`winix.apps = [ ... ];`) for a fraction of the
effort, and leaves a shell-script codebase that is easy to read and easy to
peel apart later.

## Why one shared VM, not one VM per app

The from-scratch plan's per-app delta model would have used less disk than
N full VM copies, but WinApps' actual model — one shared Windows install,
persisted as a single Docker/Podman volume — uses *even less*, since app
dependencies (a shared .NET runtime, VC++ redistributables, etc.) are
installed once instead of once per app. We were 50/50 on isolation vs.
footprint; footprint won, and it came for free by not fighting the fork's
own grain.

Consequence: apps declared in `winix.apps` are not isolated from each
other. They all run inside the same Windows install. That is WinApps'
model upstream, unchanged.

## Why `docker`/`podman` (`WAFLAVOR`), not `libvirt`

WinApps supports three flavors. `docker`/`podman` (via dockur/windows) do
a fully automated unattended Windows install; `libvirt` assumes a VM you
already prepared by hand. Recommended-path-first: v1 targets `docker`.
`libvirt` stays available upstream if we ever want it, but nothing here
generates its config.

## What winix v1 actually adds over plain WinApps

Plain WinApps: you install Windows by hand, RDP in, install apps by hand,
then copy an `apps/<name>/info` file to register a shortcut.

winix: `winix.apps` in Nix config generates all of that — the shortcut
`info` file, a same-named shell command, `winapps.conf`, and a `compose.yaml`
— for a Linux user's `$HOME/.config/winapps/`. If an app entry sets
`installer`, that installer (a file tracked by the Nix store, resolved from
`<winix.installers>/<name>/<installer>`) is copied into the VM's OEM
first-boot payload and silently installed automatically, using the same
`oem/install.bat` mechanism dockur/windows already runs once at first boot
— we append to a copy of the upstream `install.bat`, we do not modify the
repo's own `./oem/install.bat` (that file stays untouched, for anyone doing
the manual `docker compose up` quickstart from a checkout).

## Known v1 limitation: installers only run on first VM creation

dockur/windows' OEM hook fires once, during the first boot after Windows
setup. Adding a *new* app to `winix.apps` on a VM that already exists does
not retroactively install it — the OEM script does not re-run. For now,
either install that app by hand over RDP (WinApps already gives it a
shortcut once `WIN_EXECUTABLE` is set), or delete the `data` volume to
force a fresh provision. A `winix reprovision` command that drives a
silent install against a *live* VM over RDP is real future work, not done
here — see `docs/winix/todo.md`.

## Where secrets live

`winix.rdp.password` is a plain Nix string and ends up in `/nix/store`
(world-readable, like every Nix store path). That is an accepted v1
shortcut, not a recommendation: it is fine for a throwaway local test VM.
A `passwordFile`-style option that only touches the secret in the
activation script (never in the store) is noted in `todo.md` and was in
the original from-scratch design; it just was not worth blocking v1 on.

## Where this is going

This repo is meant to eventually become a module under `DFSuite/core` (see
`../../core`), a Zig message-bus runtime. The plan is: keep iterating on
this fork as a working shell-script tool, and once `core` itself is far
enough along, wrap or reimplement the pieces that matter (most likely:
app lifecycle / launch, not the RDP or VM plumbing itself) as a `core`
module that publishes/subscribes on the bus instead of being a standalone
CLI. Nothing here should be read as a commitment to *when* that happens.
