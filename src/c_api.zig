//! nvsync C API
//!
//! C-compatible API for VRR/G-Sync management.
//! This module exports functions with C ABI for FFI integration with
//! Rust (nvproton), C++, and other languages.

const std = @import("std");
const nvsync = @import("root.zig");

// =============================================================================
// Types
// =============================================================================

/// Opaque context handle for C consumers
pub const nvsync_ctx_t = ?*anyopaque;

/// Result codes
pub const nvsync_result_t = enum(c_int) {
    success = 0,
    error_invalid_handle = -1,
    error_scan_failed = -2,
    error_no_backend = -3,
    error_display_not_found = -4,
    error_invalid_param = -5,
    error_not_supported = -6,
    error_unknown = -99,
};

/// VRR mode enum for C
pub const nvsync_vrr_mode_t = enum(c_int) {
    off = 0,
    gsync = 1,
    gsync_compatible = 2,
    vrr = 3,
    unknown = 4,
};

/// Connection type enum for C
pub const nvsync_connection_t = enum(c_int) {
    displayport = 0,
    hdmi = 1,
    dvi = 2,
    vga = 3,
    internal = 4,
    unknown = 5,
};

/// Display information structure for C
pub const nvsync_display_t = extern struct {
    name: [64]u8,
    connector: [64]u8,
    connection_type: nvsync_connection_t,
    current_hz: u32,
    min_hz: u32,
    max_hz: u32,
    vrr_capable: bool,
    gsync_capable: bool,
    gsync_compatible: bool,
    lfc_supported: bool,
    vrr_enabled: bool,
    current_mode: nvsync_vrr_mode_t,
    width: u32,
    height: u32,
};

/// System status structure for C
pub const nvsync_status_t = extern struct {
    nvidia_detected: bool,
    driver_version: [32]u8,
    display_count: u32,
    vrr_capable_count: u32,
    vrr_enabled_count: u32,
    compositor: [32]u8,
    is_wayland: bool,
};

/// Frame limiter configuration for C
pub const nvsync_framelimit_t = extern struct {
    enabled: bool,
    target_fps: u32,
    mode: c_int, // 0 = gpu, 1 = cpu, 2 = present_wait
};

// =============================================================================
// Internal Context
// =============================================================================

const Context = struct {
    allocator: std.mem.Allocator,
    display_manager: nvsync.DisplayManager,
    vrr_controller: nvsync.VrrController,
    frame_limiter: nvsync.FrameLimiter,
    last_error: ?[]const u8,

    fn create() !*Context {
        const allocator = std.heap.c_allocator;
        const ctx = try allocator.create(Context);
        errdefer allocator.destroy(ctx);

        ctx.* = .{
            .allocator = allocator,
            .display_manager = nvsync.DisplayManager.init(allocator),
            .vrr_controller = nvsync.VrrController.init(allocator),
            .frame_limiter = nvsync.FrameLimiter.default(),
            .last_error = null,
        };

        return ctx;
    }

    fn destroy(self: *Context) void {
        self.vrr_controller.deinit();
        self.display_manager.deinit();
        if (self.last_error) |err| {
            self.allocator.free(err);
        }
        self.allocator.destroy(self);
    }

    fn setError(self: *Context, msg: []const u8) void {
        if (self.last_error) |err| {
            self.allocator.free(err);
        }
        self.last_error = self.allocator.dupe(u8, msg) catch null;
    }
};

// =============================================================================
// Exported C API Functions
// =============================================================================

/// Initialize nvsync context
/// Returns: context handle or null on failure
export fn nvsync_init() nvsync_ctx_t {
    const ctx = Context.create() catch return null;
    return @ptrCast(ctx);
}

/// Destroy nvsync context and free resources
export fn nvsync_destroy(ctx: nvsync_ctx_t) void {
    if (ctx) |ptr| {
        const context: *Context = @ptrCast(@alignCast(ptr));
        context.destroy();
    }
}

/// Get library version (major << 16 | minor << 8 | patch)
export fn nvsync_get_version() u32 {
    return (@as(u32, nvsync.version.major) << 16) |
        (@as(u32, nvsync.version.minor) << 8) |
        nvsync.version.patch;
}

