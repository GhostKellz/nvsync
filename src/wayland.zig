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

/// Hyprland VRR mode
pub const HyprlandVrrMode = enum(u8) {
    off = 0,
    on = 1,
    fullscreen_only = 2,

    pub fn toString(self: HyprlandVrrMode) []const u8 {
        return switch (self) {
            .off => "off",
            .on => "on",
            .fullscreen_only => "fullscreen only",
        };
    }
};

/// Hyprland monitor info
pub const HyprlandMonitor = struct {
    name: [64]u8,
    name_len: usize,
    description: [128]u8,
    description_len: usize,
    width: u32,
    height: u32,
    refresh_rate: f32,
    x: i32,
    y: i32,
    active_workspace_id: i32,
    vrr_enabled: bool,
    focused: bool,
    dpms_status: bool,
    transform: u8,
    scale: f32,

    pub fn getName(self: *const HyprlandMonitor) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getDescription(self: *const HyprlandMonitor) []const u8 {
        return self.description[0..self.description_len];
    }
};

/// Hyprland VRR control via hyprctl
pub const HyprlandController = struct {
    allocator: mem.Allocator,
    monitors: ?[]HyprlandMonitor,

    pub fn init(allocator: mem.Allocator) HyprlandController {
        return .{
            .allocator = allocator,
            .monitors = null,
        };
    }

    pub fn deinit(self: *HyprlandController) void {
        if (self.monitors) |m| {
            self.allocator.free(m);
            self.monitors = null;
        }
    }

    /// Enable VRR globally
    pub fn enableVrr(self: *HyprlandController, mode: HyprlandVrrMode) !void {
        _ = self;
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        var cmd_buf: [64]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "misc:vrr {d}", .{@intFromEnum(mode)}) catch return error.BufferError;

        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "hyprctl", "keyword", cmd },
        }) catch return error.CommandFailed;

        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }

    /// Set VRR mode on a specific monitor
    /// Uses hyprctl keyword to set monitor config
    pub fn setMonitorVrr(self: *HyprlandController, monitor_name: []const u8, enabled: bool) !void {
        _ = self;
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        // Hyprland monitor rule with VRR: monitor=name,res,pos,scale,vrr,vrr_value
        // We need to get current monitor config and modify it
        // For now, use a reload-style approach with keyword
        var cmd_buf: [256]u8 = undefined;
        const vrr_val: u8 = if (enabled) 1 else 0;
        const cmd = std.fmt.bufPrint(&cmd_buf, "monitor {s},preferred,auto,1,vrr,{d}", .{ monitor_name, vrr_val }) catch return error.BufferError;

        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "hyprctl", "keyword", cmd },
        }) catch return error.CommandFailed;

        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        // Check for error in output
        if (mem.indexOf(u8, result.stderr, "error") != null) {
            return error.SetVrrFailed;
        }
    }

    /// Query monitors (returns raw JSON)
    pub fn queryMonitors(self: *HyprlandController) ![]const u8 {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "hyprctl", "monitors", "-j" },
        }) catch return error.CommandFailed;

        defer self.allocator.free(result.stderr);

        return result.stdout;
    }

    /// Query VRR status (misc settings)
    pub fn queryVrrStatus(self: *HyprlandController) !HyprlandVrrMode {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "hyprctl", "getoption", "misc:vrr", "-j" },
        }) catch return error.CommandFailed;

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        // Parse JSON output to get int value
        // Output format: {"option":"misc:vrr","int":1,"float":1.0,"str":"1","set":true}
        if (mem.indexOf(u8, result.stdout, "\"int\":2")) |_| {
            return .fullscreen_only;
        } else if (mem.indexOf(u8, result.stdout, "\"int\":1")) |_| {
            return .on;
        }
        return .off;
    }

    /// Get frame timing statistics from Hyprland
    pub fn getFrameStats(self: *HyprlandController) !HyprlandFrameStats {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "hyprctl", "rollinglog", "-j" },
        }) catch return error.CommandFailed;

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        // Parse frame timing from debug log (basic implementation)
        // In a full implementation, would parse the JSON rolling log
        return HyprlandFrameStats{};
    }

    /// Dispatch a Hyprland command
    pub fn dispatch(self: *HyprlandController, command: []const u8) !void {
        _ = self;
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "hyprctl", "dispatch", command },
        }) catch return error.CommandFailed;

        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }

    /// Get active window info for VRR decisions
    pub fn getActiveWindow(self: *HyprlandController) !?HyprlandWindow {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "hyprctl", "activewindow", "-j" },
        }) catch return error.CommandFailed;

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        // Check if no window
        if (mem.indexOf(u8, result.stdout, "\"address\":\"\"") != null or result.stdout.len < 10) {
            return null;
        }

        var window = HyprlandWindow{};

        // Parse fullscreen state
        window.fullscreen = mem.indexOf(u8, result.stdout, "\"fullscreen\":1") != null or
            mem.indexOf(u8, result.stdout, "\"fullscreen\":true") != null;

        // Parse floating state
        window.floating = mem.indexOf(u8, result.stdout, "\"floating\":true") != null;

        return window;
    }

    /// Set VRR mode based on window state (smart VRR)
    pub fn smartVrr(self: *HyprlandController) !void {
        const window = try self.getActiveWindow();
        if (window) |w| {
            if (w.fullscreen) {
                // Fullscreen - enable VRR
                try self.enableVrr(.on);
            } else {
                // Not fullscreen - use fullscreen-only mode
                try self.enableVrr(.fullscreen_only);
            }
        }
    }
};

