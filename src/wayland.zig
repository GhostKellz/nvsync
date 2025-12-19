//! Wayland VRR Control
//!
//! Controls VRR via Wayland compositor protocols.
//! Supports KWin, Mutter, Hyprland, and wlroots-based compositors.

const std = @import("std");
const posix = std.posix;
const fs = std.fs;
const mem = std.mem;

/// Wayland compositor type
pub const CompositorType = enum {
    kwin, // KDE Plasma
    mutter, // GNOME
    hyprland,
    sway,
    wlroots_other, // Other wlroots-based
    unknown,

    pub fn name(self: CompositorType) []const u8 {
        return switch (self) {
            .kwin => "KWin (KDE Plasma)",
            .mutter => "Mutter (GNOME)",
            .hyprland => "Hyprland",
            .sway => "Sway",
            .wlroots_other => "wlroots-based",
            .unknown => "Unknown",
        };
    }

    pub fn supportsVrr(self: CompositorType) bool {
        return switch (self) {
            .kwin, .hyprland, .sway, .wlroots_other => true,
            .mutter => true, // GNOME 46+
            .unknown => false,
        };
    }

    pub fn vrrInstructions(self: CompositorType) []const u8 {
        return switch (self) {
            .kwin =>
            \\KDE Plasma VRR Setup:
            \\  1. System Settings -> Display and Monitor -> Display Configuration
            \\  2. Select your monitor
            \\  3. Enable "Adaptive Sync" / "Variable Refresh Rate"
            \\  4. Apply changes
            \\
            \\Or via kscreen-doctor:
            \\  kscreen-doctor output.DP-1.vrr.1
            ,
            .mutter =>
            \\GNOME Mutter VRR Setup (GNOME 46+):
            \\  gsettings set org.gnome.mutter experimental-features "['variable-refresh-rate']"
            \\
            \\Then enable in Settings -> Displays -> Variable Refresh Rate
            ,
            .hyprland =>
            \\Hyprland VRR Setup:
            \\Add to ~/.config/hypr/hyprland.conf:
            \\
            \\  misc {
            \\      vrr = 1  # 0=off, 1=on, 2=fullscreen only
            \\  }
            \\
            \\Or per-monitor:
            \\  monitor=DP-1,preferred,auto,1,vrr,1
            ,
            .sway =>
            \\Sway VRR Setup:
            \\Add to ~/.config/sway/config:
            \\
            \\  output * adaptive_sync on
            \\
            \\Or per-monitor:
            \\  output DP-1 adaptive_sync on
            ,
            .wlroots_other =>
            \\wlroots-based compositor VRR:
            \\Check your compositor's documentation for adaptive_sync or VRR settings.
            \\Most support output configuration via config file.
            ,
            .unknown => "Unknown compositor. Check your compositor's documentation for VRR support.",
        };
    }
};

/// Detect current Wayland compositor
pub fn detectCompositor() CompositorType {
    // Check environment variables
    if (posix.getenv("HYPRLAND_INSTANCE_SIGNATURE") != null) {
        return .hyprland;
    }

    if (posix.getenv("SWAYSOCK") != null) {
        return .sway;
    }

    if (posix.getenv("XDG_CURRENT_DESKTOP")) |desktop| {
        if (mem.indexOf(u8, desktop, "KDE") != null) {
            return .kwin;
        }
        if (mem.indexOf(u8, desktop, "GNOME") != null) {
            return .mutter;
        }
        if (mem.indexOf(u8, desktop, "Hyprland") != null) {
            return .hyprland;
        }
        if (mem.indexOf(u8, desktop, "sway") != null) {
            return .sway;
        }
    }

    // Check for WAYLAND_DISPLAY
    if (posix.getenv("WAYLAND_DISPLAY") != null) {
        return .wlroots_other;
    }

    return .unknown;
}

/// Check if running under Wayland
pub fn isWayland() bool {
    return posix.getenv("WAYLAND_DISPLAY") != null;
}

/// KWin VRR control via D-Bus
pub const KWinController = struct {
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator) KWinController {
        return .{ .allocator = allocator };
    }

    /// Enable VRR on a specific output
    pub fn enableVrr(self: *KWinController, output: []const u8) !void {
        _ = self;
        // Use kscreen-doctor to enable VRR
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        var cmd_buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "output.{s}.vrr.1", .{output}) catch return error.BufferError;

        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "kscreen-doctor", cmd },
        }) catch return error.CommandFailed;

        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            return error.SetVrrFailed;
        }
    }

    /// Disable VRR on a specific output
    pub fn disableVrr(self: *KWinController, output: []const u8) !void {
        _ = self;
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        var cmd_buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "output.{s}.vrr.0", .{output}) catch return error.BufferError;

        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "kscreen-doctor", cmd },
        }) catch return error.CommandFailed;

        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }

    /// Query current VRR status
    pub fn queryVrrStatus(self: *KWinController) ![]const u8 {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "kscreen-doctor", "-o" },
        }) catch return error.CommandFailed;

        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            self.allocator.free(result.stdout);
            return error.QueryFailed;
        }

        return result.stdout;
    }
};

