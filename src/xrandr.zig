//! X11 Display Queries via XRandR
//!
//! Query display information and modes via xrandr command-line tool.
//! Works on X11 with any driver (NVIDIA, AMD, Intel).

const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const process = std.process;

/// Display connection state
pub const ConnectionState = enum {
    connected,
    disconnected,
    unknown,
};

/// Display mode (resolution + refresh rate)
pub const DisplayMode = struct {
    width: u32,
    height: u32,
    refresh_rate: f32,
    is_current: bool,
    is_preferred: bool,
    is_interlaced: bool,
};

/// X11 display output info
pub const XrandrOutput = struct {
    allocator: mem.Allocator,
    name: []const u8,
    connection: ConnectionState,
    is_primary: bool,
    width: u32,
    height: u32,
    x: i32,
    y: i32,
    current_refresh: f32,
    modes: std.ArrayListUnmanaged(DisplayMode),

    pub fn deinit(self: *XrandrOutput) void {
        self.allocator.free(self.name);
        self.modes.deinit(self.allocator);
    }

    pub fn getCurrentModeString(self: *const XrandrOutput) ![]const u8 {
        var buf: [64]u8 = undefined;
        return std.fmt.bufPrint(&buf, "{d}x{d}@{d:.2}Hz", .{
            self.width,
            self.height,
            self.current_refresh,
        }) catch return "unknown";
    }
};

