//! nvsync - VRR/G-Sync Management for Linux
//!
//! Unified variable refresh rate control for NVIDIA GPUs on Linux.
//! Supports G-Sync, G-Sync Compatible, and VRR modes.

const std = @import("std");
const posix = std.posix;
const fs = std.fs;
const mem = std.mem;

/// Library version
pub const version = std.SemanticVersion{
    .major = 0,
    .minor = 1,
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
};

/// Display manager for detecting and controlling displays
pub const DisplayManager = struct {
    allocator: mem.Allocator,
    displays: std.ArrayListUnmanaged(Display),
    nvidia_detected: bool,
    driver_version: ?[]const u8,

    pub fn init(allocator: mem.Allocator) DisplayManager {
        return .{
            .allocator = allocator,
            .displays = .empty,
            .nvidia_detected = false,
            .driver_version = null,
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

        // Scan DRM devices
        try self.scanDrmDevices();
    }

    fn scanDrmDevices(self: *DisplayManager) !void {
        // Look for DRM card devices
        var dir = fs.cwd().openDir("/sys/class/drm", .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (!mem.startsWith(u8, entry.name, "card")) continue;
            if (mem.indexOf(u8, entry.name, "-") == null) continue; // Skip card0, want card0-DP-1

            // Parse connector info
            var path_buf: [256]u8 = undefined;
            const status_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/status", .{entry.name}) catch continue;

            const status = fs.cwd().readFileAlloc(status_path, self.allocator, .unlimited) catch continue;
            defer self.allocator.free(status);

            const trimmed = mem.trim(u8, status, &[_]u8{'\n', '\r', ' '});
            if (!mem.eql(u8, trimmed, "connected")) continue;

            // Connected display found
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

            // Try to get VRR capability
            var vrr_path_buf: [256]u8 = undefined;
            const vrr_path = std.fmt.bufPrint(&vrr_path_buf, "/sys/class/drm/{s}/vrr_capable", .{entry.name}) catch "";

            if (vrr_path.len > 0) {
                const vrr_cap = fs.cwd().readFileAlloc(vrr_path, self.allocator, .unlimited) catch null;
                if (vrr_cap) |v| {
                    defer self.allocator.free(v);
                    const cap_trimmed = mem.trim(u8, v, &[_]u8{'\n', '\r', ' '});
                    display.vrr_capable = mem.eql(u8, cap_trimmed, "1");
                    display.gsync_compatible = display.vrr_capable;
                }
            }

            // Check for enabled state
            const enabled_path = std.fmt.bufPrint(&vrr_path_buf, "/sys/class/drm/{s}/vrr_enabled", .{entry.name}) catch "";
            if (enabled_path.len > 0) {
                const vrr_en = fs.cwd().readFileAlloc(enabled_path, self.allocator, .unlimited) catch null;
                if (vrr_en) |v| {
                    defer self.allocator.free(v);
                    const en_trimmed = mem.trim(u8, v, &[_]u8{'\n', '\r', ' '});
                    display.vrr_enabled = mem.eql(u8, en_trimmed, "1");
                    if (display.vrr_enabled) {
                        display.current_mode = if (display.gsync_capable) .gsync else .gsync_compatible;
                    }
                }
            }

            // Parse mode for resolution and refresh
            try self.parseDisplayMode(&display, entry.name);

            self.displays.append(self.allocator, display) catch continue;
        }
    }

    fn parseConnectionType(self: *DisplayManager, name: []const u8) ConnectionType {
        _ = self;
        if (mem.indexOf(u8, name, "DP") != null or mem.indexOf(u8, name, "DisplayPort") != null) {
            return .displayport;
        } else if (mem.indexOf(u8, name, "HDMI") != null) {
            return .hdmi;
        } else if (mem.indexOf(u8, name, "DVI") != null) {
            return .dvi;
        } else if (mem.indexOf(u8, name, "VGA") != null) {
            return .vga;
        } else if (mem.indexOf(u8, name, "eDP") != null) {
            return .internal;
        }
        return .unknown;
    }

    fn parseDisplayMode(self: *DisplayManager, display: *Display, connector: []const u8) !void {
        var path_buf: [256]u8 = undefined;
        const modes_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/modes", .{connector}) catch return;

        const modes = fs.cwd().readFileAlloc(modes_path, self.allocator, .unlimited) catch return;
        defer self.allocator.free(modes);

        // Parse first mode (current)
        var lines = mem.splitSequence(u8, modes, "\n");
        if (lines.next()) |first_mode| {
            // Format: WIDTHxHEIGHT
            var parts = mem.splitSequence(u8, first_mode, "x");
            if (parts.next()) |w_str| {
                display.width = std.fmt.parseInt(u32, w_str, 10) catch 1920;
            }
            if (parts.next()) |h_str| {
                display.height = std.fmt.parseInt(u32, h_str, 10) catch 1080;
            }
        }
    }

    /// Get number of displays
    pub fn count(self: *const DisplayManager) usize {
        return self.displays.items.len;
    }

    /// Get display by index
    pub fn get(self: *const DisplayManager, index: usize) ?*const Display {
        if (index >= self.displays.items.len) return null;
        return &self.displays.items[index];
    }
};

/// Check if NVIDIA GPU is present
pub fn isNvidiaGpu() bool {
    // Check via /proc/driver/nvidia
    fs.cwd().access("/proc/driver/nvidia/version", .{}) catch return false;
    return true;
}

/// Get NVIDIA driver version
pub fn getNvidiaDriverVersion(allocator: mem.Allocator) ?[]const u8 {
    const content = fs.cwd().readFileAlloc("/proc/driver/nvidia/version", allocator, .unlimited) catch return null;
    defer allocator.free(content);

    // Parse "NVRM version: NVIDIA UNIX x86_64 Kernel Module  580.105.08"
    if (mem.indexOf(u8, content, "Kernel Module")) |idx| {
        const rest_raw = content[idx + 13 ..];
        const rest = mem.trim(u8, rest_raw, &[_]u8{ ' ', '\t', '\n', '\r' });

        // Find end of version string
        var end: usize = 0;
        for (rest, 0..) |c, i| {
            if (c == ' ' or c == '\n' or c == '\r') {
                end = i;
                break;
            }
            end = i + 1;
        }

        if (end > 0) {
            return allocator.dupe(u8, rest[0..end]) catch null;
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

    // Detect compositor
    const compositor = detectCompositor(allocator);

    return .{
        .nvidia_detected = manager.nvidia_detected,
        .driver_version = if (manager.driver_version) |v| allocator.dupe(u8, v) catch null else null,
        .display_count = manager.displays.items.len,
        .vrr_capable_count = vrr_capable,
        .vrr_enabled_count = vrr_enabled,
        .compositor = compositor,
    };
}

/// Detect current compositor
fn detectCompositor(allocator: mem.Allocator) ?[]const u8 {
    // Check XDG_CURRENT_DESKTOP or running processes
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

    // Check WAYLAND_DISPLAY for Wayland vs X11
    if (posix.getenv("WAYLAND_DISPLAY") != null) {
        return allocator.dupe(u8, "Wayland (unknown)") catch null;
    }

    if (posix.getenv("DISPLAY") != null) {
        return allocator.dupe(u8, "X11") catch null;
    }

    return null;
}

// =============================================================================
// Tests
// =============================================================================

test "version" {
    try std.testing.expectEqual(@as(u8, 0), version.major);
    try std.testing.expectEqual(@as(u8, 1), version.minor);
}

test "VrrMode names" {
    try std.testing.expectEqualStrings("G-Sync", VrrMode.gsync.name());
    try std.testing.expectEqualStrings("G-Sync Compatible", VrrMode.gsync_compatible.name());
}

test "ConnectionType names" {
    try std.testing.expectEqualStrings("DisplayPort", ConnectionType.displayport.name());
    try std.testing.expectEqualStrings("HDMI", ConnectionType.hdmi.name());
}
