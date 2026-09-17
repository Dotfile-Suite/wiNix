# winix todo

## Done
- [x] Fork WinApps into this repo, confirm existing `winapps`/`winapps-launcher`
      packages still build (`nix flake check`).
- [x] `modules/winix.nix`: NixOS module generating `winapps.conf`,
      `compose.yaml`, per-app `info` shortcuts, per-app shell commands, and
      an OEM-injected silent-install payload from `winix.apps`.
- [x] Wire `flake.nix` to export `nixosModules.winix`.
- [x] Eval-test the module against a synthetic `nixosSystem` (no real
      docker/podman on this box) — activation script content checked by
      hand, looks correct.

## Next (for actually running this)
- [ ] Wire `winix` into a real system flake (e.g. the user's dotfiles) with
      `virtualisation.docker.enable = true;` (or podman) and a real
      `winix.apps` list, and `nixos-rebuild switch`.
- [ ] Run `docker compose -f ~/.config/winapps/compose.yaml up -d`, confirm
      the Windows VM installs, RDP comes up, and `winapps.conf`/shortcut
      generation actually match what `bin/winapps` expects at runtime.
- [ ] Confirm the OEM-injected installer loop in `install.bat` actually
      fires at first boot and installs the declared app silently.
- [ ] Confirm the generated per-app command (e.g. `foo`) launches the app
      as a RemoteApp window.

## Known gaps (see design-decisions.md for why these are deferred)
- [ ] Installers only run on first VM creation, not when adding an app to
      an already-provisioned VM. Needs either a documented "wipe the data
      volume" workflow or a `winix reprovision <app>` command that drives
      a silent install against a live VM over RDP.
- [ ] `winix.rdp.password` is plaintext in `/nix/store`. Add a
      `passwordFile` option (read at activation time only, never
      eval time) before using this for anything that matters.
- [ ] No `libvirt` flavor support — only `docker`/`podman` config is
      generated. Not needed unless we hit a real reason to want it.
- [ ] No per-app isolation (see design-decisions.md — accepted tradeoff for
      the shared-VM footprint win, not an oversight).

## Future / explicitly out of scope for now
- Per-project/temp app declarations from a consumer's own `flake.nix`
  (`nix run`-style ephemeral apps not permanently declared in system config).
- Eventually: wrap or reimplement the app-lifecycle piece as a module under
  `DFSuite/core` once `core` itself is further along.
