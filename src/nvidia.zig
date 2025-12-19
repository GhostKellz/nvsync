//! NVIDIA-specific VRR Control
//!
//! Controls VRR via nvidia-settings and NV-CONTROL extension.
//! Works on X11 with NVIDIA proprietary driver.

const std = @import("std");
const posix = std.posix;
const fs = std.fs;
const mem = std.mem;

/// NVIDIA VRR mode
pub const NvidiaVrrMode = enum {
    /// VRR disabled
    disabled,
    /// G-Sync enabled (native module)
    gsync,
    /// G-Sync Compatible (adaptive sync)
    gsync_compatible,
    /// Force G-Sync Compatible on non-validated monitors
    gsync_compatible_force,

    pub fn toMetaModeString(self: NvidiaVrrMode) []const u8 {
        return switch (self) {
            .disabled => "AllowGSYNC=Off, AllowGSYNCCompatible=Off",
            .gsync => "AllowGSYNC=On",
            .gsync_compatible => "AllowGSYNCCompatible=On",
            .gsync_compatible_force => "AllowGSYNCCompatibleSpecific=On",
        };
    }
};

/// NVIDIA display info from nvidia-settings
pub const NvidiaDisplay = struct {
    allocator: mem.Allocator,
    name: []const u8,
    connection: []const u8, // DP-0, HDMI-0, etc.
    gpu: []const u8,
    gsync_capable: bool,
    gsync_compatible: bool,
    gsync_enabled: bool,
    refresh_rate: u32,
    vrr_min_refresh: u32,

    pub fn deinit(self: *NvidiaDisplay) void {
        self.allocator.free(self.name);
        self.allocator.free(self.connection);
        self.allocator.free(self.gpu);
    }
};

/// NVIDIA VRR Controller
pub const NvidiaController = struct {
    allocator: mem.Allocator,
    displays: std.ArrayListUnmanaged(NvidiaDisplay),
    driver_version: ?[]const u8,
    gpu_name: ?[]const u8,

    pub fn init(allocator: mem.Allocator) NvidiaController {
        return .{
            .allocator = allocator,
            .displays = .empty,
            .driver_version = null,
            .gpu_name = null,
        };
    }

    pub fn deinit(self: *NvidiaController) void {
        for (self.displays.items) |*d| {
            d.deinit();
        }
        self.displays.deinit(self.allocator);
        if (self.driver_version) |v| self.allocator.free(v);
        if (self.gpu_name) |n| self.allocator.free(n);
    }

    /// Query NVIDIA GPU and display info
    pub fn query(self: *NvidiaController) !void {
        // Get driver version
        self.driver_version = getDriverVersion(self.allocator);

        // Get GPU name
        self.gpu_name = try queryNvidiaSetting(self.allocator, "GPUFullName");

        // Query displays via nvidia-settings
        try self.queryDisplays();
    }

    fn queryDisplays(self: *NvidiaController) !void {
        // Query connected displays
        const dpys = try queryNvidiaSetting(self.allocator, "EnabledDisplays") orelse return;
        defer self.allocator.free(dpys);

        // Parse display list and query each
        // Format: "DPY-1, DPY-2" or bitmask
        // For simplicity, query common outputs
        const outputs = [_][]const u8{ "DP-0", "DP-1", "DP-2", "DP-3", "HDMI-0", "HDMI-1" };

        for (outputs) |output| {
            const gsync_cap = queryNvidiaDisplayAttribute(self.allocator, output, "GSYNCSupported");
            const gsync_compat = queryNvidiaDisplayAttribute(self.allocator, output, "GSYNCCompatible");

            if (gsync_cap != null or gsync_compat != null) {
                const display = NvidiaDisplay{
                    .allocator = self.allocator,
                    .name = self.allocator.dupe(u8, output) catch continue,
                    .connection = self.allocator.dupe(u8, output) catch continue,
                    .gpu = self.allocator.dupe(u8, self.gpu_name orelse "GPU-0") catch continue,
                    .gsync_capable = if (gsync_cap) |v| blk: {
                        defer self.allocator.free(v);
                        break :blk mem.eql(u8, v, "1");
                    } else false,
                    .gsync_compatible = if (gsync_compat) |v| blk: {
                        defer self.allocator.free(v);
                        break :blk mem.eql(u8, v, "1");
                    } else false,
                    .gsync_enabled = false, // Would need to check current mode
                    .refresh_rate = 60,
                    .vrr_min_refresh = 48,
                };

                self.displays.append(self.allocator, display) catch continue;
            }

            if (gsync_cap) |v| self.allocator.free(v);
            if (gsync_compat) |v| self.allocator.free(v);
        }
    }

    /// Enable G-Sync/G-Sync Compatible on a display
    pub fn enableGsync(self: *NvidiaController, display: []const u8, mode: NvidiaVrrMode) !void {
        _ = self;
        const metamode = try buildMetaMode(display, mode);
        try setMetaMode(metamode);
    }

    /// Disable G-Sync on a display
    pub fn disableGsync(self: *NvidiaController, display: []const u8) !void {
        _ = self;
        const metamode = try buildMetaMode(display, .disabled);
        try setMetaMode(metamode);
    }
};