/// Scan for connected displays
export fn nvsync_scan(ctx: nvsync_ctx_t) nvsync_result_t {
    const context: *Context = @ptrCast(@alignCast(ctx orelse return .error_invalid_handle));

    context.display_manager.scan() catch |err| {
        context.setError(@errorName(err));
        return .error_scan_failed;
    };

    return .success;
}

/// Get number of displays
export fn nvsync_get_display_count(ctx: nvsync_ctx_t) c_int {
    const context: *Context = @ptrCast(@alignCast(ctx orelse return -1));
    return @intCast(context.display_manager.count());
}

/// Get display information by index
export fn nvsync_get_display(ctx: nvsync_ctx_t, index: u32, out_display: ?*nvsync_display_t) nvsync_result_t {
    const context: *Context = @ptrCast(@alignCast(ctx orelse return .error_invalid_handle));
    const display_ptr = out_display orelse return .error_invalid_param;

    const display = context.display_manager.get(index) orelse return .error_display_not_found;

    // Copy name with null termination
    const name_len = @min(display.name.len, 63);
    @memcpy(display_ptr.name[0..name_len], display.name[0..name_len]);
    display_ptr.name[name_len] = 0;

    // Copy connector
    const conn_len = @min(display.connector.len, 63);
    @memcpy(display_ptr.connector[0..conn_len], display.connector[0..conn_len]);
    display_ptr.connector[conn_len] = 0;

    display_ptr.connection_type = switch (display.connection_type) {
        .displayport => .displayport,
        .hdmi => .hdmi,
        .dvi => .dvi,
        .vga => .vga,
        .internal => .internal,
        .unknown => .unknown,
    };

    display_ptr.current_hz = display.current_hz;
    display_ptr.min_hz = display.min_hz;
    display_ptr.max_hz = display.max_hz;
    display_ptr.vrr_capable = display.vrr_capable;
    display_ptr.gsync_capable = display.gsync_capable;
    display_ptr.gsync_compatible = display.gsync_compatible;
    display_ptr.lfc_supported = display.lfc_supported;
    display_ptr.vrr_enabled = display.vrr_enabled;

    display_ptr.current_mode = switch (display.current_mode) {
        .off => .off,
        .gsync => .gsync,
        .gsync_compatible => .gsync_compatible,
        .vrr => .vrr,
        .unknown => .unknown,
    };

    display_ptr.width = display.width;
    display_ptr.height = display.height;

    return .success;
}

/// Get system VRR status
export fn nvsync_get_status(ctx: nvsync_ctx_t, out_status: ?*nvsync_status_t) nvsync_result_t {
    const context: *Context = @ptrCast(@alignCast(ctx orelse return .error_invalid_handle));
    const status_ptr = out_status orelse return .error_invalid_param;

    // Clear the output structure
    @memset(std.mem.asBytes(status_ptr), 0);

    status_ptr.nvidia_detected = context.display_manager.nvidia_detected;
    status_ptr.display_count = @intCast(context.display_manager.count());
    status_ptr.is_wayland = nvsync.wayland.isWayland();

    // Copy driver version
    if (context.display_manager.driver_version) |ver| {
        const ver_len = @min(ver.len, 31);
        @memcpy(status_ptr.driver_version[0..ver_len], ver[0..ver_len]);
    }

    // Copy compositor name
    if (context.display_manager.compositor) |comp| {
        const comp_name = comp.name();
        const comp_len = @min(comp_name.len, 31);
        @memcpy(status_ptr.compositor[0..comp_len], comp_name[0..comp_len]);
    }

    // Count VRR capable and enabled displays
    var vrr_capable: u32 = 0;
    var vrr_enabled: u32 = 0;

    for (context.display_manager.displays.items) |d| {
        if (d.vrr_capable or d.gsync_capable or d.gsync_compatible) {
            vrr_capable += 1;
        }
        if (d.vrr_enabled) {
            vrr_enabled += 1;
        }
    }

    status_ptr.vrr_capable_count = vrr_capable;
    status_ptr.vrr_enabled_count = vrr_enabled;

    return .success;
}

/// Enable VRR on a display (null for all displays)
export fn nvsync_enable_vrr(ctx: nvsync_ctx_t, display_name: ?[*:0]const u8) nvsync_result_t {
    const context: *Context = @ptrCast(@alignCast(ctx orelse return .error_invalid_handle));

    const name_slice: ?[]const u8 = if (display_name) |name| std.mem.span(name) else null;

    context.vrr_controller.enable(name_slice) catch |err| {
        context.setError(@errorName(err));
        return switch (err) {
            error.NoBackend => .error_no_backend,
            else => .error_unknown,
        };
    };

    return .success;
}

