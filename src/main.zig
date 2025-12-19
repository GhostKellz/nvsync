//! nvsync CLI - VRR/G-Sync Management for Linux
//!
//! Command-line interface for VRR and G-Sync control.

const std = @import("std");
const nvsync = @import("nvsync");
const posix = std.posix;
const fs = std.fs;
const mem = std.mem;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "status")) {
        try statusCommand(allocator);
    } else if (std.mem.eql(u8, command, "info")) {
        try infoCommand(allocator);
    } else if (std.mem.eql(u8, command, "displays")) {
        try displaysCommand(allocator);
    } else if (std.mem.eql(u8, command, "enable")) {
        try enableCommand(args[2..]);
    } else if (std.mem.eql(u8, command, "disable")) {
        try disableCommand(args[2..]);
    } else if (std.mem.eql(u8, command, "limit")) {
        try limitCommand(args[2..]);
    } else if (std.mem.eql(u8, command, "json")) {
        try jsonCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
    } else if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        printVersion();
    } else {
        std.debug.print("Unknown command: {s}\n\n", .{command});
        printUsage();
    }
}

fn printUsage() void {
    std.debug.print(
        \\nvsync - VRR/G-Sync Management for Linux v{d}.{d}.{d}
        \\
        \\USAGE:
        \\    nvsync <command> [options]
        \\
        \\COMMANDS:
        \\    status              Show VRR/G-Sync status
        \\    info                Show detailed system information
        \\    displays            List connected displays with VRR info
        \\    enable [display]    Enable VRR for display (or all)
        \\    disable [display]   Disable VRR for display (or all)
        \\    limit <fps>         Set frame rate limit
        \\    json <subcommand>   Output as JSON (status, displays)
        \\    help                Show this help message
        \\    version             Show version information
        \\
        \\EXAMPLES:
        \\    nvsync status
        \\    nvsync displays
        \\    nvsync enable DP-1
        \\    nvsync limit 144
        \\    nvsync json status
        \\
        \\VRR MODES:
        \\    G-Sync           - Native G-Sync module (dedicated hardware)
        \\    G-Sync Compatible - Adaptive Sync (FreeSync/VRR monitors)
        \\    VRR              - HDMI 2.1 Variable Refresh Rate
        \\
    , .{
        nvsync.version.major,
        nvsync.version.minor,
        nvsync.version.patch,
    });
}

fn printVersion() void {
    std.debug.print("nvsync v{d}.{d}.{d}\n", .{
        nvsync.version.major,
        nvsync.version.minor,
        nvsync.version.patch,
    });
}

fn statusCommand(allocator: mem.Allocator) !void {
    std.debug.print("nvsync - VRR/G-Sync Status\n", .{});
    std.debug.print("==========================\n\n", .{});

    const status = try nvsync.getSystemStatus(allocator);
    defer {
        if (status.driver_version) |v| allocator.free(v);
        if (status.compositor) |c| allocator.free(c);
    }

    // GPU info
    std.debug.print("NVIDIA GPU:\n", .{});
    if (status.nvidia_detected) {
        std.debug.print("  [OK] Detected\n", .{});
        if (status.driver_version) |v| {
            std.debug.print("  Driver: {s}\n", .{v});
        }
    } else {
        std.debug.print("  [--] Not detected\n", .{});
    }

    // Display info
    std.debug.print("\nDisplays:\n", .{});
    std.debug.print("  Total:        {d}\n", .{status.display_count});
    std.debug.print("  VRR Capable:  {d}\n", .{status.vrr_capable_count});
    std.debug.print("  VRR Enabled:  {d}\n", .{status.vrr_enabled_count});

    // Compositor
    std.debug.print("\nCompositor:\n", .{});
    if (status.compositor) |c| {
        std.debug.print("  {s}\n", .{c});
    } else {
        std.debug.print("  Unknown\n", .{});
    }

    // VRR recommendations
    std.debug.print("\nRecommendations:\n", .{});
    if (status.vrr_capable_count > 0 and status.vrr_enabled_count == 0) {
        std.debug.print("  - VRR capable displays found but not enabled\n", .{});
        std.debug.print("  - Enable via compositor settings or 'nvsync enable'\n", .{});
    } else if (status.vrr_enabled_count > 0) {
        std.debug.print("  - VRR is active on {d} display(s)\n", .{status.vrr_enabled_count});
    } else if (status.vrr_capable_count == 0) {
        std.debug.print("  - No VRR capable displays detected\n", .{});
        std.debug.print("  - G-Sync or G-Sync Compatible monitor required\n", .{});
    }
}