/// Hyprland frame statistics
pub const HyprlandFrameStats = struct {
    avg_frame_time_us: u64 = 0,
    max_frame_time_us: u64 = 0,
    min_frame_time_us: u64 = 0,
    dropped_frames: u32 = 0,
    vrr_active: bool = false,
};

/// Hyprland window info (minimal)
pub const HyprlandWindow = struct {
    fullscreen: bool = false,
    floating: bool = false,
    class: [128]u8 = [_]u8{0} ** 128,
    class_len: usize = 0,

    pub fn getClass(self: *const HyprlandWindow) []const u8 {
        return self.class[0..self.class_len];
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
    hyprland_ctrl: ?HyprlandController,

    pub fn init(allocator: mem.Allocator) WaylandVrrController {
        const compositor = detectCompositor();
        return .{
            .allocator = allocator,
            .compositor = compositor,
            .hyprland_ctrl = if (compositor == .hyprland) HyprlandController.init(allocator) else null,
        };
    }

    pub fn deinit(self: *WaylandVrrController) void {
        if (self.hyprland_ctrl) |*ctrl| {
            ctrl.deinit();
            self.hyprland_ctrl = null;
        }
    }

    /// Enable VRR using compositor-appropriate method
    pub fn enableVrr(self: *WaylandVrrController, output: ?[]const u8) !void {
        switch (self.compositor) {
            .kwin => {
                var ctrl = KWinController.init(self.allocator);
                try ctrl.enableVrr(output orelse "*");
            },
            .hyprland => {
                if (self.hyprland_ctrl) |*ctrl| {
                    if (output) |o| {
                        try ctrl.setMonitorVrr(o, true);
                    } else {
                        try ctrl.enableVrr(.on);
                    }
                }
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
                if (self.hyprland_ctrl) |*ctrl| {
                    if (output) |o| {
                        try ctrl.setMonitorVrr(o, false);
                    } else {
                        try ctrl.enableVrr(.off);
                    }
                }
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

    /// Set VRR to fullscreen-only mode (Hyprland specific)
    pub fn setFullscreenOnly(self: *WaylandVrrController) !void {
        if (self.compositor == .hyprland) {
            if (self.hyprland_ctrl) |*ctrl| {
                try ctrl.enableVrr(.fullscreen_only);
            }
        } else {
            // For other compositors, just enable VRR (they handle fullscreen internally)
            try self.enableVrr(null);
        }
    }

    /// Get VRR setup instructions for current compositor
    pub fn getInstructions(self: *WaylandVrrController) []const u8 {
        return self.compositor.vrrInstructions();
    }

    /// Get Hyprland-specific controller (if running under Hyprland)
    pub fn getHyprlandController(self: *WaylandVrrController) ?*HyprlandController {
        if (self.hyprland_ctrl) |*ctrl| {
            return ctrl;
        }
        return null;
    }
};

test "detectCompositor basic" {
    const compositor = detectCompositor();
    // Just ensure it doesn't crash
    _ = compositor.name();
    _ = compositor.supportsVrr();
}