/// Hyprland VRR control via hyprctl
pub const HyprlandController = struct {
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator) HyprlandController {
        return .{ .allocator = allocator };
    }

    /// Enable VRR globally
    pub fn enableVrr(self: *HyprlandController, mode: u8) !void {
        _ = self;
        // mode: 0=off, 1=on, 2=fullscreen only
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        var cmd_buf: [64]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "misc:vrr {d}", .{mode}) catch return error.BufferError;

        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "hyprctl", "keyword", cmd },
        }) catch return error.CommandFailed;

        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }

    /// Query monitors
    pub fn queryMonitors(self: *HyprlandController) ![]const u8 {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "hyprctl", "monitors", "-j" },
        }) catch return error.CommandFailed;

        defer self.allocator.free(result.stderr);

        return result.stdout;
    }
};

/// Sway VRR control via swaymsg
pub const SwayController = struct {
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator) SwayController {
        return .{ .allocator = allocator };
    }

    /// Enable adaptive sync on output
    pub fn enableAdaptiveSync(self: *SwayController, output: []const u8) !void {
        _ = self;
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        var cmd_buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "output {s} adaptive_sync on", .{output}) catch return error.BufferError;

        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "swaymsg", cmd },
        }) catch return error.CommandFailed;

        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }

    /// Disable adaptive sync on output
    pub fn disableAdaptiveSync(self: *SwayController, output: []const u8) !void {
        _ = self;
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        var cmd_buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "output {s} adaptive_sync off", .{output}) catch return error.BufferError;

        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "swaymsg", cmd },
        }) catch return error.CommandFailed;

        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }

    /// Query outputs
    pub fn queryOutputs(self: *SwayController) ![]const u8 {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "swaymsg", "-t", "get_outputs" },
        }) catch return error.CommandFailed;

        defer self.allocator.free(result.stderr);

        return result.stdout;
    }
};

/// Mutter/GNOME VRR control via gsettings
pub const MutterController = struct {
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator) MutterController {
        return .{ .allocator = allocator };
    }

    /// Enable VRR experimental feature
    pub fn enableVrr(self: *MutterController) !void {
        _ = self;
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{
                "gsettings",
                "set",
                "org.gnome.mutter",
                "experimental-features",
                "['variable-refresh-rate']",
            },
        }) catch return error.CommandFailed;

        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            return error.SetVrrFailed;
        }
    }

    /// Disable VRR experimental feature
    pub fn disableVrr(self: *MutterController) !void {
        _ = self;
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{
                "gsettings",
                "set",
                "org.gnome.mutter",
                "experimental-features",
                "[]",
            },
        }) catch return error.CommandFailed;

        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }

    /// Check if VRR is enabled
    pub fn isVrrEnabled(self: *MutterController) !bool {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{
                "gsettings",
                "get",
                "org.gnome.mutter",
                "experimental-features",
            },
        }) catch return false;

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return mem.indexOf(u8, result.stdout, "variable-refresh-rate") != null;
    }
};

/// Unified Wayland VRR controller
pub const WaylandVrrController = struct {
    allocator: mem.Allocator,
    compositor: CompositorType,

    pub fn init(allocator: mem.Allocator) WaylandVrrController {
        return .{
            .allocator = allocator,
            .compositor = detectCompositor(),
        };
    }

    /// Enable VRR using compositor-appropriate method
    pub fn enableVrr(self: *WaylandVrrController, output: ?[]const u8) !void {
        switch (self.compositor) {
            .kwin => {
                var ctrl = KWinController.init(self.allocator);
                try ctrl.enableVrr(output orelse "*");
            },
            .hyprland => {
                var ctrl = HyprlandController.init(self.allocator);
                try ctrl.enableVrr(1); // 1 = always on
            },
            .sway, .wlroots_other => {
                var ctrl = SwayController.init(self.allocator);
                try ctrl.enableAdaptiveSync(output orelse "*");
            },
            .mutter => {
                var ctrl = MutterController.init(self.allocator);
                try ctrl.enableVrr();
            },
            .unknown => {
                return error.UnsupportedCompositor;
            },
        }
    }

    /// Disable VRR
    pub fn disableVrr(self: *WaylandVrrController, output: ?[]const u8) !void {
        switch (self.compositor) {
            .kwin => {
                var ctrl = KWinController.init(self.allocator);
                try ctrl.disableVrr(output orelse "*");
            },
            .hyprland => {
                var ctrl = HyprlandController.init(self.allocator);
                try ctrl.enableVrr(0); // 0 = off
            },
            .sway, .wlroots_other => {
                var ctrl = SwayController.init(self.allocator);
                try ctrl.disableAdaptiveSync(output orelse "*");
            },
            .mutter => {
                var ctrl = MutterController.init(self.allocator);
                try ctrl.disableVrr();
            },
            .unknown => {
                return error.UnsupportedCompositor;
            },
        }
    }

    /// Get VRR setup instructions for current compositor
    pub fn getInstructions(self: *WaylandVrrController) []const u8 {
        return self.compositor.vrrInstructions();
    }
};

test "detectCompositor basic" {
    const compositor = detectCompositor();
    // Just ensure it doesn't crash
    _ = compositor.name();
    _ = compositor.supportsVrr();
}