/// Get NVIDIA driver version
pub fn getDriverVersion(allocator: mem.Allocator) ?[]const u8 {
    const content = fs.cwd().readFileAlloc("/proc/driver/nvidia/version", allocator, 4096) catch return null;
    defer allocator.free(content);

    // Parse "NVRM version: NVIDIA UNIX x86_64 Kernel Module  580.105.08"
    if (mem.indexOf(u8, content, "Kernel Module")) |idx| {
        const rest_raw = content[idx + 13 ..];
        const rest = mem.trim(u8, rest_raw, " \t\n\r");

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

/// Query nvidia-settings attribute
pub fn queryNvidiaSetting(allocator: mem.Allocator, attribute: []const u8) !?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "nvidia-settings",
            "-q",
            attribute,
            "-t", // Terse output
        },
    }) catch return null;

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) return null;

    const trimmed = mem.trim(u8, result.stdout, "\n \t\r");
    if (trimmed.len == 0) return null;

    return allocator.dupe(u8, trimmed) catch null;
}

/// Query nvidia-settings display attribute
pub fn queryNvidiaDisplayAttribute(allocator: mem.Allocator, display: []const u8, attribute: []const u8) ?[]const u8 {
    var query_buf: [256]u8 = undefined;
    const query = std.fmt.bufPrint(&query_buf, "[dpy:{s}]/{s}", .{ display, attribute }) catch return null;

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "nvidia-settings",
            "-q",
            query,
            "-t",
        },
    }) catch return null;

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) return null;

    const trimmed = mem.trim(u8, result.stdout, "\n \t\r");
    if (trimmed.len == 0) return null;

    return allocator.dupe(u8, trimmed) catch null;
}

/// Build MetaMode string for nvidia-settings
fn buildMetaMode(display: []const u8, mode: NvidiaVrrMode) ![]const u8 {
    _ = display;
    // Format: "DP-0: nvidia-auto-select +0+0 {AllowGSYNCCompatible=On}"
    // For now return the VRR options part
    return mode.toMetaModeString();
}

/// Set MetaMode via nvidia-settings
fn setMetaMode(metamode: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var assign_buf: [512]u8 = undefined;
    const assign = std.fmt.bufPrint(&assign_buf, "CurrentMetaMode=\"nvidia-auto-select {{{s}}}\"", .{metamode}) catch return error.BufferError;

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "nvidia-settings",
            "--assign",
            assign,
        },
    }) catch return error.CommandFailed;

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        return error.SetModeFailed;
    }
}

/// Set frame rate limit via nvidia-settings
pub fn setFrameLimit(fps: u32) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // __GL_MaxFramesAllowed is an environment variable, not nvidia-settings
    // But we can suggest the command
    std.debug.print("To set frame limit to {d} FPS:\n", .{fps});
    std.debug.print("  export __GL_SYNC_TO_VBLANK=0\n", .{});
    if (fps > 0) {
        std.debug.print("  export __GL_MaxFramesAllowed={d}\n", .{fps});
    } else {
        std.debug.print("  unset __GL_MaxFramesAllowed\n", .{});
    }

    // Also can use nvidia-settings for some properties
    if (fps > 0) {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{
                "nvidia-settings",
                "--assign",
                "SyncToVBlank=0",
            },
        }) catch return;

        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }
}

/// Environment variables for NVIDIA VRR/performance
pub const NvidiaEnvVars = struct {
    /// Enable VRR in DXVK
    pub const DXVK_VRR = "__GL_VRR_ALLOWED";
    /// Enable G-Sync Compatible for all monitors
    pub const GSYNC_COMPAT = "__GL_GSYNC_ALLOWED";
    /// Frame limiter
    pub const MAX_FRAMES = "__GL_MaxFramesAllowed";
    /// Disable VSync for frame limiting
    pub const SYNC_TO_VBLANK = "__GL_SYNC_TO_VBLANK";
    /// Shader cache path
    pub const SHADER_CACHE = "__GL_SHADER_DISK_CACHE_PATH";
    /// Threaded optimizations
    pub const THREADED_OPT = "__GL_THREADED_OPTIMIZATIONS";
};

/// Generate environment variables for optimal VRR gaming
pub fn getVrrEnvVars(fps_limit: ?u32) std.ArrayList([2][]const u8) {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var vars = std.ArrayList([2][]const u8).init(allocator);

    vars.append(.{ NvidiaEnvVars.GSYNC_COMPAT, "1" }) catch {};
    vars.append(.{ NvidiaEnvVars.DXVK_VRR, "1" }) catch {};
    vars.append(.{ NvidiaEnvVars.THREADED_OPT, "1" }) catch {};

    if (fps_limit) |fps| {
        var buf: [16]u8 = undefined;
        const fps_str = std.fmt.bufPrint(&buf, "{d}", .{fps}) catch "0";
        vars.append(.{ NvidiaEnvVars.MAX_FRAMES, fps_str }) catch {};
        vars.append(.{ NvidiaEnvVars.SYNC_TO_VBLANK, "0" }) catch {};
    }

    return vars;
}

test "NvidiaVrrMode strings" {
    try std.testing.expectEqualStrings("AllowGSYNCCompatible=On", NvidiaVrrMode.gsync_compatible.toMetaModeString());
}