/// XRandR display controller
pub const XrandrController = struct {
    allocator: mem.Allocator,
    outputs: std.ArrayListUnmanaged(XrandrOutput),
    screen_width: u32,
    screen_height: u32,

    pub fn init(allocator: mem.Allocator) XrandrController {
        return .{
            .allocator = allocator,
            .outputs = .empty,
            .screen_width = 0,
            .screen_height = 0,
        };
    }

    pub fn deinit(self: *XrandrController) void {
        for (self.outputs.items) |*o| {
            o.deinit();
        }
        self.outputs.deinit(self.allocator);
    }

    /// Check if running on X11
    pub fn isX11() bool {
        // Check DISPLAY environment variable
        return std.c.getenv("DISPLAY") != null and
            std.c.getenv("WAYLAND_DISPLAY") == null;
    }

    /// Query all outputs via xrandr
    pub fn query(self: *XrandrController) !void {
        const io = Io.Threaded.global_single_threaded.io();
        const result = process.run(self.allocator, io, .{
            .argv = &[_][]const u8{ "xrandr", "--query" },
        }) catch return error.XrandrNotFound;

        defer self.allocator.free(result.stderr);

        if (result.term != .exited or result.term.exited != 0) {
            self.allocator.free(result.stdout);
            return error.XrandrFailed;
        }

        // Parse xrandr output
        try self.parseOutput(result.stdout);
        self.allocator.free(result.stdout);
    }

    /// Parse xrandr --query output
    fn parseOutput(self: *XrandrController, output: []const u8) !void {
        var lines = mem.splitScalar(u8, output, '\n');
        var current_output: ?*XrandrOutput = null;

        while (lines.next()) |line| {
            if (line.len == 0) continue;

            // Screen line: "Screen 0: minimum 8 x 8, current 3840 x 1080, maximum 32767 x 32767"
            if (mem.startsWith(u8, line, "Screen ")) {
                // Parse screen dimensions
                if (mem.indexOf(u8, line, "current ")) |curr_idx| {
                    const after_current = line[curr_idx + 8 ..];
                    var parts = mem.splitAny(u8, after_current, " x,");
                    if (parts.next()) |w| {
                        self.screen_width = std.fmt.parseInt(u32, w, 10) catch 0;
                    }
                    if (parts.next()) |h| {
                        self.screen_height = std.fmt.parseInt(u32, h, 10) catch 0;
                    }
                }
                continue;
            }

            // Output line: "DP-2 connected primary 1920x1080+0+0 (...)"
            // or: "HDMI-0 disconnected (normal left inverted right x axis y axis)"
            if (!mem.startsWith(u8, line, " ") and !mem.startsWith(u8, line, "\t")) {
                var parts = mem.splitScalar(u8, line, ' ');
                const name = parts.next() orelse continue;

                // Skip if it's a Screen line or other header
                if (mem.eql(u8, name, "Screen") or name.len == 0) continue;

                const state_str = parts.next() orelse continue;
                const connection = if (mem.eql(u8, state_str, "connected"))
                    ConnectionState.connected
                else if (mem.eql(u8, state_str, "disconnected"))
                    ConnectionState.disconnected
                else
                    ConnectionState.unknown;

                var new_output = XrandrOutput{
                    .allocator = self.allocator,
                    .name = try self.allocator.dupe(u8, name),
                    .connection = connection,
                    .is_primary = false,
                    .width = 0,
                    .height = 0,
                    .x = 0,
                    .y = 0,
                    .current_refresh = 0,
                    .modes = .empty,
                };

                // Parse remaining parts for connected outputs
                if (connection == .connected) {
                    while (parts.next()) |part| {
                        if (mem.eql(u8, part, "primary")) {
                            new_output.is_primary = true;
                        } else if (mem.indexOf(u8, part, "x") != null and mem.indexOf(u8, part, "+") != null) {
                            // Resolution+position: "1920x1080+0+0"
                            self.parseResolutionPosition(part, &new_output);
                        }
                    }
                }

                try self.outputs.append(self.allocator, new_output);
                current_output = &self.outputs.items[self.outputs.items.len - 1];
            }
            // Mode line: "   1920x1080     60.00*+  50.00    59.94"
            else if (current_output != null and (mem.startsWith(u8, line, "   ") or mem.startsWith(u8, line, "\t"))) {
                const trimmed = mem.trimLeft(u8, line, " \t");
                if (trimmed.len == 0) continue;

                // Skip if starts with letter (other info like rotation)
                if (trimmed[0] >= 'A' and trimmed[0] <= 'z') continue;

                try self.parseModeLine(trimmed, current_output.?);
            }
        }
    }

    fn parseResolutionPosition(self: *XrandrController, part: []const u8, output: *XrandrOutput) void {
        _ = self;
        // Parse "1920x1080+0+0"
        var iter = mem.tokenizeAny(u8, part, "x+");
        if (iter.next()) |w| {
            output.width = std.fmt.parseInt(u32, w, 10) catch 0;
        }
        if (iter.next()) |h| {
            output.height = std.fmt.parseInt(u32, h, 10) catch 0;
        }
        if (iter.next()) |x| {
            output.x = std.fmt.parseInt(i32, x, 10) catch 0;
        }
        if (iter.next()) |y| {
            output.y = std.fmt.parseInt(i32, y, 10) catch 0;
        }
    }

    fn parseModeLine(self: *XrandrController, line: []const u8, output: *XrandrOutput) !void {
        _ = self;
        // Parse "1920x1080     60.00*+  50.00    59.94"
        var parts = mem.tokenizeAny(u8, line, " \t");

        const res = parts.next() orelse return;

        // Parse resolution
        var res_iter = mem.splitScalar(u8, res, 'x');
        const width = std.fmt.parseInt(u32, res_iter.next() orelse return, 10) catch return;
        const height_str = res_iter.next() orelse return;
        // Height may have 'i' suffix for interlaced
        const is_interlaced = mem.endsWith(u8, height_str, "i");
        const height_clean = if (is_interlaced) height_str[0 .. height_str.len - 1] else height_str;
        const height = std.fmt.parseInt(u32, height_clean, 10) catch return;

        // Parse refresh rates
        while (parts.next()) |rate_str| {
            if (rate_str.len == 0) continue;

            // Check for current (*) and preferred (+) markers
            var clean_rate = rate_str;
            var is_current = false;
            var is_preferred = false;

            if (mem.indexOf(u8, rate_str, "*")) |_| {
                is_current = true;
                clean_rate = mem.trim(u8, clean_rate, "*");
            }
            if (mem.indexOf(u8, rate_str, "+")) |_| {
                is_preferred = true;
                clean_rate = mem.trim(u8, clean_rate, "+");
            }

            const refresh = std.fmt.parseFloat(f32, clean_rate) catch continue;

            const mode = DisplayMode{
                .width = width,
                .height = height,
                .refresh_rate = refresh,
                .is_current = is_current,
                .is_preferred = is_preferred,
                .is_interlaced = is_interlaced,
            };

            try output.modes.append(output.allocator, mode);

            // Update current refresh if this is the current mode
            if (is_current) {
                output.current_refresh = refresh;
            }
        }
    }

    /// Get output by name
    pub fn getOutput(self: *XrandrController, name: []const u8) ?*XrandrOutput {
        for (self.outputs.items) |*o| {
            if (mem.eql(u8, o.name, name)) {
                return o;
            }
        }
        return null;
    }

    /// Get primary output
    pub fn getPrimary(self: *XrandrController) ?*XrandrOutput {
        for (self.outputs.items) |*o| {
            if (o.is_primary) {
                return o;
            }
        }
        // Return first connected if no primary
        for (self.outputs.items) |*o| {
            if (o.connection == .connected) {
                return o;
            }
        }
        return null;
    }

    /// Set display mode (resolution + refresh rate)
    pub fn setMode(self: *XrandrController, output_name: []const u8, width: u32, height: u32, refresh: f32) !void {
        var mode_buf: [64]u8 = undefined;
        const mode = std.fmt.bufPrint(&mode_buf, "{d}x{d}", .{ width, height }) catch return error.BufferError;

        var rate_buf: [16]u8 = undefined;
        const rate = std.fmt.bufPrint(&rate_buf, "{d:.2}", .{refresh}) catch return error.BufferError;

        const io = Io.Threaded.global_single_threaded.io();
        const result = process.run(self.allocator, io, .{
            .argv = &[_][]const u8{ "xrandr", "--output", output_name, "--mode", mode, "--rate", rate },
        }) catch return error.CommandFailed;

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term != .exited or result.term.exited != 0) {
            return error.SetModeFailed;
        }
    }

    /// Set output as primary
    pub fn setPrimary(self: *XrandrController, output_name: []const u8) !void {
        const io = Io.Threaded.global_single_threaded.io();
        const result = process.run(self.allocator, io, .{
            .argv = &[_][]const u8{ "xrandr", "--output", output_name, "--primary" },
        }) catch return error.CommandFailed;

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term != .exited or result.term.exited != 0) {
            return error.SetPrimaryFailed;
        }
    }

    /// Turn output off
    pub fn turnOff(self: *XrandrController, output_name: []const u8) !void {
        const io = Io.Threaded.global_single_threaded.io();
        const result = process.run(self.allocator, io, .{
            .argv = &[_][]const u8{ "xrandr", "--output", output_name, "--off" },
        }) catch return error.CommandFailed;

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
    }

    /// Get all available refresh rates for a resolution
    pub fn getRefreshRates(self: *XrandrController, output_name: []const u8, width: u32, height: u32) ![]f32 {
        const output = self.getOutput(output_name) orelse return error.OutputNotFound;

        var rates = std.ArrayList(f32).init(self.allocator);
        defer rates.deinit();

        for (output.modes.items) |mode| {
            if (mode.width == width and mode.height == height) {
                try rates.append(mode.refresh_rate);
            }
        }

        return try rates.toOwnedSlice();
    }

    /// Get maximum refresh rate for current resolution
    pub fn getMaxRefresh(self: *XrandrController, output_name: []const u8) ?f32 {
        const output = self.getOutput(output_name) orelse return null;
        if (output.width == 0 or output.height == 0) return null;

        var max: f32 = 0;
        for (output.modes.items) |mode| {
            if (mode.width == output.width and mode.height == output.height) {
                if (mode.refresh_rate > max) {
                    max = mode.refresh_rate;
                }
            }
        }

        return if (max > 0) max else null;
    }
};

/// Check if xrandr is available
pub fn isAvailable() bool {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const allocator = debug_alloc.allocator();

    const io = Io.Threaded.global_single_threaded.io();
    const result = process.run(allocator, io, .{
        .argv = &[_][]const u8{ "xrandr", "--version" },
    }) catch return false;

    allocator.free(result.stdout);
    allocator.free(result.stderr);

    return result.term == .exited and result.term.exited == 0;
}

// =============================================================================
// Tests
// =============================================================================

test "XrandrController init/deinit" {
    var ctrl = XrandrController.init(std.testing.allocator);
    defer ctrl.deinit();

    try std.testing.expect(ctrl.outputs.items.len == 0);
}

test "isX11 detection" {
    // Just ensure it doesn't crash
    _ = XrandrController.isX11();
}

test "ConnectionState" {
    try std.testing.expectEqual(ConnectionState.connected, ConnectionState.connected);
}
