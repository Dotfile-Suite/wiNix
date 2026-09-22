# winix: a NixOS module wrapping WinApps (this repo) so Windows apps can be
# declared like:
#
#   winix.apps = [ { name = "access"; winExecutable = "C:\\..."; } ];
#
# It only generates config for the `docker`/`podman` WAFLAVOR (a single
# shared Windows VM, WinApps' own recommended path). Per-app isolation is
# explicitly out of scope for v1 -- see docs/winix/design-decisions.md.
#
# Curried on `self` so it can reach this flake's own `packages.winapps`
# without the consuming flake needing to add anything beyond this module.
{ self }:
{ config, lib, pkgs, ... }:
let
  cfg = config.winix;

  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    mkMerge
    types
    concatStringsSep
    concatMapStringsSep
    optionalString
    ;

  winapps = self.packages.${pkgs.system}.winapps;

  appOpts = { name, ... }: {
    options = {
      name = mkOption {
        type = types.strMatching "[a-zA-Z0-9_-]+";
        default = name;
        description = "App id. Becomes the shell command and the WinApps shortcut name.";
      };

      fullName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Human-readable name shown in shortcuts. Defaults to `name`.";
      };

      winExecutable = mkOption {
        type = types.str;
        example = "C:\\Program Files\\Foo\\foo.exe";
        description = "In-guest path to the installed app's .exe (WinApps' WIN_EXECUTABLE).";
      };

      installer = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "installer.exe";
        description = ''
          Path, relative to `<installers>/<name>/`, to a silent-installable
          .exe tracked in the Nix store. Copied into the VM's OEM first-boot
          payload and run once, the first time the Windows VM is created.

          Leave null for an app you install by hand over RDP -- you still
          get a shortcut/command, you just skip automated install.
        '';
      };

      installArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "/S" ];
        description = "Silent-install flags appended after the installer path.";
      };

      categories = mkOption {
        type = types.listOf types.str;
        default = [ "WinApps" ];
        description = "freedesktop categories for the generated .desktop entry.";
      };

      mimeTypes = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "MIME types this app should be offered for, e.g. from Nautilus.";
      };
    };
  };

  displayName = app: if app.fullName != null then app.fullName else app.name;

  semicolonList = xs: optionalString (xs != [ ]) (concatStringsSep ";" xs + ";");

  infoFileText = app: ''
    NAME="${displayName app}"
    FULL_NAME="${displayName app}"
    WIN_EXECUTABLE="${app.winExecutable}"
    CATEGORIES="${semicolonList app.categories}"
    MIME_TYPES="${semicolonList app.mimeTypes}"
  '';

  installableApps = builtins.filter (a: a.installer != null) cfg.apps;

  installerGuestPath = app: "installers\\${app.name}\\installer.exe";

  installBatAppend = concatMapStringsSep "\n" (app: ''
    echo [INFO] winix: installing ${app.name}...
    "%~dp0${installerGuestPath app}" ${concatStringsSep " " app.installArgs}
  '') installableApps;

  generatedInstallBat = ''
    ${builtins.readFile ../oem/install.bat}

    :: --- winix: apps declared via winix.apps, installed once on first boot ---
    ${installBatAppend}
  '';

  winappsConfText = ''
    RDP_USER="${cfg.rdp.user}"
    RDP_IP="127.0.0.1"
    WAFLAVOR="${cfg.flavor}"
  '' + optionalString (cfg.rdp.password != null) ''
    RDP_PASS="${cfg.rdp.password}"
  '' + optionalString cfg.rdp.fullscreen ''
    RDP_FLAGS_WINDOWS="/f"
    RDP_FLAGS_NON_WINDOWS="/size:100%"
  '' + optionalString cfg.autopause.enable ''
    AUTOPAUSE="on"
    AUTOPAUSE_TIME="${toString cfg.autopause.time}"
    AUTOPAUSE_ACTION="${cfg.autopause.action}"
  '';

  composeYamlText = ''
    name: "winix"
    volumes:
      data:
    services:
      windows:
        image: ghcr.io/dockur/windows:latest
        container_name: WinApps
        environment:
          VERSION: "${cfg.vm.version}"
          RAM_SIZE: "${cfg.vm.ramSize}"
          CPU_CORES: "${toString cfg.vm.cpuCores}"
          DISK_SIZE: "${cfg.vm.diskSize}"
          USERNAME: "${cfg.rdp.user}"
          PASSWORD: "${if cfg.rdp.password != null then cfg.rdp.password else ""}"
          HOME: "''${HOME}"
        ports:
          - "127.0.0.1:8006:8006"
          - "127.0.0.1:3389:3389/tcp"
          - "127.0.0.1:3389:3389/udp"
        cap_add:
          - NET_ADMIN
          - NET_RAW
        stop_grace_period: 120s
        restart: on-failure
        volumes:
          - data:/storage
          - ''${HOME}:/shared
          - ./oem:/oem
        devices:
          - /dev/kvm
          - /dev/net/tun
  '';

  userHome = "/home/${cfg.systemUser}";
  configDir = "${userHome}/.config/winapps";

  perAppInstall = lib.concatMapStrings (app: ''
    install -d -m755 "$oem/installers/${app.name}"
    install -m755 "${cfg.installers}/${app.name}/${app.installer}" \
      "$oem/installers/${app.name}/installer.exe"
  '') installableApps;

  perAppShortcut = lib.concatMapStrings (app: ''
    install -d -m755 "${sysAppPath}/apps/${app.name}"
    install -m644 ${pkgs.writeText "winix-${app.name}-info" (infoFileText app)} \
      "${sysAppPath}/apps/${app.name}/info"
  '') cfg.apps;

  sysAppPath = "/usr/local/share/winapps";

  wrapperPackages = map (
    app: pkgs.writeShellScriptBin app.name ''exec ${winapps}/bin/winapps ${app.name} "$@"''
  ) cfg.apps;

