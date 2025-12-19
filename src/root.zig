//! nvsync - VRR/G-Sync Management for Linux
//!
//! Unified variable refresh rate control for NVIDIA GPUs on Linux.
//! Supports G-Sync, G-Sync Compatible, and VRR modes.
//!
//! Backends:
//! - DRM/KMS for direct kernel mode setting
//! - nvidia-settings/NV-CONTROL for X11
//! - Wayland compositor protocols (KWin, Mutter, Hyprland, Sway)

const std = @import("std");
const posix = std.posix;
const fs = std.fs;
const mem = std.mem;

// Sub-modules
pub const drm = @import("drm.zig");
pub const nvidia = @import("nvidia.zig");
pub const wayland = @import("wayland.zig");

/// Library version
pub const version = std.SemanticVersion{
    .major = 0,
    .minor = 2,
    .patch = 0,
};

/// VRR Mode
pub const VrrMode = enum {
    /// VRR disabled
    off,
    /// G-Sync enabled (native G-Sync module)
    gsync,
    /// G-Sync Compatible (adaptive sync)
    gsync_compatible,
    /// Generic VRR (HDMI 2.1)
    vrr,
    /// Unknown/unsupported
    unknown,

    pub fn name(self: VrrMode) []const u8 {
        return switch (self) {
            .off => "Off",
            .gsync => "G-Sync",
            .gsync_compatible => "G-Sync Compatible",
            .vrr => "VRR",
            .unknown => "Unknown",
        };
    }
};

/// Display connection type
pub const ConnectionType = enum {
    displayport,
    hdmi,
    dvi,
    vga,
    internal,
    unknown,

    pub fn name(self: ConnectionType) []const u8 {
        return switch (self) {
            .displayport => "DisplayPort",
            .hdmi => "HDMI",
            .dvi => "DVI",
            .vga => "VGA",
            .internal => "Internal",
            .unknown => "Unknown",
        };
    }

    /// Check if connection type supports VRR
    pub fn supportsVrr(self: ConnectionType) bool {
        return switch (self) {
            .displayport, .hdmi => true,
            .dvi, .vga, .internal, .unknown => false,
        };
    }
};

/// Display information
pub const Display = struct {
    allocator: mem.Allocator,
    name: []const u8,
    connector: []const u8,
    connection_type: ConnectionType,

    // Refresh rate info
    current_hz: u32,
    min_hz: u32,
    max_hz: u32,

    // VRR capabilities
    vrr_capable: bool,
    gsync_capable: bool,
    gsync_compatible: bool,
    lfc_supported: bool, // Low Framerate Compensation

    // Current state
    vrr_enabled: bool,
    current_mode: VrrMode,

    // Resolution
    width: u32,
    height: u32,

    pub fn deinit(self: *Display) void {
        self.allocator.free(self.name);
        self.allocator.free(self.connector);
    }

    /// Check if LFC is active (framerate < VRR min triggers frame doubling)
    pub fn isLfcActive(self: *const Display, current_fps: u32) bool {
        return self.lfc_supported and current_fps < self.min_hz;
    }

    /// Get effective VRR range description
    pub fn vrrRangeString(self: *const Display) []const u8 {
        var buf: [64]u8 = undefined;
        if (self.lfc_supported) {
            return std.fmt.bufPrint(&buf, "{d}-{d}Hz (LFC: {d}Hz effective min)", .{
                self.min_hz,
                self.max_hz,
                self.min_hz / 2,
            }) catch "unknown";
        }
        return std.fmt.bufPrint(&buf, "{d}-{d}Hz", .{ self.min_hz, self.max_hz }) catch "unknown";
    }
};

