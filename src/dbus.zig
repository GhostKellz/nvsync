//! D-Bus Interface for Compositor VRR Control
//!
//! Direct D-Bus communication with KWin and Mutter for VRR control.
//! Provides lower-level access than CLI wrappers.
//!
//! D-Bus Services:
//! - KWin: org.kde.kscreen, org.kde.KWin
//! - Mutter: org.gnome.Mutter.DisplayConfig

const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const Io = std.Io;
const process = std.process;

// =============================================================================
// D-Bus Connection
// =============================================================================

/// D-Bus bus type
pub const BusType = enum {
    session, // User session bus (compositors)
    system, // System bus (hardware events)

    pub fn envVar(self: BusType) []const u8 {
        return switch (self) {
            .session => "DBUS_SESSION_BUS_ADDRESS",
            .system => "DBUS_SYSTEM_BUS_ADDRESS",
        };
    }
};

/// Result from a D-Bus method call
pub const DBusResult = struct {
    success: bool,
    stdout: []const u8,
    stderr: []const u8,
    allocator: mem.Allocator,

    pub fn deinit(self: *DBusResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }

    pub fn getValue(self: *const DBusResult) ?[]const u8 {
        if (!self.success) return null;
        return mem.trim(u8, self.stdout, &[_]u8{ '\n', '\r', ' ', '\t' });
    }
};

