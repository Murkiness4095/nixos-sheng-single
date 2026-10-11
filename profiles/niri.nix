# Niri + Noctalia desktop profile for the default image.
#
# Everything comes from nixpkgs NixOS modules -- no flake inputs:
#   programs.niri                                  (compositor + session)
#   programs.noctalia                              (shell)
#   services.displayManager.noctalia-greeter       (greetd greeter)
#
# The base system (modules/hardware.nix) already opens tty1 to root; this
# profile puts a graphical session on the same seat via greetd auto-login.
{ config, lib, pkgs, ... }:

let
  autoLoginUser = "root";

  # Noctalia only auto-binds a backlight whose sysfs parent lives under a DRM
  # connector, or when the output name starts with eDP. sheng's backlight is
  # the I2C ktz8866 next to the DSI panel, so without an explicit mapping the
  # shell skips it ("could not be matched to an active output") and offers no
  # brightness control at all. Connector name as under wlr-randr; the KTZ8866
  # chips are named in docs/DEVELOPMENT.md (sheng,ktz8866-status).
  noctaliaConfigHome = "/var/lib/noctalia-config";
  noctaliaConfigFile = pkgs.writeText "noctalia-config.toml" ''
    [brightness.monitor.DSI-1]
    backend = "backlight"
    backlight_device = "ktz8866-backlight"
  '';

  # niri resolves $XDG_CONFIG_HOME/niri/config.kdl, falling back to
  # /etc/niri/config.kdl, and only uses the config embedded in the binary when
  # neither exists. Almost every section defaults when omitted -- the key
  # bindings explicitly do not, so a config file that only appends would
  # silently drop every default binding. Include niri's packaged default
  # config and only add what this device needs.
  niriConfig = ''
    include "${pkgs.niri.doc}/share/doc/niri/default-config.kdl"

    // sheng: Noctalia is the shell, started with the platform config home so
    // brightness works out of the box.
    spawn-at-startup "${lib.getExe' pkgs.coreutils "env"}" "NOCTALIA_CONFIG_HOME=${noctaliaConfigHome}" "${lib.getExe config.programs.noctalia.package}"

    // sheng: fcitx5 with the Wayland input-method frontend (niri implements
    // zwp_input_method_v2, so text fields go through the compositor).
    spawn-at-startup "${config.i18n.inputMethod.package}/bin/fcitx5" "-d"
  '';
