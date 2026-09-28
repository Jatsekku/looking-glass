{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
with types;
let
  cfg = config.virtualisation.looking-glass;

  # Module describing permissions of shared memory
  permissionsModule = submodule {
    options = {
      user = mkOption {
        type = str;
        default = "root";
        description = "Owner of the shared memory";
      };
      group = mkOption {
        type = str;
        default = "root";
        description = "Group of the shared memory";
      };
      mode = mkOption {
        type = str;
        default = "0600";
        description = "Mode of the shared memory";
      };
    };
  };

  # Module describing single virtual display
  displayModule = submodule {
    options = {
      width = mkOption {
        type = ints.positive;
        default = 1920;
        description = "Display width in pixels";
      };

      height = mkOption {
        type = ints.positive;
        default = 1080;
        description = "Display height in pixels";
      };

      bpp = mkOption {
        type = ints.positive;
        default = 4;
        description = "Bytes per pixel";
      };

      permissions = mkOption {
        type = permissionsModule;
        default = { };
        description = "Permissions of underlaying shared memory for virtual display";
      };

      kvmfr = mkOption {
        type = bool;
        default = true;
        description = "Whether to use KVMFR for this display";
      };
    };
  };

  # Function to calculate required memory size for single virtual display
  memorySizeOfDisplay =
    display:
    let

      doubleUntilAtLeast = limit: x: if x >= limit then x else doubleUntilAtLeast limit (2 * x);

      ceilToPowerOf2 = n: if n <= 0 then 0 else doubleUntilAtLeast n 1;

      # https://looking-glass.io/docs/B7/install_libvirt/#determining-memory
      frameSizeBytes = display.width * display.height * display.bpp * 2;
      frameSizeMiB = frameSizeBytes / 1024 / 1024;
      requiredSizeMiB = frameSizeMiB + 10;
      totalSizeMib = ceilToPowerOf2 requiredSizeMiB;
    in
    totalSizeMib;

  MiB2Bytes = MiB: MiB * 1024 * 1024;

  # Set of displays with additional index and memory size
  displays =
    let
      # KVMFR displays come first
      displaysNames = builtins.attrNames cfg.displays;
      kvmfrDisplaysNames = filter (name: cfg.displays.${name}.kvmfr) displaysNames;
      nonKvmfrDisplaysNames = filter (name: !cfg.displays.${name}.kvmfr) displaysNames;

      allDisplaysNames = kvmfrDisplaysNames ++ nonKvmfrDisplaysNames;
    in
    mapAttrs (
      name: display:
      display
      // {
        # Name comes from set so it always will be present and unique
        index = lists.findFirstIndex (n: n == name) null allDisplaysNames;
        memorySize = memorySizeOfDisplay display;
      }
    ) cfg.displays;

  # Two sets of displays - for enabled and disabled KVMFR
  kvmfrDisplays = filterAttrs (_name: display: display.kvmfr) displays;
  nonKvmfrDisplays = filterAttrs (_name: display: !display.kvmfr) displays;

  # Check if at least one display has kvmfr enabled
  hasAnyKvmfrDisplay = kvmfrDisplays != { };
  # Check if at least one display has kvmfr disabled
  hasAnyNonKvmfrDisplay = nonKvmfrDisplays != { };

  # List of memory sizes for KVMFR-enabled displays
  kvmfrDisplaysMemorySizes = mapAttrsToList (_name: display: display.memorySize) kvmfrDisplays;

  # Udev rules (KVMFR)
  udevPackage = pkgs.writeTextFile {
    name = "kvmfr-udev-rules";
    destination = "/etc/udev/rules.d/99-kvmfr.rules";
    text = concatStringsSep "\n" (
      mapAttrsToList (name: display: ''
        # Virtual display: ${name}
        SUBSYSTEM=="kvmfr", KERNEL=="kvmfr${toString display.index}", OWNER="${display.permissions.user}", GROUP="${display.permissions.group}", MODE="${display.permissions.mode}", TAG+="systemd"
      '') kvmfrDisplays
    );
  };

  # Systemd tmpfiles (non-KVMFR)
  tmpfilesPackage = pkgs.writeTextFile {
    name = "looking-glass-tmpfiles";
    destination = "/lib/tmpfiles.d/10-looking-glass.conf";
    text = concatStringsSep "\n" (
      mapAttrsToList (name: display: ''
        # Virtual display: ${name}
        f /dev/shm/looking-glass-${name} ${display.permissions.mode} ${display.permissions.user} ${display.permissions.group} -
      '') nonKvmfrDisplays
    );
  };

  # Qemu Commandline (KVMFR)
  mkNixVirtQemuCommandLineArgs =
    displayName:
    let
      display = displays.${displayName};
      kvmfrPath = "/dev/kvmfr${toString display.index}";
      size = "${toString (MiB2Bytes display.memorySize)}";
    in
    if display.kvmfr then
      [
        { value = "-device"; }
        { value = "{\"driver\":\"ivshmem-plain\",\"id\":\"shmem0\",\"memdev\":\"looking-glass\"}"; }
        { value = "-object"; }
        {
          value = "{\"qom-type\":\"memory-backend-file\",\"id\":\"looking-glass\",\"mem-path\":\"${kvmfrPath}\",\"size\":${size},\"share\":true}";
        }
      ]
    else
      [ ];

  # Shmem (non-KVMFR)
  mkNixVirtSharedMemory =
    displayName:
    let
      display = displays.${displayName};
      size = display.memorySize;
    in
    if !display.kvmfr then
      [
        {
          name = "looking-glass-${displayName}";
          model.type = "ivshmem-plain";
          size = {
            unit = "M";
            count = size;
          };
        }
      ]
    else
      [ ];

  mkNixVirtSettings = displayName: {
    qemuCommandLineArgs = mkNixVirtQemuCommandLineArgs displayName;
    sharedMemory = mkNixVirtSharedMemory displayName;
  };

  # Configure cgroup device ACL for QEMU to allow access to KVMFR nodes
  kvmfrDevices = mapAttrsToList (_name: display: "/dev/kvmfr${toString display.index}") kvmfrDisplays;