/// Display manager for detecting and controlling displays
pub const DisplayManager = struct {
    allocator: mem.Allocator,
    displays: std.ArrayListUnmanaged(Display),
    nvidia_detected: bool,
    driver_version: ?[]const u8,
    compositor: ?wayland.CompositorType,

    pub fn init(allocator: mem.Allocator) DisplayManager {
        return .{
            .allocator = allocator,
            .displays = .empty,
            .nvidia_detected = false,
            .driver_version = null,
            .compositor = null,
        };
    }

    pub fn deinit(self: *DisplayManager) void {
        for (self.displays.items) |*d| {
            d.deinit();
        }
        self.displays.deinit(self.allocator);
        if (self.driver_version) |v| {
            self.allocator.free(v);
        }
    }

    /// Scan for displays via DRM
    pub fn scan(self: *DisplayManager) !void {
        // Check for NVIDIA GPU
        self.nvidia_detected = isNvidiaGpu();

        if (self.nvidia_detected) {
            self.driver_version = getNvidiaDriverVersion(self.allocator);
        }

        // Detect compositor
        if (wayland.isWayland()) {
            self.compositor = wayland.detectCompositor();
        }

        // Scan DRM devices
        try self.scanDrmDevices();
    }

    fn scanDrmDevices(self: *DisplayManager) !void {
        var dir = fs.cwd().openDir("/sys/class/drm", .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (!mem.startsWith(u8, entry.name, "card")) continue;
            if (mem.indexOf(u8, entry.name, "-") == null) continue;

            var path_buf: [256]u8 = undefined;
            const status_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/status", .{entry.name}) catch continue;

            const file = fs.cwd().openFile(status_path, .{}) catch continue;
            defer file.close();

            var status_buf: [64]u8 = undefined;
            const status_len = file.read(&status_buf) catch continue;
            const status = status_buf[0..status_len];

            const trimmed = mem.trim(u8, status, &[_]u8{ '\n', '\r', ' ' });
            if (!mem.eql(u8, trimmed, "connected")) continue;

            var display = Display{
                .allocator = self.allocator,
                .name = self.allocator.dupe(u8, entry.name) catch continue,
                .connector = self.allocator.dupe(u8, entry.name) catch continue,
                .connection_type = self.parseConnectionType(entry.name),
                .current_hz = 60,
                .min_hz = 48,
                .max_hz = 144,
                .vrr_capable = false,
                .gsync_capable = false,
                .gsync_compatible = false,
                .lfc_supported = false,
                .vrr_enabled = false,
                .current_mode = .off,
                .width = 1920,
                .height = 1080,
            };

            // Read VRR capable
            const vrr_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/vrr_capable", .{entry.name}) catch "";
            if (vrr_path.len > 0) {
                const vrr_file = fs.cwd().openFile(vrr_path, .{}) catch null;
                if (vrr_file) |f| {
                    defer f.close();
                    var vrr_buf: [8]u8 = undefined;
                    const vrr_len = f.read(&vrr_buf) catch 0;
                    if (vrr_len > 0) {
                        const vrr_trimmed = mem.trim(u8, vrr_buf[0..vrr_len], &[_]u8{ '\n', '\r', ' ' });
                        display.vrr_capable = mem.eql(u8, vrr_trimmed, "1");
                        display.gsync_compatible = display.vrr_capable;
                        // LFC typically supported if VRR range is >= 2.4x
                        display.lfc_supported = display.vrr_capable;
                    }
                }
            }

            // Check VRR enabled state
            const enabled_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/vrr_enabled", .{entry.name}) catch "";
            if (enabled_path.len > 0) {
                const en_file = fs.cwd().openFile(enabled_path, .{}) catch null;
                if (en_file) |f| {
                    defer f.close();
                    var en_buf: [8]u8 = undefined;
                    const en_len = f.read(&en_buf) catch 0;
                    if (en_len > 0) {
                        const en_trimmed = mem.trim(u8, en_buf[0..en_len], &[_]u8{ '\n', '\r', ' ' });
                        display.vrr_enabled = mem.eql(u8, en_trimmed, "1");
                        if (display.vrr_enabled) {
                            display.current_mode = if (display.gsync_capable) .gsync else .gsync_compatible;
                        }
                    }
                }
            }

            // Parse resolution from modes
            try self.parseDisplayMode(&display, entry.name);

            self.displays.append(self.allocator, display) catch continue;
        }
    }

    fn parseConnectionType(self: *DisplayManager, name_str: []const u8) ConnectionType {
        _ = self;
        if (mem.indexOf(u8, name_str, "DP") != null or mem.indexOf(u8, name_str, "DisplayPort") != null) {
            return .displayport;
        } else if (mem.indexOf(u8, name_str, "HDMI") != null) {
            return .hdmi;
        } else if (mem.indexOf(u8, name_str, "DVI") != null) {
            return .dvi;
        } else if (mem.indexOf(u8, name_str, "VGA") != null) {
            return .vga;
        } else if (mem.indexOf(u8, name_str, "eDP") != null) {
            return .internal;
        }
        return .unknown;
    }

    fn parseDisplayMode(_: *DisplayManager, display: *Display, connector: []const u8) !void {
        var path_buf: [256]u8 = undefined;
        const modes_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/modes", .{connector}) catch return;

        const file = fs.cwd().openFile(modes_path, .{}) catch return;
        defer file.close();

        var modes_buf: [1024]u8 = undefined;
        const modes_len = file.read(&modes_buf) catch return;
        const modes = modes_buf[0..modes_len];

        var lines = mem.splitSequence(u8, modes, "\n");
        if (lines.next()) |first_mode| {
            var parts = mem.splitSequence(u8, first_mode, "x");
            if (parts.next()) |w_str| {
                display.width = std.fmt.parseInt(u32, w_str, 10) catch 1920;
            }
            if (parts.next()) |h_str| {
                display.height = std.fmt.parseInt(u32, h_str, 10) catch 1080;
            }
        }
    }

    pub fn count(self: *const DisplayManager) usize {
        return self.displays.items.len;
    }

    pub fn get(self: *const DisplayManager, index: usize) ?*const Display {
        if (index >= self.displays.items.len) return null;
        return &self.displays.items[index];
    }

    /// Find display by name
    pub fn findByName(self: *DisplayManager, name_str: []const u8) ?*Display {
        for (self.displays.items) |*d| {
            if (mem.indexOf(u8, d.name, name_str) != null) return d;
        }
        return null;
    }

    /// Get all VRR-capable displays
    pub fn getVrrCapable(self: *const DisplayManager) []const Display {
        // Would need to allocate - for now return all
        return self.displays.items;
    }
};