/// Disable VRR on a display (null for all displays)
export fn nvsync_disable_vrr(ctx: nvsync_ctx_t, display_name: ?[*:0]const u8) nvsync_result_t {
    const context: *Context = @ptrCast(@alignCast(ctx orelse return .error_invalid_handle));

    const name_slice: ?[]const u8 = if (display_name) |name| std.mem.span(name) else null;

    context.vrr_controller.disable(name_slice) catch |err| {
        context.setError(@errorName(err));
        return switch (err) {
            error.NoBackend => .error_no_backend,
            else => .error_unknown,
        };
    };

    return .success;
}

/// Set frame rate limit
export fn nvsync_set_frame_limit(ctx: nvsync_ctx_t, target_fps: u32) nvsync_result_t {
    const context: *Context = @ptrCast(@alignCast(ctx orelse return .error_invalid_handle));

    if (target_fps == 0) {
        context.frame_limiter.enabled = false;
        context.frame_limiter.target_fps = 0;
    } else {
        context.frame_limiter.enabled = true;
        context.frame_limiter.target_fps = target_fps;
    }

    return .success;
}

/// Get current frame limit configuration
export fn nvsync_get_frame_limit(ctx: nvsync_ctx_t, out_config: ?*nvsync_framelimit_t) nvsync_result_t {
    const context: *Context = @ptrCast(@alignCast(ctx orelse return .error_invalid_handle));
    const config_ptr = out_config orelse return .error_invalid_param;

    config_ptr.enabled = context.frame_limiter.enabled;
    config_ptr.target_fps = context.frame_limiter.target_fps;
    config_ptr.mode = switch (context.frame_limiter.mode) {
        .gpu => 0,
        .cpu => 1,
        .present_wait => 2,
    };

    return .success;
}

/// Check if NVIDIA GPU is present
export fn nvsync_is_nvidia_gpu() bool {
    return nvsync.isNvidiaGpu();
}

/// Check if running under Wayland
export fn nvsync_is_wayland() bool {
    return nvsync.wayland.isWayland();
}

/// Get last error message (null-terminated)
export fn nvsync_get_last_error(ctx: nvsync_ctx_t) [*:0]const u8 {
    const context: *Context = @ptrCast(@alignCast(ctx orelse return "invalid context"));
    if (context.last_error) |err| {
        // We need a static buffer for this
        const Static = struct {
            var buf: [256]u8 = undefined;
        };
        const len = @min(err.len, Static.buf.len - 1);
        @memcpy(Static.buf[0..len], err[0..len]);
        Static.buf[len] = 0;
        return @ptrCast(&Static.buf);
    }
    return "no error";
}

/// Get VRR range for a display (returns as string like "48-144Hz")
export fn nvsync_get_vrr_range(ctx: nvsync_ctx_t, index: u32, out_buf: [*]u8, buf_len: u32) nvsync_result_t {
    const context: *Context = @ptrCast(@alignCast(ctx orelse return .error_invalid_handle));
    if (buf_len == 0) return .error_invalid_param;

    const display = context.display_manager.get(index) orelse return .error_display_not_found;

    const range_str = std.fmt.bufPrint(
        out_buf[0..buf_len],
        "{d}-{d}Hz",
        .{ display.min_hz, display.max_hz },
    ) catch {
        out_buf[0] = 0;
        return .error_unknown;
    };

    // Null terminate
    if (range_str.len < buf_len) {
        out_buf[range_str.len] = 0;
    }

    return .success;
}

// =============================================================================
// Tests
// =============================================================================

test "C API context lifecycle" {
    const ctx = nvsync_init();
    try std.testing.expect(ctx != null);
    defer nvsync_destroy(ctx);

    const version = nvsync_get_version();
    try std.testing.expect(version > 0);
}

test "C API scan and status" {
    const ctx = nvsync_init();
    try std.testing.expect(ctx != null);
    defer nvsync_destroy(ctx);

    const result = nvsync_scan(ctx);
    try std.testing.expectEqual(nvsync_result_t.success, result);

    var status: nvsync_status_t = undefined;
    const status_result = nvsync_get_status(ctx, &status);
    try std.testing.expectEqual(nvsync_result_t.success, status_result);
}