in
{
  # -- compositor ------------------------------------------------------------
  programs.niri.enable = true;
  environment.etc."niri/config.kdl".text = niriConfig;

  # -- shell -----------------------------------------------------------------
  # systemd user service is off: a greetd session does not reliably reach
  # graphical-session.target before niri has created the Wayland socket, so
  # Noctalia is started from the session instead (see niriConfig).
  programs.noctalia = {
    enable = true;
    recommendedServices.enable = true; # NetworkManager, bluetooth, upower, ppd
    systemd.enable = false;
  };

  # Mutable config home, seeded only when the file is missing ("C"): values
  # changed in the Noctalia settings UI survive later activations.
  systemd.tmpfiles.rules = [
    "d ${noctaliaConfigHome} 0755 root root -"
    "d ${noctaliaConfigHome}/noctalia 0755 root root -"
    "C ${noctaliaConfigHome}/noctalia/config.toml 0644 root root - ${noctaliaConfigFile}"
  ];

  # -- greeter ---------------------------------------------------------------
  services.displayManager.noctalia-greeter = {
    enable = true;
    # On-screen keyboard at the greeter is UNVERIFIED ON THIS DEVICE -- the
    # greeter is Quickshell-based; check a keyboard appears on the password
    # field, otherwise log in via a USB keyboard on tty1 (root autologin is
    # on, so the greeter only shows on logout/lock anyway).
    settings = { };
  };

  # Tablet: no physical keyboard by default, so the session auto-logs-in.
  # greetd has no services.displayManager.autoLogin path in this nixpkgs --
  # initial_session is the mechanism (it also disables greetd's restart, so a
  # crash of the session does not loop into re-login). The greeter still
  # appears on logout / screen lock.
  services.greetd = {
    enable = true;
    settings.initial_session = {
      command = "${lib.getExe pkgs.niri} --session";
      user = autoLoginUser;
    };
  };

  # -- desktop plumbing ------------------------------------------------------
  # niri's NixOS module defaults gnome-keyring on, which hangs the greetd PAM
  # stack (greetd PAM is assembled from login; the greeter stage has no
  # session D-Bus). This device has no use for the keyring.
  services.gnome.gnome-keyring.enable = false;

  # Greetd owns the VT.
  services.kmscon.enable = lib.mkForce false;

  # Noctalia and modern Wayland desktops need it.
  security.polkit.enable = lib.mkDefault true;

  # gnome portal for screen sharing/screenshot, gtk for file chooser; the
  # wlr portal's ScreenCast is the weaker path here.
  xdg.portal = {
    enable = true;
    extraPortals = with pkgs; [
      xdg-desktop-portal-gnome
      xdg-desktop-portal-gtk
    ];
    config.niri = {
      default = [ "gnome" "gtk" ];
      "org.freedesktop.impl.portal.ScreenCast" = [ "gnome" ];
      "org.freedesktop.impl.portal.Screenshot" = [ "gnome" ];
      "org.freedesktop.impl.portal.FileChooser" = [ "gtk" ];
      # programs.niri defaults the Secret interface to gnome-keyring; with the
      # keyring off, collapse it to an empty backend instead.
      "org.freedesktop.impl.portal.Secret" = lib.mkForce "";
    };
  };

  hardware.graphics.enable = lib.mkDefault true;

  # The sheng kernel suspend path is unreliable (see TODO.md); do not let a
  # stray lid/power key event trigger it.
  services.logind.settings.Login.HandlePowerKey = lib.mkDefault "ignore";
  services.logind.settings.Login.HandleLidSwitch = lib.mkDefault "ignore";
  services.logind.settings.Login.HandleLidSwitchExternalPower = lib.mkDefault "ignore";
  services.logind.settings.Login.HandleLidSwitchDocked = lib.mkDefault "ignore";

  # -- input method ------------------------------------------------------------
  i18n.defaultLocale = "zh_CN.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "zh_CN.UTF-8";
    LC_IDENTIFICATION = "zh_CN.UTF-8";
    LC_MEASUREMENT = "zh_CN.UTF-8";
    LC_MONETARY = "zh_CN.UTF-8";
    LC_NAME = "zh_CN.UTF-8";
    LC_NUMERIC = "zh_CN.UTF-8";
    LC_PAPER = "zh_CN.UTF-8";
    LC_TELEPHONE = "zh_CN.UTF-8";
    LC_TIME = "zh_CN.UTF-8";
  };
  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5 = {
      waylandFrontend = true; # leaves GTK_IM_MODULE/QT_IM_MODULE unset
      addons = with pkgs; [
        fcitx5-rime
        fcitx5-gtk
      ];
    };
  };

  # -- fonts -------------------------------------------------------------------
  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif
    noto-fonts-color-emoji
    nerd-fonts.symbols-only
  ];

  # -- applications ---------------------------------------------------------------
  # Kept to packages with aarch64 substitutes so a cold CI build stays in the
  # hour range; extend from the device with `nix shell`/`nix profile install`.
  environment.systemPackages = with pkgs; [
    # shell / launcher
    alacritty
    fuzzel
    wl-clipboard
    brightnessctl # Noctalia OSD + brightness keys
    wlr-randr
    kanshi

    # files / media
    thunar
    tumbler
    imv
    celluloid
    ffmpeg
    poppler-utils
    file-roller

    # screenshot (grim+slurp cover the keybind default; satty for annotation)
    grim
    slurp
    satty

    # browser (aarch64 substitute on cache.nixos.org)
    firefox

    # tools
    yazi
    btop
    fastfetch
    git
    vim
    wget
    curl
    file
    fd
    ripgrep
    fzf
    tmux
    nix-output-monitor
    nvd

    # Wayland/X11 escape hatches
    xwayland-satellite
    maliit-keyboard # on-screen keyboard for the niri session

    # Wayland locker/idle (suspend itself stays off, see logind above)
    swayidle
    swaylock
  ];
}