in
{
  options.virtualisation.looking-glass = {
    enable = mkEnableOption "Looking glass";
    enableClient = mkEnableOption "Looking Glass Client";
    displays = mkOption {
      type = attrsOf displayModule;
      default = { };
      description = "Set of virtual displays";
    };
    nixVirtSettingsFor = mkOption {
      type = attrs;
      readOnly = true;
      default = mapAttrs (displayName: _: mkNixVirtSettings displayName) displays;
      description = "Read only settings for nixvirt";
    };
  };

  config = mkIf cfg.enable {
    boot = mkIf hasAnyKvmfrDisplay {
      # Add kvmfr kernel module
      extraModulePackages = with config.boot.kernelPackages; [ kvmfr ];
      # Load kvmfr module oon boot
      kernelModules = [ "kvmfr" ];
      # Set kvmfr shared memory size for virtual displays
      extraModprobeConfig = optionalString (kvmfrDisplaysMemorySizes != [ ]) ''
        options kvmfr static_size_mb=${concatStringsSep "," (map toString kvmfrDisplaysMemorySizes)}
      '';
    };

    virtualisation.libvirtd.qemu.verbatimConfig = mkIf hasAnyKvmfrDisplay (
      mkOptionDefault (mkAfter ''
        cgroup_device_acl = ${
          builtins.toJSON (
            [
              "/dev/full"
              "/dev/null"
              "/dev/ptmx"
              "/dev/random"
              "/dev/urandom"
              "/dev/userfaultfd"
              "/dev/zero"
            ]
            ++ kvmfrDevices
          )
        }
      '')
    );

    # Set udev rules for shared memory of virtual displays (KVMFR)
    services.udev.packages = optionals hasAnyKvmfrDisplay [ udevPackage ];

    # Set systemd tmpfiles for shared memory of virtual displays (non-KVMFR)
    systemd.tmpfiles.packages = optionals (nonKvmfrDisplays != { }) [ tmpfilesPackage ];

    # Install looking glass client
    environment.systemPackages = lib.optionals cfg.enableClient [ pkgs.looking-glass-client ];
  };
}
