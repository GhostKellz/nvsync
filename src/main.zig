//! nvsync CLI - VRR/G-Sync Management for Linux
//!
//! Command-line interface for VRR and G-Sync control.

const std = @import("std");
const nvsync = @import("nvsync");
const posix = std.posix;
const fs = std.fs;
const mem = std.mem;
const process = std.process;

/// Sleep for a given number of nanoseconds
fn sleepNs(ns: u64) void {
    const ts = std.c.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&ts, null);
}

pub fn main(init: process.Init.Minimal) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Collect args into an ArrayList
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(allocator);

    var args_iter = process.Args.Iterator.init(init.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

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
        try enableCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "disable")) {
        try disableCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "limit")) {
        try limitCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "json")) {
        try jsonCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "profile")) {
        try profileCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "daemon")) {
        try daemonCommand(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "monitor")) {
        try monitorCommand(allocator);
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
        \\    profile <action>    Manage game profiles (list, set, get, remove)
        \\    daemon <action>     Auto-switching daemon (start, stop, status)
        \\    monitor             Real-time VRR status monitor
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

fn enableCommand(allocator: mem.Allocator, args: []const []const u8) !void {
    const display: ?[]const u8 = if (args.len > 0) args[0] else null;
    const display_str = display orelse "all displays";

    std.debug.print("Enabling VRR for: {s}\n", .{display_str});

    var ctrl = nvsync.VrrController.init(allocator);
    defer ctrl.deinit();

    ctrl.enable(display) catch |err| {
        std.debug.print("\nAutomatic VRR control failed: {}\n", .{err});
        std.debug.print("\nManual enable methods:\n", .{});
        std.debug.print("{s}\n", .{ctrl.getInstructions()});

        // Also show compositor-specific instructions
        if (nvsync.wayland.isWayland()) {
            const compositor = nvsync.wayland.detectCompositor();
            std.debug.print("\nDetected compositor: {s}\n", .{compositor.name()});
            std.debug.print("{s}\n", .{compositor.vrrInstructions()});
        } else {
            std.debug.print("\n  X11 (nvidia-settings):\n", .{});
            std.debug.print("    nvidia-settings --assign CurrentMetaMode=\"DP-0: nvidia-auto-select +0+0 {{AllowGSYNCCompatible=On}}\"\n", .{});
        }
        return;
    };

    std.debug.print("[OK] VRR enabled successfully for: {s}\n", .{display_str});

    // Verify the change
    const status = nvsync.getSystemStatus(allocator) catch return;
    defer {
        if (status.driver_version) |v| allocator.free(v);
        if (status.compositor) |c| allocator.free(c);
    }
    std.debug.print("VRR now active on {d} display(s)\n", .{status.vrr_enabled_count});
}

fn disableCommand(allocator: mem.Allocator, args: []const []const u8) !void {
    const display: ?[]const u8 = if (args.len > 0) args[0] else null;
    const display_str = display orelse "all displays";

    std.debug.print("Disabling VRR for: {s}\n", .{display_str});

    var ctrl = nvsync.VrrController.init(allocator);
    defer ctrl.deinit();

    ctrl.disable(display) catch |err| {
        std.debug.print("\nAutomatic VRR control failed: {}\n", .{err});
        std.debug.print("\nManual disable: Reverse the enable steps for your compositor.\n", .{});

        if (nvsync.wayland.isWayland()) {
            const compositor = nvsync.wayland.detectCompositor();
            std.debug.print("\nDetected compositor: {s}\n", .{compositor.name()});
            switch (compositor) {
                .kwin => std.debug.print("  kscreen-doctor output.DP-1.vrr.0\n", .{}),
                .hyprland => std.debug.print("  hyprctl keyword misc:vrr 0\n", .{}),
                .sway => std.debug.print("  swaymsg output * adaptive_sync off\n", .{}),
                .mutter => std.debug.print("  gsettings set org.gnome.mutter experimental-features \"[]\"\n", .{}),
                else => {},
            }
        } else {
            std.debug.print("\n  X11: nvidia-settings --assign CurrentMetaMode=\"DP-0: nvidia-auto-select +0+0\"\n", .{});
        }
        return;
    };

    std.debug.print("[OK] VRR disabled successfully for: {s}\n", .{display_str});
}

fn limitCommand(allocator: mem.Allocator, args: []const []const u8) !void {
    _ = allocator;

    if (args.len == 0) {
        std.debug.print("Usage: nvsync limit <fps>\n", .{});
        std.debug.print("\nSets a frame rate limit using the NVIDIA driver.\n", .{});
        std.debug.print("\nExamples:\n", .{});
        std.debug.print("  nvsync limit 144    # Limit to 144 FPS\n", .{});
        std.debug.print("  nvsync limit 0      # Remove limit\n", .{});
        std.debug.print("\nModes:\n", .{});
        std.debug.print("  GPU mode (default): Uses NVIDIA driver's native limiter (lowest latency)\n", .{});
        std.debug.print("  CPU mode: Uses CPU timing (fallback)\n", .{});
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
        const frame_time_ms = @as(f32, 1000.0) / @as(f32, @floatFromInt(fps));
        std.debug.print("Target frame time: {d:.2}ms\n", .{frame_time_ms});
    }

    // Try nvidia-settings first (X11)
    nvsync.nvidia.setFrameLimit(fps) catch {};

    // Print environment variables for GPU-level limiting
    std.debug.print("\nGPU-level frame limiting (apply before launching game):\n", .{});
    std.debug.print("  export __GL_SYNC_TO_VBLANK=0\n", .{});
    if (fps > 0) {
        std.debug.print("  export __GL_MaxFramesAllowed={d}\n", .{fps});
    } else {
        std.debug.print("  unset __GL_MaxFramesAllowed\n", .{});
    }

    // Alternative methods
    std.debug.print("\nAlternative methods:\n", .{});
    std.debug.print("  MangoHud: MANGOHUD_CONFIG=fps_limit={d} game\n", .{fps});
    std.debug.print("  Gamescope: gamescope -r {d} -- game\n", .{fps});
    if (nvsync.wayland.isWayland()) {
        const compositor = nvsync.wayland.detectCompositor();
        if (compositor == .hyprland) {
            std.debug.print("  Hyprland: misc:render_ahead_of_time = false\n", .{});
        }
    }
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

fn profileCommand(allocator: mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: nvsync profile <action> [options]\n", .{});
        std.debug.print("\nActions:\n", .{});
        std.debug.print("  list                  List all game profiles\n", .{});
        std.debug.print("  get <executable>      Show profile for a game\n", .{});
        std.debug.print("  set <executable>      Create/update a profile\n", .{});
        std.debug.print("      --name <name>     Game name\n", .{});
        std.debug.print("      --fps <fps>       Frame limit (0 = unlimited)\n", .{});
        std.debug.print("      --vrr <mode>      VRR mode: off, gsync, gsync_compatible, vrr\n", .{});
        std.debug.print("  remove <executable>   Remove a profile\n", .{});
        std.debug.print("\nExamples:\n", .{});
        std.debug.print("  nvsync profile list\n", .{});
        std.debug.print("  nvsync profile set game.exe --name \"My Game\" --fps 144\n", .{});
        std.debug.print("  nvsync profile get game.exe\n", .{});
        return;
    }

    const action = args[0];

    var manager = nvsync.profiles.ProfileManager.init(allocator);
    defer manager.deinit();

    // Try to load existing profiles
    manager.load() catch {};

    if (std.mem.eql(u8, action, "list")) {
        std.debug.print("Game Profiles\n", .{});
        std.debug.print("=============\n\n", .{});

        if (manager.count() == 0) {
            std.debug.print("No profiles configured.\n", .{});
            std.debug.print("Use 'nvsync profile set <executable>' to create one.\n", .{});
            return;
        }

        var iter = manager.list();
        var idx: usize = 1;
        while (iter.next()) |entry| {
            const profile = entry.value_ptr.*;
            std.debug.print("{d}. {s}\n", .{ idx, profile.name });
            std.debug.print("   Executable: {s}\n", .{profile.executable});
            std.debug.print("   VRR Mode:   {s}\n", .{profile.vrr_mode.name()});
            std.debug.print("   FPS Limit:  {s}\n", .{if (profile.frame_limit == 0) "Unlimited" else "set"});
            if (profile.frame_limit > 0) {
                std.debug.print("               {d} FPS\n", .{profile.frame_limit});
            }
            if (profile.notes.len > 0) {
                std.debug.print("   Notes:      {s}\n", .{profile.notes});
            }
            std.debug.print("\n", .{});
            idx += 1;
        }
    } else if (std.mem.eql(u8, action, "get")) {
        if (args.len < 2) {
            std.debug.print("Usage: nvsync profile get <executable>\n", .{});
            return;
        }

        const executable = args[1];
        if (manager.getForProcess(executable)) |profile| {
            std.debug.print("Profile: {s}\n", .{profile.name});
            std.debug.print("  Executable:  {s}\n", .{profile.executable});
            std.debug.print("  VRR Mode:    {s}\n", .{profile.vrr_mode.name()});
            std.debug.print("  FPS Limit:   {d}\n", .{profile.frame_limit});
            std.debug.print("  Force G-Sync:{s}\n", .{if (profile.force_gsync) " Yes" else " No"});
            std.debug.print("  LFC Enabled: {s}\n", .{if (profile.lfc_enabled) " Yes" else " No"});
            if (profile.notes.len > 0) {
                std.debug.print("  Notes:       {s}\n", .{profile.notes});
            }
        } else {
            std.debug.print("No profile found for: {s}\n", .{executable});
        }
    } else if (std.mem.eql(u8, action, "set")) {
        if (args.len < 2) {
            std.debug.print("Usage: nvsync profile set <executable> [options]\n", .{});
            return;
        }

        const executable = args[1];

        // Parse options
        var name: []const u8 = executable;
        var fps_limit: u32 = 0;
        var vrr_mode: nvsync.VrrMode = .gsync_compatible;

        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--name") and i + 1 < args.len) {
                i += 1;
                name = args[i];
            } else if (std.mem.eql(u8, arg, "--fps") and i + 1 < args.len) {
                i += 1;
                fps_limit = std.fmt.parseInt(u32, args[i], 10) catch 0;
            } else if (std.mem.eql(u8, arg, "--vrr") and i + 1 < args.len) {
                i += 1;
                const mode = args[i];
                if (std.mem.eql(u8, mode, "off")) {
                    vrr_mode = .off;
                } else if (std.mem.eql(u8, mode, "gsync")) {
                    vrr_mode = .gsync;
                } else if (std.mem.eql(u8, mode, "vrr")) {
                    vrr_mode = .vrr;
                } else {
                    vrr_mode = .gsync_compatible;
                }
            }
        }

        const profile = nvsync.profiles.GameProfile{
            .name = allocator.dupe(u8, name) catch return,
            .executable = allocator.dupe(u8, executable) catch return,
            .vrr_mode = vrr_mode,
            .frame_limit = fps_limit,
            .force_gsync = false,
            .lfc_enabled = true,
            .notes = allocator.dupe(u8, "") catch return,
        };

        manager.set(profile) catch |err| {
            std.debug.print("Failed to set profile: {}\n", .{err});
            return;
        };

        manager.save() catch |err| {
            std.debug.print("Failed to save profiles: {}\n", .{err});
            return;
        };

        std.debug.print("[OK] Profile saved for: {s}\n", .{name});
        std.debug.print("     Executable: {s}\n", .{executable});
        std.debug.print("     VRR Mode:   {s}\n", .{vrr_mode.name()});
        std.debug.print("     FPS Limit:  {d}\n", .{fps_limit});
    } else if (std.mem.eql(u8, action, "remove")) {
        if (args.len < 2) {
            std.debug.print("Usage: nvsync profile remove <executable>\n", .{});
            return;
        }

        const executable = args[1];
        if (manager.remove(executable)) {
            manager.save() catch |err| {
                std.debug.print("Failed to save profiles: {}\n", .{err});
                return;
            };
            std.debug.print("[OK] Profile removed: {s}\n", .{executable});
        } else {
            std.debug.print("No profile found for: {s}\n", .{executable});
        }
    } else {
        std.debug.print("Unknown action: {s}\n", .{action});
        std.debug.print("Use 'nvsync profile' to see available actions.\n", .{});
    }
}

