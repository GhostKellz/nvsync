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
const Io = std.Io;
const Dir = Io.Dir;

// Sub-modules
pub const drm = @import("drm.zig");
pub const nvidia = @import("nvidia.zig");
pub const wayland = @import("wayland.zig");
pub const dbus = @import("dbus.zig");
pub const profiles = @import("profiles.zig");
pub const daemon = @import("daemon.zig");
pub const xrandr = @import("xrandr.zig");

/// Library version
pub const version = std.SemanticVersion{
    .major = 0,
    .minor = 2,
    .patch = 2,
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
        const io = Io.Threaded.global_single_threaded.io();
        var dir = Dir.cwd().openDir(io, "/sys/class/drm", .{ .iterate = true }) catch return;
        defer dir.close(io);

        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (!mem.startsWith(u8, entry.name, "card")) continue;
            if (mem.indexOf(u8, entry.name, "-") == null) continue;

            var path_buf: [256]u8 = undefined;
            const status_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/status", .{entry.name}) catch continue;

            const file = Dir.cwd().openFile(io, status_path, .{}) catch continue;
            defer file.close(io);

            var status_buf: [64]u8 = undefined;
            const status_len = posix.read(file.handle, &status_buf) catch continue;
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

            // Read EDID for VRR range and resolution
            const edid_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/edid", .{entry.name}) catch "";
            if (edid_path.len > 0) {
                const edid_file = Dir.cwd().openFile(io, edid_path, .{}) catch null;
                if (edid_file) |f| {
                    defer f.close(io);
                    var edid_buf: [512]u8 = undefined;
                    const edid_len = posix.read(f.handle, &edid_buf) catch 0;
                    if (edid_len >= 128) {
                        const edid = edid_buf[0..edid_len];

                        // Parse VRR range from EDID
                        const vrr_range = drm.parseEdidVrrRange(edid);
                        display.min_hz = vrr_range.min;
                        display.max_hz = vrr_range.max;
                        display.lfc_supported = vrr_range.lfc_supported;

                        // Parse native resolution from EDID
                        if (drm.parseEdidNativeResolution(edid)) |res| {
                            display.width = res.width;
                            display.height = res.height;
                        }
                    }
                }
            }

            // Read VRR capable from sysfs
            const vrr_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/vrr_capable", .{entry.name}) catch "";
            if (vrr_path.len > 0) {
                const vrr_file = Dir.cwd().openFile(io, vrr_path, .{}) catch null;
                if (vrr_file) |f| {
                    defer f.close(io);
                    var vrr_buf: [8]u8 = undefined;
                    const vrr_len = posix.read(f.handle, &vrr_buf) catch 0;
                    if (vrr_len > 0) {
                        const vrr_trimmed = mem.trim(u8, vrr_buf[0..vrr_len], &[_]u8{ '\n', '\r', ' ' });
                        display.vrr_capable = mem.eql(u8, vrr_trimmed, "1");
                        display.gsync_compatible = display.vrr_capable;
                    }
                }
            }

            // Check VRR enabled state
            const enabled_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/vrr_enabled", .{entry.name}) catch "";
            if (enabled_path.len > 0) {
                const en_file = Dir.cwd().openFile(io, enabled_path, .{}) catch null;
                if (en_file) |f| {
                    defer f.close(io);
                    var en_buf: [8]u8 = undefined;
                    const en_len = posix.read(f.handle, &en_buf) catch 0;
                    if (en_len > 0) {
                        const en_trimmed = mem.trim(u8, en_buf[0..en_len], &[_]u8{ '\n', '\r', ' ' });
                        display.vrr_enabled = mem.eql(u8, en_trimmed, "1");
                        if (display.vrr_enabled) {
                            display.current_mode = if (display.gsync_capable) .gsync else .gsync_compatible;
                        }
                    }
                }
            }

            // Parse refresh rate from modes (fallback)
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
        const io = Io.Threaded.global_single_threaded.io();
        var path_buf: [256]u8 = undefined;
        const modes_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/modes", .{connector}) catch return;

        const file = Dir.cwd().openFile(io, modes_path, .{}) catch return;
        defer file.close(io);

        var modes_buf: [1024]u8 = undefined;
        const modes_len = posix.read(file.handle, &modes_buf) catch return;
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

    // =========================================================================
    // VRR Control Methods
    // =========================================================================

    /// Enable VRR on a specific display by name (e.g., "DP-1", "HDMI-A-1")
    /// This is the primary API for nvprime and other consumers
    pub fn setVrrEnabled(self: *DisplayManager, display_name: []const u8, enabled: bool) !void {
        // Find the display
        const display = self.findByName(display_name) orelse return error.DisplayNotFound;

        if (!display.vrr_capable and !display.gsync_compatible) {
            return error.VrrNotSupported;
        }

        // Try sysfs method first (simplest, works on most systems)
        if (self.setVrrViaSysfs(display.name, enabled)) {
            // Update local state
            for (self.displays.items) |*d| {
                if (mem.eql(u8, d.name, display.name)) {
                    d.vrr_enabled = enabled;
                    d.current_mode = if (enabled)
                        (if (d.gsync_capable) .gsync else .gsync_compatible)
                    else
                        .off;
                    break;
                }
            }
            return;
        }

        // Try DRM ioctl method (requires DRM master)
        self.setVrrViaDrm(display.name, enabled) catch |err| {
            // Fall back to compositor-specific methods
            if (wayland.isWayland()) {
                var ctrl = wayland.WaylandVrrController.init(self.allocator);
                if (enabled) {
                    try ctrl.enableVrr(display_name);
                } else {
                    try ctrl.disableVrr(display_name);
                }
                return;
            }

            // X11: Use nvidia-settings
            if (isNvidiaGpu()) {
                var nv_ctrl = nvidia.NvidiaController.init(self.allocator);
                defer nv_ctrl.deinit();
                if (enabled) {
                    try nv_ctrl.enableGsync(display_name, .gsync_compatible);
                } else {
                    try nv_ctrl.disableGsync(display_name);
                }
                return;
            }

            return err;
        };
    }

    /// Set VRR via sysfs (most portable method)
    fn setVrrViaSysfs(self: *DisplayManager, connector: []const u8, enabled: bool) bool {
        _ = self;
        const io = Io.Threaded.global_single_threaded.io();
        var path_buf: [256]u8 = undefined;

        // Try direct path first (connector name from scan includes card prefix)
        const direct_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/vrr_enabled", .{connector}) catch return false;

        if (Dir.cwd().openFile(io, direct_path, .{ .mode = .write_only })) |file| {
            defer file.close(io);
            const value: []const u8 = if (enabled) "1\n" else "0\n";
            file.writeStreamingAll(io, value) catch return false;
            return true;
        } else |_| {
            // Try to find matching connector by suffix
            if (mem.indexOf(u8, connector, "-")) |idx| {
                const short_name = connector[idx + 1 ..];

                var dir = Dir.cwd().openDir(io, "/sys/class/drm", .{ .iterate = true }) catch return false;
                defer dir.close(io);

                var iter = dir.iterate();
                while (iter.next(io) catch null) |entry| {
                    if (mem.endsWith(u8, entry.name, short_name)) {
                        const full_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/vrr_enabled", .{entry.name}) catch continue;
                        if (Dir.cwd().openFile(io, full_path, .{ .mode = .write_only })) |file| {
                            defer file.close(io);
                            const value: []const u8 = if (enabled) "1\n" else "0\n";
                            file.writeStreamingAll(io, value) catch return false;
                            return true;
                        } else |_| {
                            continue;
                        }
                    }
                }
            }
        }

        return false;
    }

    /// Set VRR via DRM ioctl (requires DRM master)
    fn setVrrViaDrm(self: *DisplayManager, connector: []const u8, enabled: bool) !void {
        _ = self;
        // Parse card number from connector name (e.g., "card1-DP-1" -> card 1)
        const card_num = blk: {
            if (mem.startsWith(u8, connector, "card")) {
                const dash_idx = mem.indexOf(u8, connector, "-") orelse break :blk @as(u32, 0);
                break :blk std.fmt.parseInt(u32, connector[4..dash_idx], 10) catch 0;
            }
            break :blk @as(u32, 0);
        };

        // Get connector ID (would need to enumerate via ioctl)
        // For now, use sysfs to find it
        var path_buf: [256]u8 = undefined;
        const conn_id_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/connector_id", .{connector}) catch return error.PathError;

        const io = Io.Threaded.global_single_threaded.io();
        const file = Dir.cwd().openFile(io, conn_id_path, .{}) catch return error.ConnectorIdNotFound;
        defer file.close(io);

        var buf: [32]u8 = undefined;
        const len = posix.read(file.handle, &buf) catch return error.ReadFailed;
        const conn_id_str = mem.trim(u8, buf[0..len], &[_]u8{ '\n', '\r', ' ' });
        const connector_id = std.fmt.parseInt(u32, conn_id_str, 10) catch return error.InvalidConnectorId;

        try drm.setVrrEnabled(card_num, connector_id, enabled);
    }

    /// Enable VRR on all capable displays
    pub fn enableVrrAll(self: *DisplayManager) !void {
        var errors: usize = 0;
        for (self.displays.items) |d| {
            if (d.vrr_capable or d.gsync_compatible) {
                self.setVrrEnabled(d.name, true) catch {
                    errors += 1;
                };
            }
        }
        if (errors > 0 and errors == self.displays.items.len) {
            return error.AllDisplaysFailed;
        }
    }

    /// Disable VRR on all displays
    pub fn disableVrrAll(self: *DisplayManager) !void {
        for (self.displays.items) |d| {
            if (d.vrr_enabled) {
                self.setVrrEnabled(d.name, false) catch continue;
            }
        }
    }

    // =========================================================================
    // Display Mode / Refresh Rate Control
    // =========================================================================

    /// Display mode information
    pub const DisplayMode = struct {
        width: u32,
        height: u32,
        refresh_hz: u32,
        mode_string: [64]u8,
        mode_len: usize,

        pub fn getString(self: *const DisplayMode) []const u8 {
            return self.mode_string[0..self.mode_len];
        }
    };

    /// Get available display modes for a display
    pub fn getAvailableModes(self: *DisplayManager, display_name: []const u8) ![]DisplayMode {
        const display = self.findByName(display_name) orelse return error.DisplayNotFound;
        _ = display;

        var path_buf: [256]u8 = undefined;
        const modes_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/modes", .{display_name}) catch return error.PathError;

        const io = Io.Threaded.global_single_threaded.io();
        const file = Dir.cwd().openFile(io, modes_path, .{}) catch return error.ModesNotFound;
        defer file.close(io);

        var modes_buf: [4096]u8 = undefined;
        const modes_len = posix.read(file.handle, &modes_buf) catch return error.ReadFailed;
        const modes_content = modes_buf[0..modes_len];

        // Parse modes (format: "1920x1080" per line, Hz in separate file or parsed)
        var modes = std.ArrayListUnmanaged(DisplayMode).empty;
        var lines = mem.splitSequence(u8, modes_content, "\n");

        while (lines.next()) |line| {
            if (line.len == 0) continue;

            var mode = DisplayMode{
                .width = 0,
                .height = 0,
                .refresh_hz = 60, // Default, would need modeline parsing for exact
                .mode_string = [_]u8{0} ** 64,
                .mode_len = @min(line.len, 63),
            };

            @memcpy(mode.mode_string[0..mode.mode_len], line[0..mode.mode_len]);

            // Parse WxH format
            var parts = mem.splitSequence(u8, line, "x");
            if (parts.next()) |w| {
                mode.width = std.fmt.parseInt(u32, w, 10) catch 0;
            }
            if (parts.next()) |h| {
                mode.height = std.fmt.parseInt(u32, h, 10) catch 0;
            }

            if (mode.width > 0 and mode.height > 0) {
                modes.append(self.allocator, mode) catch continue;
            }
        }

        return modes.items;
    }

    /// Set display refresh rate (requires xrandr or wlr-randr)
    pub fn setRefreshRate(self: *DisplayManager, display_name: []const u8, hz: u32) !void {
        const display = self.findByName(display_name) orelse return error.DisplayNotFound;

        // Build mode string for the current resolution
        var mode_buf: [64]u8 = undefined;
        const mode_str = std.fmt.bufPrint(&mode_buf, "{d}x{d}", .{ display.width, display.height }) catch return error.FormatError;

        const io = Io.Threaded.global_single_threaded.io();

        if (wayland.isWayland()) {
            // Use wlr-randr for wlroots compositors, or compositor-specific tools
            const result = std.process.run(self.allocator, io, .{
                .argv = &[_][]const u8{
                    "wlr-randr",
                    "--output",
                    display_name,
                    "--mode",
                    mode_str,
                    "--custom-mode",
                    std.fmt.bufPrint(&mode_buf, "{d}x{d}@{d}", .{ display.width, display.height, hz }) catch return error.FormatError,
                },
            }) catch return error.WlrRandrFailed;
            defer self.allocator.free(result.stdout);
            defer self.allocator.free(result.stderr);

            if (result.term.exited != 0) {
                return error.ModeChangeFailed;
            }
        } else {
            // Use xrandr for X11
            var rate_buf: [16]u8 = undefined;
            const rate_str = std.fmt.bufPrint(&rate_buf, "{d}", .{hz}) catch return error.FormatError;

            const result = std.process.run(self.allocator, io, .{
                .argv = &[_][]const u8{
                    "xrandr",
                    "--output",
                    display_name,
                    "--mode",
                    mode_str,
                    "--rate",
                    rate_str,
                },
            }) catch return error.XrandrFailed;
            defer self.allocator.free(result.stdout);
            defer self.allocator.free(result.stderr);

            if (result.term.exited != 0) {
                return error.ModeChangeFailed;
            }
        }

        // Update local state
        for (self.displays.items) |*d| {
            if (mem.eql(u8, d.name, display.name)) {
                d.current_hz = hz;
                break;
            }
        }
    }
};