fn infoCommand(allocator: mem.Allocator) !void {
    std.debug.print("nvsync System Information\n", .{});
    std.debug.print("=========================\n\n", .{});

    // Library version
    std.debug.print("Library Version:\n", .{});
    std.debug.print("  nvsync: v{d}.{d}.{d}\n\n", .{
        nvsync.version.major,
        nvsync.version.minor,
        nvsync.version.patch,
    });

    // GPU info
    std.debug.print("GPU Information:\n", .{});
    if (nvsync.isNvidiaGpu()) {
        std.debug.print("  Vendor: NVIDIA\n", .{});
        if (nvsync.getNvidiaDriverVersion(allocator)) |v| {
            defer allocator.free(v);
            std.debug.print("  Driver: {s}\n", .{v});
        }
    } else {
        std.debug.print("  Vendor: Unknown (not NVIDIA or driver not loaded)\n", .{});
    }

    // VRR requirements
    std.debug.print("\nVRR Requirements:\n", .{});
    std.debug.print("  G-Sync Module:      Any NVIDIA GPU\n", .{});
    std.debug.print("  G-Sync Compatible:  GTX 1000+, driver 440+ (590+ recommended)\n", .{});
    std.debug.print("  HDMI 2.1 VRR:       RTX 3000+, driver 470+ (590+ recommended)\n", .{});
    std.debug.print("  Note: Driver 590+ has improved DPI detection and Wayland 1.20+ support\n", .{});

    // Compositor detection
    std.debug.print("\nCompositor Support:\n", .{});
    std.debug.print("  KWin (KDE):    Full VRR support\n", .{});
    std.debug.print("  Mutter (GNOME): VRR support in GNOME 46+\n", .{});
    std.debug.print("  Hyprland:      Full VRR support\n", .{});
    std.debug.print("  Sway:          VRR via wlroots\n", .{});
    std.debug.print("  X11:           Limited (fullscreen only)\n", .{});
}

fn displaysCommand(allocator: mem.Allocator) !void {
    std.debug.print("Connected Displays\n", .{});
    std.debug.print("==================\n\n", .{});

    var manager = nvsync.DisplayManager.init(allocator);
    defer manager.deinit();

    try manager.scan();

    if (manager.count() == 0) {
        std.debug.print("No displays detected.\n", .{});
        return;
    }

    for (manager.displays.items, 0..) |display, i| {
        std.debug.print("Display {d}: {s}\n", .{ i + 1, display.name });
        std.debug.print("  Connector:  {s}\n", .{display.connection_type.name()});
        std.debug.print("  Resolution: {d}x{d}\n", .{ display.width, display.height });
        std.debug.print("  Refresh:    {d}-{d}Hz (current: {d}Hz)\n", .{ display.min_hz, display.max_hz, display.current_hz });
        std.debug.print("  VRR:\n", .{});
        std.debug.print("    Capable:     {s}\n", .{if (display.vrr_capable) "Yes" else "No"});
        std.debug.print("    G-Sync:      {s}\n", .{if (display.gsync_capable) "Yes" else "No"});
        std.debug.print("    Compatible:  {s}\n", .{if (display.gsync_compatible) "Yes" else "No"});
        std.debug.print("    LFC:         {s}\n", .{if (display.lfc_supported) "Yes" else "No"});
        std.debug.print("    Enabled:     {s}\n", .{if (display.vrr_enabled) "Yes" else "No"});
        std.debug.print("    Mode:        {s}\n", .{display.current_mode.name()});
        std.debug.print("\n", .{});
    }
}