/// Check if NVIDIA GPU is present
pub fn isNvidiaGpu() bool {
    fs.cwd().access("/proc/driver/nvidia/version", .{}) catch return false;
    return true;
}

/// Get NVIDIA driver version
pub fn getNvidiaDriverVersion(allocator: mem.Allocator) ?[]const u8 {
    const file = fs.cwd().openFile("/proc/driver/nvidia/version", .{}) catch return null;
    defer file.close();

    var buf: [512]u8 = undefined;
    const len = file.read(&buf) catch return null;
    const content = buf[0..len];

    // Find version number pattern (e.g., "590.48.01")
    // Look for 3 digits followed by a dot - more robust than text matching
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        // Look for start of version: digit followed by more digits and dots
        if (std.ascii.isDigit(content[i])) {
            var end = i;
            var dot_count: usize = 0;
            while (end < content.len and (std.ascii.isDigit(content[end]) or content[end] == '.')) {
                if (content[end] == '.') dot_count += 1;
                end += 1;
            }
            // Valid version has at least one dot and reasonable length (e.g., "590.48.01")
            if (dot_count >= 1 and end - i >= 5) {
                return allocator.dupe(u8, content[i..end]) catch null;
            }
        }
    }

    return null;
}

/// Frame limiter configuration
pub const FrameLimiter = struct {
    enabled: bool,
    target_fps: u32,
    mode: LimitMode,

    pub const LimitMode = enum {
        /// GPU-based limiting (lowest latency)
        gpu,
        /// CPU-based limiting (fallback)
        cpu,
        /// Vulkan present wait
        present_wait,
    };

    pub fn default() FrameLimiter {
        return .{
            .enabled = false,
            .target_fps = 0,
            .mode = .gpu,
        };
    }
};

/// System VRR status
pub const SystemStatus = struct {
    nvidia_detected: bool,
    driver_version: ?[]const u8,
    display_count: usize,
    vrr_capable_count: usize,
    vrr_enabled_count: usize,
    compositor: ?[]const u8,
    is_wayland: bool,
};

/// Get system VRR status
pub fn getSystemStatus(allocator: mem.Allocator) !SystemStatus {
    var manager = DisplayManager.init(allocator);
    defer manager.deinit();

    try manager.scan();

    var vrr_capable: usize = 0;
    var vrr_enabled: usize = 0;

    for (manager.displays.items) |d| {
        if (d.vrr_capable or d.gsync_capable or d.gsync_compatible) {
            vrr_capable += 1;
        }
        if (d.vrr_enabled) {
            vrr_enabled += 1;
        }
    }

    const compositor_name = if (manager.compositor) |c| c.name() else null;
    const compositor_str = if (compositor_name) |n| allocator.dupe(u8, n) catch null else detectCompositorLegacy(allocator);

    return .{
        .nvidia_detected = manager.nvidia_detected,
        .driver_version = if (manager.driver_version) |v| allocator.dupe(u8, v) catch null else null,
        .display_count = manager.displays.items.len,
        .vrr_capable_count = vrr_capable,
        .vrr_enabled_count = vrr_enabled,
        .compositor = compositor_str,
        .is_wayland = wayland.isWayland(),
    };
}