in
{
  options.winix = {
    enable = mkEnableOption "winix (WinApps, driven from Nix config)";

    systemUser = mkOption {
      type = types.str;
      description = ''
        The Linux account winix manages WinApps config for -- config lands
        under that user's $HOME/.config/winapps. Single-user for v1.
      '';
    };

    flavor = mkOption {
      type = types.enum [ "docker" "podman" ];
      default = "docker";
      description = "WinApps WAFLAVOR. v1 only targets the shared-VM container backends.";
    };

    installers = mkOption {
      type = types.path;
      description = ''
        Root directory holding one subdirectory per app: `<installers>/<name>/<installer>`.
      '';
    };

    rdp = {
      user = mkOption {
        type = types.str;
        default = "MyWindowsUser";
        description = "Windows account name, used for both the VM and the RDP login.";
      };

      password = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Plaintext Windows account password. Ends up world-readable in
          /nix/store -- fine for a throwaway local test VM, not recommended
          otherwise. Prefer setting the password by hand in the generated
          winapps.conf/compose.yaml if that matters to you; a passwordFile
          option is future work (see docs/winix/design-decisions.md).
        '';
      };

      fullscreen = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Launch every winapps RDP session maximized to fill the local
          screen: `/f` (true fullscreen) for `winapps windows` full-desktop
          sessions, `/size:100%` for per-app RemoteApp/RAIL sessions (RAIL
          has no real "fullscreen" concept -- sizing the virtual desktop to
          the local screen is the closest equivalent, so a RAIL app only
          fills the screen if it also opens maximized on the Windows side).
        '';
      };
    };

    vm = {
      version = mkOption {
        type = types.str;
        default = "11";
        description = "dockur/windows VERSION.";
      };
      ramSize = mkOption { type = types.str; default = "4G"; };
      cpuCores = mkOption { type = types.int; default = 4; };
      diskSize = mkOption { type = types.str; default = "64G"; };
    };

    autopause = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Automatically pause or stop the Windows container after RDP
          sessions have been idle for `autopause.time` seconds.
        '';
      };

      time = mkOption {
        type = types.int;
        default = 300;
        description = ''
          Seconds of inactivity (no WinApps RDP session open) to tolerate
          before acting. Must be >= 20; rounds down to the nearest 10.
        '';
      };

      action = mkOption {
        type = types.enum [ "pause" "stop" ];
        default = "pause";
        description = ''
          `pause` freezes the container -- resuming is near-instant, but it
          still reserves its RAM while paused. `stop` fully stops the
          container, freeing its RAM and CPU back to the host at the cost of
          a full Windows boot on next launch. `stop` requires `flavor` to be
          `docker` or `podman` (falls back to `pause` under `libvirt`).
        '';
      };
    };

    apps = mkOption {
      type = types.listOf (types.submodule appOpts);
      default = [ ];
      description = "Windows apps to expose as native-feeling commands.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.rdp.password != null;
        message = "winix.rdp.password must be set for v1 (auto-templates winapps.conf + compose.yaml).";
      }
    ];

    environment.systemPackages = [ winapps ] ++ wrapperPackages;

    system.activationScripts.winixConfig = {
      deps = [ "users" ];
      text = ''
        set -e
        oem="${configDir}/oem"

        install -d -m700 -o ${cfg.systemUser} -g users "${configDir}"
        install -d -m755 -o ${cfg.systemUser} -g users "$oem"

        install -m644 -o ${cfg.systemUser} -g users \
          ${pkgs.writeText "winix-compose.yaml" composeYamlText} \
          "${configDir}/compose.yaml"

        install -m600 -o ${cfg.systemUser} -g users \
          ${pkgs.writeText "winix-winapps.conf" winappsConfText} \
          "${configDir}/winapps.conf"

        install -m755 -o ${cfg.systemUser} -g users \
          ${pkgs.writeText "winix-install.bat" generatedInstallBat} \
          "$oem/install.bat"

        for f in RDPApps.reg Container.reg NetProfileCleanup.ps1 TimeSync.ps1; do
          install -m644 -o ${cfg.systemUser} -g users "${../oem}/$f" "$oem/$f"
        done

        ${perAppInstall}

        install -d -m755 "${sysAppPath}/apps"
        ${perAppShortcut}
      '';
    };
  };
}