fn daemonCommand(allocator: mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print(
            \\nvsync daemon - Profile Auto-Switching
            \\
            \\USAGE:
            \\    nvsync daemon <action>
            \\
            \\ACTIONS:
            \\    start       Start the daemon (foreground)
            \\    status      Show daemon status
            \\    check       Check once for matching profiles
            \\
            \\DESCRIPTION:
            \\    The daemon monitors running processes and automatically
            \\    applies VRR/frame limit profiles when games are detected.
            \\
            \\EXAMPLES:
            \\    nvsync daemon start    # Run in foreground
            \\    nvsync daemon status   # Check if profiles loaded
            \\
        , .{});
        return;
    }

    const action = args[0];

    if (std.mem.eql(u8, action, "start")) {
        std.debug.print("nvsync Auto-Switching Daemon\n", .{});
        std.debug.print("============================\n\n", .{});

        // Load and show profiles
        var pm = nvsync.profiles.ProfileManager.init(allocator);
        defer pm.deinit();
        pm.load() catch {
            std.debug.print("[WARN] No profiles loaded\n", .{});
        };

        std.debug.print("Loaded {d} profile(s)\n", .{pm.count()});
        std.debug.print("Polling interval: 2000ms\n", .{});
        std.debug.print("\nPress Ctrl+C to stop.\n\n", .{});

        // Start the daemon
        nvsync.daemon.runDaemonized(allocator) catch |err| {
            std.debug.print("Daemon error: {}\n", .{err});
        };
    } else if (std.mem.eql(u8, action, "status")) {
        var pm = nvsync.profiles.ProfileManager.init(allocator);
        defer pm.deinit();
        pm.load() catch {};

        std.debug.print("Daemon Status\n", .{});
        std.debug.print("=============\n\n", .{});
        std.debug.print("Profiles loaded: {d}\n", .{pm.count()});
        std.debug.print("Config path: ~/.config/nvsync/profiles.json\n", .{});

        // List profiles
        if (pm.count() > 0) {
            std.debug.print("\nConfigured profiles:\n", .{});
            var iter = pm.list();
            while (iter.next()) |entry| {
                const p = entry.value_ptr.*;
                std.debug.print("  - {s} ({s})\n", .{ p.name, p.executable });
            }
        }
    } else if (std.mem.eql(u8, action, "check")) {
        // One-shot check for a specific executable
        if (args.len < 2) {
            std.debug.print("Usage: nvsync daemon check <executable>\n", .{});
            return;
        }

        const exe = args[1];
        const result = nvsync.daemon.checkOnce(allocator, exe) catch {
            std.debug.print("Error checking profile\n", .{});
            return;
        };
        if (result) |profile| {
            std.debug.print("Profile found: {s}\n", .{profile.name});
            std.debug.print("  VRR Mode:   {s}\n", .{profile.vrr_mode.name()});
            std.debug.print("  FPS Limit:  {d}\n", .{profile.frame_limit});
        } else {
            std.debug.print("No profile found for: {s}\n", .{exe});
        }
    } else {
        std.debug.print("Unknown action: {s}\n", .{action});
    }
}