/// D-Bus method call helper using gdbus
pub fn callMethod(
    allocator: mem.Allocator,
    bus: BusType,
    destination: []const u8,
    object_path: []const u8,
    interface: []const u8,
    method: []const u8,
    args: ?[]const u8,
) !DBusResult {
    var argv_buf: [16][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "gdbus";
    argc += 1;
    argv_buf[argc] = "call";
    argc += 1;

    argv_buf[argc] = switch (bus) {
        .session => "--session",
        .system => "--system",
    };
    argc += 1;

    argv_buf[argc] = "--dest";
    argc += 1;
    argv_buf[argc] = destination;
    argc += 1;

    argv_buf[argc] = "--object-path";
    argc += 1;
    argv_buf[argc] = object_path;
    argc += 1;

    argv_buf[argc] = "--method";
    argc += 1;

    // Build method signature
    var method_buf: [256]u8 = undefined;
    const method_full = std.fmt.bufPrint(&method_buf, "{s}.{s}", .{ interface, method }) catch return error.BufferError;
    argv_buf[argc] = method_full;
    argc += 1;

    if (args) |a| {
        argv_buf[argc] = a;
        argc += 1;
    }

    const io = Io.Threaded.global_single_threaded.io();
    const result = process.run(allocator, io, .{
        .argv = argv_buf[0..argc],
    }) catch |err| {
        std.log.debug("D-Bus call failed: {}", .{err});
        return error.DBusCallFailed;
    };

    return DBusResult{
        .success = result.term == .exited and result.term.exited == 0,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .allocator = allocator,
    };
}

/// D-Bus property getter using gdbus
pub fn getProperty(
    allocator: mem.Allocator,
    bus: BusType,
    destination: []const u8,
    object_path: []const u8,
    interface: []const u8,
    property: []const u8,
) !DBusResult {
    const io = Io.Threaded.global_single_threaded.io();
    const result = process.run(allocator, io, .{
        .argv = &[_][]const u8{
            "gdbus",
            "call",
            switch (bus) {
                .session => "--session",
                .system => "--system",
            },
            "--dest",
            destination,
            "--object-path",
            object_path,
            "--method",
            "org.freedesktop.DBus.Properties.Get",
            interface,
            property,
        },
    }) catch return error.DBusCallFailed;

    return DBusResult{
        .success = result.term == .exited and result.term.exited == 0,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .allocator = allocator,
    };
}

// =============================================================================
// KWin D-Bus Interface
// =============================================================================

pub const KWinDBus = struct {
    allocator: mem.Allocator,

    // D-Bus service names
    const KSCREEN_SERVICE = "org.kde.kscreen";
    const KSCREEN_PATH = "/org/kde/kscreen";
    const KSCREEN_INTERFACE = "org.kde.kscreen";

    const KWIN_SERVICE = "org.kde.KWin";
    const KWIN_PATH = "/org/kde/KWin";
    const KWIN_INTERFACE = "org.kde.KWin";

    const OUTPUTS_PATH = "/org/kde/kscreen/outputs";
    const OUTPUT_INTERFACE = "org.kde.kscreen.Output";

    pub fn init(allocator: mem.Allocator) KWinDBus {
        return .{ .allocator = allocator };
    }

    /// Check if KWin D-Bus is available
    pub fn isAvailable(self: *KWinDBus) bool {
        var result = callMethod(
            self.allocator,
            .session,
            KWIN_SERVICE,
            KWIN_PATH,
            "org.freedesktop.DBus.Peer",
            "Ping",
            null,
        ) catch return false;
        defer result.deinit();
        return result.success;
    }

    /// Get KWin compositor version
    pub fn getVersion(self: *KWinDBus) ![]const u8 {
        var result = try getProperty(
            self.allocator,
            .session,
            KWIN_SERVICE,
            KWIN_PATH,
            KWIN_INTERFACE,
            "supportInformation",
        );
        // Don't deinit - caller owns the memory
        if (result.success) {
            return result.stdout;
        }
        result.deinit();
        return error.PropertyGetFailed;
    }

    /// Get list of output names via kscreen D-Bus
    pub fn getOutputs(self: *KWinDBus) ![]const u8 {
        var result = try callMethod(
            self.allocator,
            .session,
            KSCREEN_SERVICE,
            KSCREEN_PATH,
            KSCREEN_INTERFACE,
            "outputs",
            null,
        );
        if (result.success) {
            return result.stdout;
        }
        result.deinit();
        return error.MethodCallFailed;
    }

    /// Set VRR on an output via D-Bus property
    pub fn setOutputVrr(self: *KWinDBus, output_id: u32, enabled: bool) !void {
        var path_buf: [128]u8 = undefined;
        const output_path = std.fmt.bufPrint(&path_buf, "{s}/{d}", .{ OUTPUTS_PATH, output_id }) catch return error.BufferError;

        var arg_buf: [64]u8 = undefined;
        const args = std.fmt.bufPrint(&arg_buf, "'org.kde.kscreen.Output' 'vrr' '<{s}>'", .{
            if (enabled) "true" else "false",
        }) catch return error.BufferError;

        var result = try callMethod(
            self.allocator,
            .session,
            KSCREEN_SERVICE,
            output_path,
            "org.freedesktop.DBus.Properties",
            "Set",
            args,
        );
        defer result.deinit();

        if (!result.success) {
            return error.SetPropertyFailed;
        }
    }

    /// Request compositor reconfiguration
    pub fn reconfigure(self: *KWinDBus) !void {
        var result = try callMethod(
            self.allocator,
            .session,
            KWIN_SERVICE,
            KWIN_PATH,
            KWIN_INTERFACE,
            "reconfigure",
            null,
        );
        defer result.deinit();
    }

    /// Get VRR status for an output
    pub fn getOutputVrrStatus(self: *KWinDBus, output_id: u32) !bool {
        var path_buf: [128]u8 = undefined;
        const output_path = std.fmt.bufPrint(&path_buf, "{s}/{d}", .{ OUTPUTS_PATH, output_id }) catch return error.BufferError;

        var result = try getProperty(
            self.allocator,
            .session,
            KSCREEN_SERVICE,
            output_path,
            OUTPUT_INTERFACE,
            "vrr",
        );
        defer result.deinit();

        if (result.success) {
            const value = result.getValue() orelse return false;
            return mem.indexOf(u8, value, "true") != null;
        }
        return false;
    }
};

// =============================================================================
// Mutter D-Bus Interface
// =============================================================================

pub const MutterDBus = struct {
    allocator: mem.Allocator,

    // D-Bus service names
    const DISPLAY_CONFIG_SERVICE = "org.gnome.Mutter.DisplayConfig";
    const DISPLAY_CONFIG_PATH = "/org/gnome/Mutter/DisplayConfig";
    const DISPLAY_CONFIG_INTERFACE = "org.gnome.Mutter.DisplayConfig";

    const MUTTER_SERVICE = "org.gnome.Shell";
    const MUTTER_PATH = "/org/gnome/Shell";

    pub fn init(allocator: mem.Allocator) MutterDBus {
        return .{ .allocator = allocator };
    }

    /// Check if Mutter D-Bus is available
    pub fn isAvailable(self: *MutterDBus) bool {
        var result = callMethod(
            self.allocator,
            .session,
            DISPLAY_CONFIG_SERVICE,
            DISPLAY_CONFIG_PATH,
            "org.freedesktop.DBus.Peer",
            "Ping",
            null,
        ) catch return false;
        defer result.deinit();
        return result.success;
    }

    /// Get current display configuration state
    pub fn getCurrentState(self: *MutterDBus) ![]const u8 {
        var result = try callMethod(
            self.allocator,
            .session,
            DISPLAY_CONFIG_SERVICE,
            DISPLAY_CONFIG_PATH,
            DISPLAY_CONFIG_INTERFACE,
            "GetCurrentState",
            null,
        );
        if (result.success) {
            return result.stdout;
        }
        result.deinit();
        return error.MethodCallFailed;
    }

    /// Get resources (monitors, modes, etc.)
    pub fn getResources(self: *MutterDBus) ![]const u8 {
        var result = try callMethod(
            self.allocator,
            .session,
            DISPLAY_CONFIG_SERVICE,
            DISPLAY_CONFIG_PATH,
            DISPLAY_CONFIG_INTERFACE,
            "GetResources",
            null,
        );
        if (result.success) {
            return result.stdout;
        }
        result.deinit();
        return error.MethodCallFailed;
    }

    /// Apply monitors configuration
    /// Note: This is a complex D-Bus call that requires serialized monitor config
    pub fn applyMonitorsConfig(
        self: *MutterDBus,
        serial: u32,
        method: ApplyMethod,
        logical_monitors: []const u8,
        properties: []const u8,
    ) !void {
        var arg_buf: [2048]u8 = undefined;
        const args = std.fmt.bufPrint(&arg_buf, "uint32:{d} uint32:{d} {s} {s}", .{
            serial,
            @intFromEnum(method),
            logical_monitors,
            properties,
        }) catch return error.BufferError;

        var result = try callMethod(
            self.allocator,
            .session,
            DISPLAY_CONFIG_SERVICE,
            DISPLAY_CONFIG_PATH,
            DISPLAY_CONFIG_INTERFACE,
            "ApplyMonitorsConfig",
            args,
        );
        defer result.deinit();

        if (!result.success) {
            return error.ApplyConfigFailed;
        }
    }

    /// Monitor apply method
    pub const ApplyMethod = enum(u32) {
        verify = 0, // Just verify, don't apply
        temporary = 1, // Apply temporarily (reverts after timeout)
        permanent = 2, // Apply permanently
    };

    /// Enable VRR feature via gsettings (more reliable than D-Bus for this)
    pub fn enableVrrFeature(self: *MutterDBus) !void {
        const io = Io.Threaded.global_single_threaded.io();
        const result = process.run(self.allocator, io, .{
            .argv = &[_][]const u8{
                "gsettings",
                "set",
                "org.gnome.mutter",
                "experimental-features",
                "['variable-refresh-rate']",
            },
        }) catch return error.CommandFailed;

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term != .exited or result.term.exited != 0) {
            return error.SetFeatureFailed;
        }
    }

    /// Disable VRR feature
    pub fn disableVrrFeature(self: *MutterDBus) !void {
        const io = Io.Threaded.global_single_threaded.io();
        const result = process.run(self.allocator, io, .{
            .argv = &[_][]const u8{
                "gsettings",
                "set",
                "org.gnome.mutter",
                "experimental-features",
                "[]",
            },
        }) catch return error.CommandFailed;

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
    }

    /// Check if VRR feature is enabled
    pub fn isVrrFeatureEnabled(self: *MutterDBus) !bool {
        const io = Io.Threaded.global_single_threaded.io();
        const result = process.run(self.allocator, io, .{
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

    /// Get GNOME Shell version
    pub fn getShellVersion(self: *MutterDBus) ![]const u8 {
        var result = try getProperty(
            self.allocator,
            .session,
            MUTTER_SERVICE,
            MUTTER_PATH,
            "org.gnome.Shell",
            "ShellVersion",
        );
        if (result.success) {
            return result.stdout;
        }
        result.deinit();
        return error.PropertyGetFailed;
    }
};

// =============================================================================
// Unified D-Bus VRR Controller
// =============================================================================

pub const DBusVrrController = struct {
    allocator: mem.Allocator,
    kwin: ?KWinDBus,
    mutter: ?MutterDBus,
    active_backend: ?Backend,

    pub const Backend = enum {
        kwin,
        mutter,
        none,
    };

    pub fn init(allocator: mem.Allocator) DBusVrrController {
        var ctrl = DBusVrrController{
            .allocator = allocator,
            .kwin = null,
            .mutter = null,
            .active_backend = null,
        };

        // Detect available backend
        var kwin = KWinDBus.init(allocator);
        if (kwin.isAvailable()) {
            ctrl.kwin = kwin;
            ctrl.active_backend = .kwin;
            return ctrl;
        }

        var mutter = MutterDBus.init(allocator);
        if (mutter.isAvailable()) {
            ctrl.mutter = mutter;
            ctrl.active_backend = .mutter;
            return ctrl;
        }

        ctrl.active_backend = .none;
        return ctrl;
    }

    /// Get active backend name
    pub fn getBackendName(self: *const DBusVrrController) []const u8 {
        return switch (self.active_backend orelse .none) {
            .kwin => "KWin (D-Bus)",
            .mutter => "Mutter (D-Bus)",
            .none => "None",
        };
    }

    /// Enable VRR on the specified output (or all outputs)
    pub fn enableVrr(self: *DBusVrrController, output_id: ?u32) !void {
        switch (self.active_backend orelse .none) {
            .kwin => {
                if (self.kwin) |*kwin| {
                    try kwin.setOutputVrr(output_id orelse 0, true);
                    try kwin.reconfigure();
                }
            },
            .mutter => {
                if (self.mutter) |*mutter| {
                    try mutter.enableVrrFeature();
                }
            },
            .none => return error.NoBackendAvailable,
        }
    }

    /// Disable VRR
    pub fn disableVrr(self: *DBusVrrController, output_id: ?u32) !void {
        switch (self.active_backend orelse .none) {
            .kwin => {
                if (self.kwin) |*kwin| {
                    try kwin.setOutputVrr(output_id orelse 0, false);
                    try kwin.reconfigure();
                }
            },
            .mutter => {
                if (self.mutter) |*mutter| {
                    try mutter.disableVrrFeature();
                }
            },
            .none => return error.NoBackendAvailable,
        }
    }

    /// Get VRR status
    pub fn isVrrEnabled(self: *DBusVrrController, output_id: ?u32) !bool {
        switch (self.active_backend orelse .none) {
            .kwin => {
                if (self.kwin) |*kwin| {
                    return kwin.getOutputVrrStatus(output_id orelse 0);
                }
            },
            .mutter => {
                if (self.mutter) |*mutter| {
                    return mutter.isVrrFeatureEnabled();
                }
            },
            .none => return false,
        }
        return false;
    }

    /// Get compositor info
    pub fn getCompositorInfo(self: *DBusVrrController) ![]const u8 {
        switch (self.active_backend orelse .none) {
            .kwin => {
                if (self.kwin) |*kwin| {
                    return kwin.getVersion();
                }
            },
            .mutter => {
                if (self.mutter) |*mutter| {
                    return mutter.getShellVersion();
                }
            },
            .none => return error.NoBackendAvailable,
        }
        return error.NoBackendAvailable;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "DBusResult value extraction" {
    var allocator = std.testing.allocator;
    var result = DBusResult{
        .success = true,
        .stdout = try allocator.dupe(u8, "  test_value\n"),
        .stderr = try allocator.dupe(u8, ""),
        .allocator = allocator,
    };
    defer result.deinit();

    const value = result.getValue();
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("test_value", value.?);
}

test "BusType envVar" {
    try std.testing.expectEqualStrings("DBUS_SESSION_BUS_ADDRESS", BusType.session.envVar());
    try std.testing.expectEqualStrings("DBUS_SYSTEM_BUS_ADDRESS", BusType.system.envVar());
}