/// Detect current compositor (legacy method)
fn detectCompositorLegacy(allocator: mem.Allocator) ?[]const u8 {
    if (posix.getenv("XDG_CURRENT_DESKTOP")) |desktop| {
        if (mem.indexOf(u8, desktop, "KDE") != null) {
            return allocator.dupe(u8, "KWin") catch null;
        } else if (mem.indexOf(u8, desktop, "GNOME") != null) {
            return allocator.dupe(u8, "Mutter") catch null;
        } else if (mem.indexOf(u8, desktop, "Hyprland") != null) {
            return allocator.dupe(u8, "Hyprland") catch null;
        } else if (mem.indexOf(u8, desktop, "sway") != null) {
            return allocator.dupe(u8, "Sway") catch null;
        }
    }

    if (posix.getenv("WAYLAND_DISPLAY") != null) {
        return allocator.dupe(u8, "Wayland (unknown)") catch null;
    }

    if (posix.getenv("DISPLAY") != null) {
        return allocator.dupe(u8, "X11") catch null;
    }

    return null;
}

/// Unified VRR Controller
pub const VrrController = struct {
    allocator: mem.Allocator,
    is_wayland: bool,
    wayland_ctrl: ?wayland.WaylandVrrController,
    nvidia_ctrl: ?nvidia.NvidiaController,

    pub fn init(allocator: mem.Allocator) VrrController {
        const is_wl = wayland.isWayland();
        return .{
            .allocator = allocator,
            .is_wayland = is_wl,
            .wayland_ctrl = if (is_wl) wayland.WaylandVrrController.init(allocator) else null,
            .nvidia_ctrl = if (!is_wl and isNvidiaGpu()) nvidia.NvidiaController.init(allocator) else null,
        };
    }

    pub fn deinit(self: *VrrController) void {
        if (self.nvidia_ctrl) |*ctrl| ctrl.deinit();
    }

    /// Enable VRR on display
    pub fn enable(self: *VrrController, display: ?[]const u8) !void {
        if (self.wayland_ctrl) |*ctrl| {
            try ctrl.enableVrr(display);
        } else if (self.nvidia_ctrl) |*ctrl| {
            try ctrl.enableGsync(display orelse "DP-0", .gsync_compatible);
        } else {
            return error.NoBackend;
        }
    }

    /// Disable VRR on display
    pub fn disable(self: *VrrController, display: ?[]const u8) !void {
        if (self.wayland_ctrl) |*ctrl| {
            try ctrl.disableVrr(display);
        } else if (self.nvidia_ctrl) |*ctrl| {
            try ctrl.disableGsync(display orelse "DP-0");
        } else {
            return error.NoBackend;
        }
    }

    /// Get setup instructions
    pub fn getInstructions(self: *VrrController) []const u8 {
        if (self.wayland_ctrl) |*ctrl| {
            return ctrl.getInstructions();
        }
        return nvidia.NvidiaVrrMode.gsync_compatible.toMetaModeString();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "version" {
    try std.testing.expectEqual(@as(u8, 0), version.major);
    try std.testing.expectEqual(@as(u8, 2), version.minor);
}

test "VrrMode names" {
    try std.testing.expectEqualStrings("G-Sync", VrrMode.gsync.name());
    try std.testing.expectEqualStrings("G-Sync Compatible", VrrMode.gsync_compatible.name());
}

test "ConnectionType names" {
    try std.testing.expectEqualStrings("DisplayPort", ConnectionType.displayport.name());
    try std.testing.expectEqualStrings("HDMI", ConnectionType.hdmi.name());
}

test "ConnectionType VRR support" {
    try std.testing.expect(ConnectionType.displayport.supportsVrr());
    try std.testing.expect(ConnectionType.hdmi.supportsVrr());
    try std.testing.expect(!ConnectionType.vga.supportsVrr());
}
