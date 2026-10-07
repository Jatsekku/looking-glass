# NixOS Looking Glass module

A flexible, declarative NixOS module designed to configure and manage **Looking Glass** virtual displays for QEMU/KVM virtual machines.
This module supports both **KVMFR (`/dev/kvmfr`)** device nodes and standard **shared memory files (`/dev/shm`)**.

## Features

- **Multi-Display Management**: Define multiple virtual displays independently.
- **Dual Backend Support**: Choose between KVMFR or standard shared memory files for each individual display.
- **Automatic Memory Sizing**: Automatically computes the minimum required memory based on display dimmensions.
- **Permissions Handling**: Configure user ownership, group permissions, and file modes per virtual display.
- **NixVirt Integration**: Exposes a read-only `nixVirtSettingsFor` attribute set that generates pre-configured QEMU command-line arguments and shared memory configurations ready for use with NixVirt.
---

## Options reference

### NixOS module options <br>`virtualisation.looking-glass`

| Option               | Type                   | Default       | Description                                                                        |
| :------------------- | :--------------------- | :------------ | :--------------------------------------------------------------------------------- |
| `enable`             | bool                   | `false`       | Whether to enable the Looking Glass module configuration.                          |
| `enableClient`       | bool                   | `false`       | Whether to install the `looking-glass-client` package in the system environment.   |
| `displays`           | attrs of displayModule | `{}`          | An attribute set defining your virtual displays.                                   |
| `nixVirtSettingsFor` | attrs                  | *(read-only)* | Read-only attribute set containing ready-to-use NixVirt settings for each display. |

### Displays (displayModule) options <br>`virtualisation.looking-glass.displays.<name>`)

| Option              | Type          | Default  | Description                                                                          |
| :------------------ | :------------ | :------- | :----------------------------------------------------------------------------------- |
| `width`             | ints.positive | `1920`   | Display width in pixels.                                                             |
| `height`            | ints.positive | `1080`   | Display height in pixels.                                                            |
| `bpp`               | ints.positive | `4`      | Bytes per pixel.                                                                     |
| `kvmfr`             | bool          | `true`   | Whether to use the KVMFR kernel module (`true`) or standard shared memory (`false`). |
| `permissions.user`  | string        | `"root"` | Owner of the shared memory device or file.                                           |
| `permissions.group` | string        | `"root"` | Group of the shared memory device or file.                                           |
| `permissions.mode`  | string        | `"0600"` | Access permission mode for the shared memory.                                        |

---

## Usage examples
1. Add the module to your `flake.nix` inputs: 
```nix
looking-glass = {
  url = "github:Jatsekku/looking-glass";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

2. Import the NixOS module:
```nix
imports = [ inputs.looking-glass.nixosModules.default ]; 
```

3. Enable module, looking-glass-client and add display:
```nix
{
  virtualisation.looking-glass = {
    enable = true;
    enableClient = true;

    displays.primary = {
      width = 2560;
      height = 1440;
      kvmfr = true;
      permissions = {
        user = "your-username";
        group = "kvm";
        mode = "0660";
      };
    };
  };
}
```