/// Check if NVIDIA GPU is present
pub fn isNvidiaGpu() bool {
    const io = Io.Threaded.global_single_threaded.io();
    Dir.cwd().access(io, "/proc/driver/nvidia/version", .{}) catch return false;
    return true;
}

/// Get NVIDIA driver version
pub fn getNvidiaDriverVersion(allocator: mem.Allocator) ?[]const u8 {
    const io = Io.Threaded.global_single_threaded.io();
    const file = Dir.cwd().openFile(io, "/proc/driver/nvidia/version", .{}) catch return null;
    defer file.close(io);

    var buf: [512]u8 = undefined;
    const len = posix.read(file.handle, &buf) catch return null;
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

/// Frame limiter with actual timing implementation
pub const FrameLimiter = struct {
    target_fps: u32,
    target_frame_time_ns: u64,
    last_frame_instant: ?std.time.Instant,
    mode: LimitMode,
    enabled: bool,

    // Statistics
    frame_count: u64,
    total_sleep_ns: u64,
    avg_frame_time_ns: u64,

    pub const LimitMode = enum {
        /// GPU-based limiting via environment variables (lowest latency)
        /// Uses __GL_MaxFramesAllowed
        gpu,
        /// CPU-based limiting with sleep + busy-wait hybrid
        cpu,
        /// Vulkan present wait (requires VK_KHR_present_wait)
        present_wait,
    };

    /// Create a new frame limiter with target FPS
    pub fn init(target_fps: u32, mode: LimitMode) FrameLimiter {
        const frame_time: u64 = if (target_fps > 0) 1_000_000_000 / target_fps else 0;
        return .{
            .target_fps = target_fps,
            .target_frame_time_ns = frame_time,
            .last_frame_instant = std.time.Instant.now() catch null,
            .mode = mode,
            .enabled = target_fps > 0,
            .frame_count = 0,
            .total_sleep_ns = 0,
            .avg_frame_time_ns = frame_time,
        };
    }

    /// Create disabled frame limiter
    pub fn disabled() FrameLimiter {
        return .{
            .target_fps = 0,
            .target_frame_time_ns = 0,
            .last_frame_instant = null,
            .mode = .cpu,
            .enabled = false,
            .frame_count = 0,
            .total_sleep_ns = 0,
            .avg_frame_time_ns = 0,
        };
    }

    /// Call at the start of each frame
    pub fn beginFrame(self: *FrameLimiter) void {
        self.last_frame_instant = std.time.Instant.now() catch null;
    }

    /// Call at the end of each frame - waits to maintain target FPS
    /// Uses hybrid sleep + busy-wait for sub-millisecond precision
    pub fn endFrame(self: *FrameLimiter) void {
        if (!self.enabled or self.target_frame_time_ns == 0) return;
        if (self.mode == .gpu) return; // GPU mode doesn't need CPU timing

        const last_instant = self.last_frame_instant orelse return;
        const now = std.time.Instant.now() catch return;

        const elapsed = now.since(last_instant);
        if (elapsed >= self.target_frame_time_ns) {
            // Already over budget, no sleep needed
            self.updateStats(elapsed, 0);
            return;
        }

        const remaining = self.target_frame_time_ns - elapsed;

        // Hybrid approach: sleep most of the time, busy-wait the last portion
        // This balances CPU usage with timing precision
        const busy_wait_threshold: u64 = 500_000; // 0.5ms

        if (remaining > busy_wait_threshold + 1_000_000) {
            // Sleep for most of the remaining time (leave 0.5ms + margin for busy-wait)
            const sleep_time = remaining - busy_wait_threshold;
            std.time.sleep(sleep_time);
            self.total_sleep_ns += sleep_time;
        }

        // Busy-wait for the final portion (sub-millisecond precision)
        while (true) {
            const current = std.time.Instant.now() catch break;
            const total_elapsed = current.since(last_instant);
            if (total_elapsed >= self.target_frame_time_ns) break;

            // Hint to CPU we're spin-waiting
            std.atomic.spinLoopHint();
        }

        const final_now = std.time.Instant.now() catch return;
        const final_elapsed = final_now.since(last_instant);
        self.updateStats(final_elapsed, remaining);
    }

    fn updateStats(self: *FrameLimiter, frame_time_ns: u64, slept_ns: u64) void {
        self.frame_count += 1;
        self.total_sleep_ns += slept_ns;

        // Exponential moving average for frame time
        const alpha: u64 = 16; // 1/16 weight for new sample
        self.avg_frame_time_ns = (self.avg_frame_time_ns * (alpha - 1) + frame_time_ns) / alpha;
    }

    /// Get current average FPS
    pub fn getAverageFps(self: *const FrameLimiter) f32 {
        if (self.avg_frame_time_ns == 0) return 0;
        return @as(f32, 1_000_000_000.0) / @as(f32, @floatFromInt(self.avg_frame_time_ns));
    }

    /// Get target frame time in milliseconds
    pub fn getTargetFrameTimeMs(self: *const FrameLimiter) f32 {
        if (self.target_frame_time_ns == 0) return 0;
        return @as(f32, @floatFromInt(self.target_frame_time_ns)) / 1_000_000.0;
    }

    /// Reset statistics
    pub fn resetStats(self: *FrameLimiter) void {
        self.frame_count = 0;
        self.total_sleep_ns = 0;
        self.avg_frame_time_ns = self.target_frame_time_ns;
    }

    /// Set new target FPS
    pub fn setTargetFps(self: *FrameLimiter, fps: u32) void {
        self.target_fps = fps;
        self.target_frame_time_ns = if (fps > 0) 1_000_000_000 / fps else 0;
        self.enabled = fps > 0;
        self.resetStats();
    }

    /// Generate environment variables for GPU-based limiting
    pub fn getGpuEnvVars(self: *const FrameLimiter) struct {
        sync_to_vblank: []const u8,
        max_frames: []const u8,
    } {
        if (self.target_fps == 0) {
            return .{
                .sync_to_vblank = "",
                .max_frames = "",
            };
        }

        // These are compile-time strings, caller should format target_fps
        return .{
            .sync_to_vblank = "0",
            .max_frames = "set to target FPS",
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
    if (std.c.getenv("XDG_CURRENT_DESKTOP")) |desktop_ptr| {
        const desktop = mem.sliceTo(desktop_ptr, 0);
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

    if (std.c.getenv("WAYLAND_DISPLAY") != null) {
        return allocator.dupe(u8, "Wayland (unknown)") catch null;
    }

    if (std.c.getenv("DISPLAY") != null) {
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
// Simplified VRR API - Convenience functions for easy access
// =============================================================================

/// Enable VRR on a display (simplified API)
/// This is the easiest way for consumers like nvprime to enable VRR
pub fn enableVrr(allocator: mem.Allocator, display_name: ?[]const u8) !void {
    var manager = DisplayManager.init(allocator);
    defer manager.deinit();
    try manager.scan();

    if (display_name) |name| {
        try manager.setVrrEnabled(name, true);
    } else {
        try manager.enableVrrAll();
    }
}

/// Disable VRR on a display (simplified API)
pub fn disableVrr(allocator: mem.Allocator, display_name: ?[]const u8) !void {
    var manager = DisplayManager.init(allocator);
    defer manager.deinit();
    try manager.scan();

    if (display_name) |name| {
        try manager.setVrrEnabled(name, false);
    } else {
        try manager.disableVrrAll();
    }
}

/// Check if VRR is currently enabled on a display
pub fn isVrrEnabled(allocator: mem.Allocator, display_name: []const u8) !bool {
    var manager = DisplayManager.init(allocator);
    defer manager.deinit();
    try manager.scan();

    const display = manager.findByName(display_name) orelse return error.DisplayNotFound;
    return display.vrr_enabled;
}

/// Check if a display is VRR-capable
pub fn isVrrCapable(allocator: mem.Allocator, display_name: []const u8) !bool {
    var manager = DisplayManager.init(allocator);
    defer manager.deinit();
    try manager.scan();

    const display = manager.findByName(display_name) orelse return error.DisplayNotFound;
    return display.vrr_capable or display.gsync_capable or display.gsync_compatible;
}

/// Get VRR range for a display
pub fn getVrrRange(allocator: mem.Allocator, display_name: []const u8) !struct { min: u32, max: u32, lfc: bool } {
    var manager = DisplayManager.init(allocator);
    defer manager.deinit();
    try manager.scan();

    const display = manager.findByName(display_name) orelse return error.DisplayNotFound;
    return .{
        .min = display.min_hz,
        .max = display.max_hz,
        .lfc = display.lfc_supported,
    };
}

/// Set display refresh rate (simplified API)
pub fn setRefreshRate(allocator: mem.Allocator, display_name: []const u8, hz: u32) !void {
    var manager = DisplayManager.init(allocator);
    defer manager.deinit();
    try manager.scan();
    try manager.setRefreshRate(display_name, hz);
}

// =============================================================================
// Profile Lookup API - For nvprime integration
// =============================================================================

/// Game profile settings returned from lookup
pub const ProfileSettings = struct {
    name: []const u8,
    executable: []const u8,
    vrr_mode: VrrMode,
    frame_limit: u32,
    force_gsync: bool,
    lfc_enabled: bool,
};

/// Get profile settings for a game executable
/// This is the primary API for nvprime to auto-apply settings on game launch
pub fn getProfileForProcess(allocator: mem.Allocator, executable: []const u8) !?ProfileSettings {
    var manager = profiles.ProfileManager.init(allocator);
    defer manager.deinit();

    manager.load() catch return null;

    if (manager.getForProcess(executable)) |profile| {
        return ProfileSettings{
            .name = profile.name,
            .executable = profile.executable,
            .vrr_mode = profile.vrr_mode,
            .frame_limit = profile.frame_limit,
            .force_gsync = profile.force_gsync,
            .lfc_enabled = profile.lfc_enabled,
        };
    }

    return null;
}

/// Apply a game profile (enable VRR and set frame limit)
pub fn applyProfile(allocator: mem.Allocator, executable: []const u8) !void {
    const profile = try getProfileForProcess(allocator, executable) orelse return error.ProfileNotFound;

    // Apply VRR settings if not off
    if (profile.vrr_mode != .off) {
        enableVrr(allocator, null) catch {}; // Best effort
    }

    // Frame limit is applied via environment variables for GPU limiting
    // The caller (nvprime) can use profile.frame_limit to set __GL_MaxFramesAllowed
}

/// List all available profiles
pub fn listProfiles(allocator: mem.Allocator) ![]profiles.GameProfile {
    var manager = profiles.ProfileManager.init(allocator);
    defer manager.deinit();

    manager.load() catch return &[_]profiles.GameProfile{};

    // Copy profiles to return
    var result = std.ArrayListUnmanaged(profiles.GameProfile).empty;
    var iter = manager.list();
    while (iter.next()) |entry| {
        result.append(allocator, entry.value_ptr.*) catch continue;
    }

    return result.items;
}

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

test "FrameLimiter init" {
    var limiter = FrameLimiter.init(144, .cpu);
    try std.testing.expectEqual(@as(u32, 144), limiter.target_fps);
    try std.testing.expect(limiter.enabled);

    // Target frame time for 144 FPS should be ~6.94ms (6944444 ns)
    const expected_ns: u64 = 1_000_000_000 / 144;
    try std.testing.expectEqual(expected_ns, limiter.target_frame_time_ns);
}

test "FrameLimiter disabled" {
    const limiter = FrameLimiter.disabled();
    try std.testing.expectEqual(@as(u32, 0), limiter.target_fps);
    try std.testing.expect(!limiter.enabled);
}

test "FrameLimiter setTargetFps" {
    var limiter = FrameLimiter.init(60, .cpu);
    try std.testing.expectEqual(@as(u32, 60), limiter.target_fps);

    limiter.setTargetFps(144);
    try std.testing.expectEqual(@as(u32, 144), limiter.target_fps);
    try std.testing.expect(limiter.enabled);

    limiter.setTargetFps(0);
    try std.testing.expectEqual(@as(u32, 0), limiter.target_fps);
    try std.testing.expect(!limiter.enabled);
}

test "FrameLimiter getTargetFrameTimeMs" {
    const limiter = FrameLimiter.init(60, .cpu);
    const frame_time_ms = limiter.getTargetFrameTimeMs();
    // 60 FPS = 16.67ms per frame
    try std.testing.expect(frame_time_ms > 16.0 and frame_time_ms < 17.0);
}
