# nvsync

**NVIDIA VRR & G-Sync Manager for Linux**

A comprehensive Variable Refresh Rate management tool that provides proper G-Sync, G-Sync Compatible, and VRR support for Linux gaming with full Wayland and X11 support.

## Driver 590+ Optimizations

nvsync 0.2.0 is optimized for NVIDIA 590.48.01+ drivers which include:
- **Wayland 1.20+ minimum** - Full VRR support on modern Wayland compositors
- **Improved DPI reporting** - Correct display detection (fixes Samsung Odyssey Neo G9 and similar)
- **Better swapchain behavior** - VRR transitions remain smooth during window operations

## Overview

nvsync solves the fragmented VRR experience on Linux by providing:

- **Unified VRR Control** - Single interface for G-Sync, FreeSync, VRR
- **Per-Game Configuration** - Custom refresh rate limits per game
- **Frame Limiter** - GPU-level frame limiting without input lag
- **VRR Range Extension** - LFC (Low Framerate Compensation) support
- **Compositor Integration** - Works with KWin, Mutter, wlroots

## The Problem

```
Linux VRR Status (Before nvsync):
┌─────────────────────────────────────────────────────────────┐
│ G-Sync Module:     Works (but limited configuration)        │
│ G-Sync Compatible: Partially works (requires tweaks)        │
│ VRR/FreeSync:      Hit or miss (compositor dependent)       │
│ Frame Limiting:    External tools only (MangoHud, libstrangle)│
│ LFC Support:       Broken on most setups                    │
└─────────────────────────────────────────────────────────────┘

With nvsync:
┌─────────────────────────────────────────────────────────────┐
│ All VRR modes:     Unified control with automatic detection │
│ Frame Limiting:    Native GPU-level limiting (zero lag)     │
│ LFC:               Automatic when below VRR range           │
│ Per-game configs:  Automatic profile switching              │
└─────────────────────────────────────────────────────────────┘
```

## Features

### VRR Modes Supported

| Mode | Hardware | Support Level |
|------|----------|---------------|
| **G-Sync** | Native G-Sync monitors | Full |
| **G-Sync Compatible** | FreeSync monitors | Full |
| **VRR (HDMI 2.1)** | HDMI 2.1 VRR TVs | Full |
| **FreeSync** | AMD-certified monitors | Via compatibility mode |

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        nvsync                                │
├───────────┬───────────┬───────────┬────────────────────────┤
│   detect  │  control  │   limit   │      profiles          │
│  (modes)  │   (vrr)   │  (fps)    │      (games)           │
├───────────┴───────────┴───────────┴────────────────────────┤
│                   Display Backend                            │
│  ┌──────────────┬──────────────┬──────────────────────┐    │
│  │   Wayland    │     X11      │      DRM/KMS         │    │
│  │  (wl_output) │ (RandR/NV)   │    (direct)          │    │
│  └──────────────┴──────────────┴──────────────────────┘    │
├─────────────────────────────────────────────────────────────┤
│              NVIDIA Driver (nvidia-settings API)             │
└─────────────────────────────────────────────────────────────┘
```

## Usage

### CLI Tool

```bash
# Check VRR status on all displays
nvsync status

# Enable VRR on primary display
nvsync enable

# Enable with specific settings
nvsync enable --display DP-1 --min-fps 30 --max-fps 165

# Set frame limiter (GPU-level, no input lag)
nvsync limit 144

# Disable VRR
nvsync disable

# Show VRR range and LFC status
nvsync info

# Per-game profile
nvsync profile set "Cyberpunk 2077" --fps-limit 60 --vrr on

# Watch VRR state in real-time
nvsync monitor
```

### Library API (Zig)

```zig
const nvsync = @import("nvsync");