fn enableCommand(args: []const []const u8) !void {
    const display = if (args.len > 0) args[0] else "all";

    std.debug.print("Enabling VRR for: {s}\n", .{display});
    std.debug.print("\nVRR control requires compositor integration.\n", .{});
    std.debug.print("\nManual enable methods:\n", .{});
    std.debug.print("\n  KDE Plasma:\n", .{});
    std.debug.print("    System Settings -> Display -> Adaptive Sync\n", .{});
    std.debug.print("\n  GNOME:\n", .{});
    std.debug.print("    gsettings set org.gnome.mutter experimental-features \"['variable-refresh-rate']\"\n", .{});
    std.debug.print("\n  Hyprland:\n", .{});
    std.debug.print("    misc:vrr = 1\n", .{});
    std.debug.print("\n  Sway:\n", .{});
    std.debug.print("    output * adaptive_sync on\n", .{});
    std.debug.print("\n  X11 (nvidia-settings):\n", .{});
    std.debug.print("    nvidia-settings --assign CurrentMetaMode=\"DP-0: nvidia-auto-select +0+0 {{AllowGSYNCCompatible=On}}\"\n", .{});
}

fn disableCommand(args: []const []const u8) !void {
    const display = if (args.len > 0) args[0] else "all";

    std.debug.print("Disabling VRR for: {s}\n", .{display});
    std.debug.print("\nVRR control requires compositor integration.\n", .{});
    std.debug.print("Reverse the enable steps for your compositor.\n", .{});
}

fn limitCommand(args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: nvsync limit <fps>\n", .{});
        std.debug.print("\nSets a frame rate limit using the NVIDIA driver.\n", .{});
        std.debug.print("\nExamples:\n", .{});
        std.debug.print("  nvsync limit 144    # Limit to 144 FPS\n", .{});
        std.debug.print("  nvsync limit 0      # Remove limit\n", .{});
        return;
    }

    const fps_str = args[0];
    const fps = std.fmt.parseInt(u32, fps_str, 10) catch {
        std.debug.print("Invalid FPS value: {s}\n", .{fps_str});
        return;
    };

    if (fps == 0) {
        std.debug.print("Removing frame rate limit...\n", .{});
    } else {
        std.debug.print("Setting frame rate limit to {d} FPS...\n", .{fps});
    }

    // Set environment variable for future processes
    std.debug.print("\nTo apply:\n", .{});
    std.debug.print("  export __GL_SYNC_TO_VBLANK=0\n", .{});
    if (fps > 0) {
        std.debug.print("  export __GL_MaxFramesAllowed={d}\n", .{fps});
    } else {
        std.debug.print("  unset __GL_MaxFramesAllowed\n", .{});
    }
    std.debug.print("\nOr use MangoHud: MANGOHUD_CONFIG=fps_limit={d}\n", .{fps});
}

fn jsonCommand(allocator: mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("{{\"error\":\"No subcommand specified\"}}\n", .{});
        return;
    }

    const subcommand = args[0];

    if (std.mem.eql(u8, subcommand, "status")) {
        const status = try nvsync.getSystemStatus(allocator);
        defer {
            if (status.driver_version) |v| allocator.free(v);
            if (status.compositor) |c| allocator.free(c);
        }

        std.debug.print(
            \\{{"version":"{d}.{d}.{d}","nvidia":{s},"driver":"{s}","displays":{d},"vrr_capable":{d},"vrr_enabled":{d},"compositor":"{s}"}}
        ++ "\n", .{
            nvsync.version.major,
            nvsync.version.minor,
            nvsync.version.patch,
            if (status.nvidia_detected) "true" else "false",
            status.driver_version orelse "unknown",
            status.display_count,
            status.vrr_capable_count,
            status.vrr_enabled_count,
            status.compositor orelse "unknown",
        });
    } else if (std.mem.eql(u8, subcommand, "displays")) {
        var manager = nvsync.DisplayManager.init(allocator);
        defer manager.deinit();

        try manager.scan();

        std.debug.print("{{\"displays\":[", .{});
        for (manager.displays.items, 0..) |display, i| {
            if (i > 0) std.debug.print(",", .{});
            std.debug.print(
                \\{{"name":"{s}","connection":"{s}","width":{d},"height":{d},"vrr_capable":{s},"vrr_enabled":{s},"mode":"{s}"}}
            , .{
                display.name,
                display.connection_type.name(),
                display.width,
                display.height,
                if (display.vrr_capable) "true" else "false",
                if (display.vrr_enabled) "true" else "false",
                display.current_mode.name(),
            });
        }
        std.debug.print("]}}\n", .{});
    } else {
        std.debug.print("{{\"error\":\"Unknown subcommand: {s}\"}}\n", .{subcommand});
    }
}

test "main compiles" {
    _ = nvsync.version;
}
