{ config, pkgs, ... }:
with pkgs.lib;
let
  # This atrocity is necessary because the recently-added, well-intentioned,
  # and probably BUG-worthy `apply` argument of mkOption for
  # `boot.kernelPackages.kernel` calls .override on the value provided in this
  # config.  We can't use a drv that was created by overrideDerivation, since
  # the ultimate .override call during the evaluation of `system` will replace
  # any changes outside of arguments passed to the pkgFunc completely.
  kernel = makeOverridable (origArgs: addPassthru (pkgs.linuxManualConfig origArgs) { features.netfilterRPFilter = true; }) rec {
    allowImportFromDerivation = true; # set by linuxPackges_custom for a reason I didn't resolve
    version = "4.8.15";
    src = pkgs.fetchurl {
      url = "https://cdn.kernel.org/pub/linux/kernel/v4.x/linux-${version}.tar.xz";
      sha256 = "1vlgacsdcww333n9vm2pmdfkcpkjhavrh1aalrr7p6vj2c4jc18n";
    };
    configfile = /etc/nixos/kernel-4.4.1.config;
    # This patch hardcodes my utilite's mac into the igb driver, used for the
    # second nic. Since upgrading uboot, dmesg seems to suggest that the mac
    # cannot be read from NVM or is invalid for some other reason. Possibly the
    # better fix is to revert(? might be original already) to the original dtb
    # or to find a way to add my mac to the dtb, but i looked and could only
    # find the first embedded nic (the medial one) in the dtb.
    kernelPatches = [{ name = "hardcoded_mac"; patch = ./hardcoded_mac.patch; }]; # inline this with writeText?
  };
in
{
  time.timeZone = "America/Los_Angeles";
  nixpkgs.config.platform = systems.platforms.utilite;
  nixpkgs.config.allowUnfree = true;
  hardware.enableAllFirmware = true; # for mwifiex_sdio wifi module
  imports = [
    ./hardware-configuration.nix
  ];

  #zramSwap.enable = true;
  #zramSwap.numDevices = 4; # = num of CPUs

  boot = {
    initrd.kernelModules = [];
    kernelPackages = pkgs.linuxPackagesFor kernel;
    kernelModules = [];
    # dont think this is gonna be used but putting it here just for reference
    kernelParams = [
      "console=ttymxc3,115200"
      "video=mxcfb0:dev=hdmi,1920x1080@60,if=RGB24,bpp=16"
      "consoleblank=0"
      "cm_fx6_v4l"
      "dmfc=3"
      # this one's just a sentinel value to detect if this list is ever used
      "sentinel=this.cmdline.from.configuration.nix"
    ];
    cleanTmpDir = true;
    loader = {
      grub.enable = false;
      #generic-extlinux-compatible.enable = true;
      generationsDir.enable = true;
      #generationsDir.copyKernels = true;
    };
  };

  nixpkgs.config.packageOverrides = with pkgs.lib; pkgs: {
    # ubootTools is supposed to be only the tools from the uboot pkg, but it
    #   doesn't make fw_printenv and fw_setenv. Dunno if this is a BUG or not, but
    #   in any case, the below overrides the callPackage args as well as the buildPhase of
    #   the resulting derivation in order to build and install these 2 files (one a
    #   symlink to the other).
    # TODO: include fw_env.conf appropriate for the platform, once that's been sorted and set in attrs somewhere.
    ubootTools = overrideDerivation (pkgs.buildUBoot {
      targetPlatforms = platforms.linux;
      defconfig = "allnoconfig";
      installDir = "$out/bin";

      filesToInstall = [
        "tools/dumpimage"
        "tools/mkenvimage"
        "tools/mkimage"
        "tools/env/fw_printenv"
        "tools/env/fw_setenv"
      ];
    }) (oldAttrs: {
      buildPhase = ''
        make tools-all
        ln -s fw_printenv tools/env/fw_setenv
      '';
    });

    gettext = overrideDerivation pkgs.gettext ( oldAttrs: rec {
      name = "gettext-${version}";
      version = "0.19.6";
      src = pkgs.fetchurl {
        url = "mirror://gnu/gettext/${name}.tar.gz";
        sha256 = "0pb9vp4ifymvdmc31ks3xxcnfqgzj8shll39czmk8c1splclqjzd";
      };
    });

    nix = pkgs.nixUnstable;
    #nix = overrideDerivation pkgs.nix (oldAttrs: { patches = [ ./nix-arm-backbuild.patch ]; });

  };


  environment.systemPackages = with pkgs; [
    kermit
    i2c-tools

    mtdutils
    # TODO make uboot-pogo etc. drvs, wherever possible (those generate
    #   .kwb flashable images; turns out this is probaly a low priority for my usage)
    ubootTools
  ];

  services = {
    das_watchdog.enable = true;
    tlsdated.enable = true;
    udev.extraRules = ''
      KERNEL=="eth*", ATTR{address}=="00:01:c0:14:ae:00", NAME="medial"
      KERNEL=="eth*", ATTR{address}=="00:01:c0:14:aa:01", NAME="lateral"
    '';
  };

  networking = {
    hostName = "utilite";

    interfaces = {
      medial.useDHCP = true;
      lateral = {
        useDHCP = false;
        #ip4 = [ {address = "10.0.1.209"; prefixLength = 24; } ];
      };
    };

    wireless = {
      enable = true;
      interfaces = [ "mlan0" ];
      networks.mynetwork.psk = "mypwd";
    };

    firewall.allowPing = true;
  };
}