pub fn main() !void {
    var ctx = try nvsync.init(.auto);
    defer ctx.deinit();

    // Get display info
    const displays = try ctx.getDisplays();
    for (displays) |display| {
        std.log.info("Display: {s}", .{display.name});
        std.log.info("  VRR Range: {d}-{d}Hz", .{
            display.vrr_min,
            display.vrr_max,
        });
        std.log.info("  VRR Active: {}", .{display.vrr_active});
    }

    // Enable VRR
    try ctx.enableVrr(.{
        .display = "DP-1",
        .min_fps = 30,
        .max_fps = 165,
        .lfc_enabled = true,
    });

    // Set frame limiter
    try ctx.setFrameLimit(144);
}
```

### C API

```c
#include <nvsync/nvsync.h>

nvsync_ctx_t* ctx = nvsync_init(NVSYNC_AUTO);

// Get VRR info
nvsync_display_info_t info;
nvsync_get_display_info(ctx, "DP-1", &info);
printf("VRR Range: %d-%dHz\n", info.vrr_min, info.vrr_max);

// Enable VRR
nvsync_vrr_config_t config = {
    .display = "DP-1",
    .min_fps = 30,
    .max_fps = 165,
    .lfc = true,
};
nvsync_enable_vrr(ctx, &config);

// Set frame limit
nvsync_set_frame_limit(ctx, 144);

nvsync_cleanup(ctx);
```

## Frame Limiting

nvsync provides GPU-level frame limiting that doesn't add input lag:

```bash
# Traditional frame limiters (add input lag):
# - MangoHud fps_limit (CPU-side, adds ~1 frame lag)
# - libstrangle (CPU-side)
# - In-game limiters (varies)

# nvsync frame limiting (zero added lag):
nvsync limit 144  # Uses NVIDIA driver's native limiter
```

### How It Works

```
Traditional CPU Limiter:
┌──────────┐    ┌──────────┐    ┌──────────┐
│  Game    │ →  │  Sleep   │ →  │  GPU     │  = +1 frame input lag
│  Logic   │    │  (wait)  │    │  Render  │
└──────────┘    └──────────┘    └──────────┘

nvsync GPU Limiter:
┌──────────┐    ┌──────────┐
│  Game    │ →  │  GPU     │  = Zero added input lag
│  Logic   │    │  (paces) │    (GPU handles timing)
└──────────┘    └──────────┘
```

## Compositor Integration

### KDE Plasma (KWin)

```bash
# Automatic integration
nvsync kde enable

# Set VRR policy
nvsync kde policy automatic  # or: always, never
```

### GNOME (Mutter)

```bash
# Enable experimental VRR
nvsync gnome enable

# Requires GNOME 46+ for full support
```

### wlroots (Sway, Hyprland)

```bash
# Enable via output configuration
nvsync wlroots enable --output DP-1
```

## Building

```bash
# Build CLI and library
zig build -Doptimize=ReleaseFast

# Build with Wayland support
zig build -Doptimize=ReleaseFast -Dwayland=true

# Build with X11 support
zig build -Doptimize=ReleaseFast -Dx11=true

# Run tests
zig build test
```

## Installation

```bash
# System-wide install
sudo zig build install --prefix /usr/local

# User install
zig build install --prefix ~/.local

# Install udev rules for non-root access
sudo cp udev/99-nvsync.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
```

## Related Projects

| Project | Purpose | Integration |
|---------|---------|-------------|
| **nvcontrol** | GUI control center | VRR settings panel |
| **nvlatency** | Latency tools | Frame timing coordination |
| **nvvk** | Vulkan extensions | VK_KHR_present_wait support |

## Requirements

- NVIDIA GPU (GTX 1000 series or newer for VRR)
- NVIDIA driver 590+ recommended (590.48.01+)
  - Minimum: 470+ (basic functionality)
- G-Sync or G-Sync Compatible monitor
- Zig 0.16+
- Linux 5.10+ (for VRR/DRM support)

## License

MIT License - See [LICENSE](LICENSE)

## Contributing

See [TODO.md](TODO.md) for the development roadmap.