fn monitorCommand(allocator: mem.Allocator) !void {
    std.debug.print("nvsync Real-Time VRR Monitor\n", .{});
    std.debug.print("============================\n", .{});
    std.debug.print("Press Ctrl+C to exit.\n\n", .{});

    var manager = nvsync.DisplayManager.init(allocator);
    defer manager.deinit();

    // Main monitoring loop
    var iteration: u32 = 0;
    while (true) : (iteration += 1) {
        // Clear screen (ANSI escape)
        std.debug.print("\x1b[2J\x1b[H", .{});

        std.debug.print("nvsync VRR Monitor - Update #{d}\n", .{iteration});
        std.debug.print("================================\n\n", .{});

        // Rescan displays
        manager.displays.clearRetainingCapacity();
        manager.scan() catch |err| {
            std.debug.print("Scan error: {}\n", .{err});
            sleepNs(1 * std.time.ns_per_s);
            continue;
        };

        // Show NVIDIA status
        if (manager.nvidia_detected) {
            std.debug.print("GPU: NVIDIA (Driver: {s})\n", .{manager.driver_version orelse "unknown"});
        } else {
            std.debug.print("GPU: Non-NVIDIA or not detected\n", .{});
        }

        // Show compositor
        if (manager.compositor) |comp| {
            std.debug.print("Compositor: {s}\n", .{comp.name()});
        }

        std.debug.print("\n", .{});

        // Show each display
        for (manager.displays.items, 0..) |display, i| {
            std.debug.print("Display {d}: {s}\n", .{ i + 1, display.name });
            std.debug.print("  Resolution:  {d}x{d} @ {d}Hz\n", .{
                display.width,
                display.height,
                display.current_hz,
            });
            std.debug.print("  VRR Range:   {d}-{d}Hz\n", .{ display.min_hz, display.max_hz });

            // VRR Status with color
            if (display.vrr_enabled) {
                std.debug.print("  VRR Status:  \x1b[32m● ENABLED\x1b[0m ({s})\n", .{display.current_mode.name()});
            } else if (display.vrr_capable or display.gsync_compatible) {
                std.debug.print("  VRR Status:  \x1b[33m○ CAPABLE\x1b[0m (not active)\n", .{});
            } else {
                std.debug.print("  VRR Status:  \x1b[31m✗ NOT SUPPORTED\x1b[0m\n", .{});
            }

            // LFC status
            if (display.lfc_supported) {
                std.debug.print("  LFC:         Supported (effective min: {d}Hz)\n", .{display.min_hz / 2});
            }

            std.debug.print("\n", .{});
        }

        // Summary
        var vrr_enabled_count: usize = 0;
        var vrr_capable_count: usize = 0;
        for (manager.displays.items) |d| {
            if (d.vrr_enabled) vrr_enabled_count += 1;
            if (d.vrr_capable or d.gsync_compatible) vrr_capable_count += 1;
        }

        std.debug.print("Summary: {d}/{d} displays with VRR enabled\n", .{
            vrr_enabled_count,
            vrr_capable_count,
        });
        std.debug.print("\nRefreshing every 2 seconds... (Ctrl+C to exit)\n", .{});

        // Wait before next update
        sleepNs(2 * std.time.ns_per_s);
    }
}

test "main compiles" {
    _ = nvsync.version;
}
