{
  description = "NixOS and U-Boot for the Xiaomi Pad 6S Pro 12.4 (sheng, SM8550)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Not a flake; buildUBoot just needs the tree. Override to iterate
    # without pushing: nix build .#u-boot --override-input u-boot-src ../u-boot
    u-boot-src = {
      url = "github:SushyDev/u-boot/xiaomi-sheng";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      u-boot-src,
    }:
    let
      # Building for this on anything else needs a remote builder.
      target = "aarch64-linux";

      hostSystems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      forHosts = f: nixpkgs.lib.genAttrs hostSystems (s: f nixpkgs.legacyPackages.${s});

      pkgs = import nixpkgs {
        system = target;
        overlays = [ (import ./overlay.nix) ];
        config.allowUnfree = true;
      };

      # Default image carries the desktop profile (profiles/niri.nix); a
      # terminal-only image is `shengSystem {}` with no extra modules --
      # both flavors build from the same flake.
      sheng = self.lib.shengSystem {
        inherit nixpkgs;
        modules = [ ./profiles/niri.nix ];
      };

      # Terminal-only variant: same platform modules, no desktop. Shares the
      # kernel/U-Boot closures with `sheng`, so CI pays for one kernel build.
      sheng-tty = self.lib.shengSystem { inherit nixpkgs; };

      # Diagnostic flavor: tty base plus the USB serial gadget console
      # (console=ttyGS0 alongside tty0). Kernel messages reach the USB port
      # once systemd loads g_serial, and the serial getty autologins to root.
      # panic=10 + oops=panic so a kernel panic is visible without any
      # display: the tablet reboots itself ~10s after the panic, which reads
      # as a boot loop instead of a black screen -- that distinguishes
      # "panicked" from "hung alive but no picture". Costs USB host mode.
      #
      # The USB channel is a bonus, not the plan: g_serial is a module, so the
      # port only exists once systemd has mounted the rootfs and run
      # modules-load. A kernel that dies earlier produces an empty window and
      # says nothing. The panel is the channel that is known to work -- the
      # measured failure shows kernel text on it -- so these parameters make
      # the panel carry the whole story by itself:
      #
      #   fbcon=nodefer      this kernel sets CONFIG_FRAMEBUFFER_CONSOLE_
      #                      DEFERRED_TAKEOVER=y (sm8550.config:5197), so fbcon
      #                      binds at the first write to the console rather
      #                      than when msm registers the fbdev, and dumps the
      #                      log_buf_len=8M backlog in one unrepeatable burst.
      #                      nodefer binds it at registration: text starts
      #                      appearing with msm's probe and stays.
      #   ignore_loglevel    print every kernel message, not just <= KERN_WARNING
      #                      (hardware.nix pins consoleLogLevel at 4).
      #   initcall_debug     one line per initcall, so the boot becomes a
      #                      continuous scroll and the last line on the panel
      #                      names the initcall that died (kernel-parameters.txt:
      #                      "Useful for working out where the kernel is dying
      #                      during startup").
      #   keep_bootcon       do not unregister the boot console at handover --
      #                      aimed squarely at "the console vanished".
      #   consoleblank=0     rule out the console blanking timer.
      #   systemd.log_*      route userspace logs to the same panel console, so
      #                      a service that takes the display down (vconsole
      #                      setup, backlight restore, a vendor daemon) is
      #                      visible instead of silent.
      sheng-serial = self.lib.shengSystem {
        inherit nixpkgs;
        modules = [
          {
            services.shengSerialConsole.enable = true;
            boot.consoleLogLevel = 7;
            boot.kernelParams = [
              "panic=10"
              "oops=panic"
              "fbcon=nodefer"
              "ignore_loglevel"
              "initcall_debug"
              "keep_bootcon"
              "consoleblank=0"
              "systemd.log_level=debug"
              "systemd.log_target=console"
              "systemd.show_status=true"
            ];
          }
        ];
      };

      mkScripts =
        hostPkgs:
        let
          mk =
            name: runtimeInputs:
            hostPkgs.writeShellApplication {
              inherit name runtimeInputs;
              text = builtins.readFile (./scripts + "/${name}");
            };
          find-sheng = mk "find-sheng" [
            hostPkgs.openssh
            hostPkgs.netcat
          ];

          mkPython =
            name: runtimeInputs:
            hostPkgs.runCommand name
              {
                nativeBuildInputs = [
                  hostPkgs.python3
                  hostPkgs.makeWrapper
                ];
              }
              ''
                install -Dm755 ${./scripts}/${name} $out/bin/${name}
                patchShebangs $out/bin/${name}
                ${hostPkgs.lib.optionalString (runtimeInputs != [ ]) ''
                  wrapProgram $out/bin/${name} \
                    --prefix PATH : ${hostPkgs.lib.makeBinPath runtimeInputs}
                ''}
              '';

          # Its own derivation, so read-blackbox cannot find it as a sibling.
          exec = mkPython "exec" [ ];
        in
        {
          inherit find-sheng exec;

          read-blackbox = mkPython "read-blackbox" [ exec ];
          capture-linux-dpu = mkPython "capture-linux-dpu" [ exec ];

          soak = mk "soak" [
            hostPkgs.openssh
            hostPkgs.coreutils
            find-sheng
          ];

          sheng-mdss-status = mk "sheng-mdss-status" [
            hostPkgs.openssh
            hostPkgs.coreutils
            find-sheng
          ];

          builder = mk "builder" [
            hostPkgs.openssh
            hostPkgs.coreutils
          ];

          flash-uboot = mk "flash-uboot" [
            hostPkgs.openssh
            hostPkgs.coreutils
            find-sheng
          ];

          flash-rootfs = mk "flash-rootfs" [
            hostPkgs.android-tools
            hostPkgs.coreutils
          ];

          fastboot-flash = mk "fastboot-flash" [
            hostPkgs.android-tools
            hostPkgs.coreutils
            hostPkgs.gnugrep
          ];
        };
    in
    {
      lib = import ./lib { inherit self; };

      nixosModules = {
        default = ./modules;
        firmware = ./modules/firmware.nix;
      };

      overlays.default = import ./overlay.nix;

      nixosConfigurations.sheng = sheng;
      nixosConfigurations.sheng-tty = sheng-tty;
      nixosConfigurations.sheng-serial = sheng-serial;

      packages = forHosts (
        hostPkgs:
        mkScripts hostPkgs
        // nixpkgs.lib.optionalAttrs (hostPkgs.stdenv.hostPlatform.system == target) (
          {
            default = sheng.config.system.build.shengImage;

            nixos = sheng.config.system.build.shengImage;

            # Terminal-only image; same boot.img (U-Boot) serves both.
            nixos-tty = sheng-tty.config.system.build.shengImage;

            # USB serial gadget console image -- for reading kernel logs when
            # the display pipeline is the failure. Built by the workflow only
            # with the diagnostic input ticked.
            nixos-serial = sheng-serial.config.system.build.shengImage;

            u-boot = pkgs.callPackage ./packages/u-boot {
              src = u-boot-src;
              version = u-boot-src.shortRev or "dirty";
            };

            kernel = pkgs.shengKernel;
            mdss-test-module = pkgs.callPackage ./packages/kernel/mdss-test-module { };
          }
          // pkgs.shengPackages
        )
      );

      apps = forHosts (
        hostPkgs:
        builtins.mapAttrs (_: script: {
          type = "app";
          program = nixpkgs.lib.getExe script;
        }) (mkScripts hostPkgs)
      );

      formatter = forHosts (hostPkgs: hostPkgs.nixfmt-rfc-style);
    };
}
