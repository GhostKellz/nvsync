//! nvsync Profile Auto-Switching Daemon
//!
//! Monitors running processes and automatically applies VRR/frame limit
//! profiles when games are detected. Designed for integration with nvprime.

const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const posix = std.posix;
const Io = std.Io;
const Dir = Io.Dir;

const nvsync = @import("root.zig");
const profiles = @import("profiles.zig");

/// Sleep for a given number of nanoseconds
fn sleepNs(ns: u64) void {
    const ts = std.c.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&ts, null);
}

/// Daemon state
pub const Daemon = struct {
    allocator: mem.Allocator,
    profile_manager: profiles.ProfileManager,
    display_manager: nvsync.DisplayManager,
    running: bool,
    poll_interval_ms: u32,
    active_profile: ?[]const u8,
    active_pid: ?i32,

    // Callbacks for external integration (nvprime)
    on_profile_applied: ?*const fn (profile: *const profiles.GameProfile) void,
    on_profile_cleared: ?*const fn () void,

    pub fn init(allocator: mem.Allocator) Daemon {
        return .{
            .allocator = allocator,
            .profile_manager = profiles.ProfileManager.init(allocator),
            .display_manager = nvsync.DisplayManager.init(allocator),
            .running = false,
            .poll_interval_ms = 2000, // Check every 2 seconds
            .active_profile = null,
            .active_pid = null,
            .on_profile_applied = null,
            .on_profile_cleared = null,
        };
    }

    pub fn deinit(self: *Daemon) void {
        self.stop();
        self.profile_manager.deinit();
        self.display_manager.deinit();
        if (self.active_profile) |p| {
            self.allocator.free(p);
        }
    }

    /// Start the daemon
    pub fn start(self: *Daemon) !void {
        if (self.running) return;

        // Load profiles
        try self.profile_manager.load();

        // Initial display scan
        try self.display_manager.scan();

        self.running = true;

        // Run the main loop
        while (self.running) {
            self.tick() catch |err| {
                std.debug.print("Daemon tick error: {}\n", .{err});
            };

            // Sleep for poll interval
            sleepNs(self.poll_interval_ms * std.time.ns_per_ms);
        }
    }

    /// Stop the daemon
    pub fn stop(self: *Daemon) void {
        self.running = false;

        // Clear any active profile
        if (self.active_profile != null) {
            self.clearActiveProfile();
        }
    }

    /// Single tick of the daemon loop
    pub fn tick(self: *Daemon) !void {
        // Check if active process is still running
        if (self.active_pid) |pid| {
            if (!self.isProcessRunning(pid)) {
                self.clearActiveProfile();
            }
        }

        // If no active profile, scan for matching processes
        if (self.active_profile == null) {
            try self.scanForGames();
        }
    }

    /// Scan running processes for games with profiles
    fn scanForGames(self: *Daemon) !void {
        const io = Io.Threaded.global_single_threaded.io();

        var proc_dir = Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch return;
        defer proc_dir.close(io);

        var iter = proc_dir.iterate();
        while (try iter.next(io)) |entry| {
            // Only look at numeric directories (PIDs)
            const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;

            // Read the process command line
            var path_buf: [256]u8 = undefined;
            const comm_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch continue;

            const comm_file = Dir.cwd().openFile(io, comm_path, .{}) catch continue;
            defer comm_file.close(io);

            var comm_buf: [256]u8 = undefined;
            const comm_len = posix.read(comm_file.handle, &comm_buf) catch continue;
            if (comm_len == 0) continue;

            const comm = mem.trim(u8, comm_buf[0..comm_len], &[_]u8{ '\n', '\r', ' ', 0 });

            // Check if we have a profile for this process
            if (self.profile_manager.getForProcess(comm)) |profile| {
                try self.applyProfile(profile, pid);
                return;
            }

            // Also check cmdline for full executable path
            const cmdline_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cmdline", .{pid}) catch continue;
            const cmdline_file = Dir.cwd().openFile(io, cmdline_path, .{}) catch continue;
            defer cmdline_file.close(io);

            var cmdline_buf: [1024]u8 = undefined;
            const cmdline_len = posix.read(cmdline_file.handle, &cmdline_buf) catch continue;
            if (cmdline_len == 0) continue;

            // cmdline is null-separated, get first arg (executable)
            const cmdline = cmdline_buf[0..cmdline_len];
            const exe_end = mem.indexOf(u8, cmdline, &[_]u8{0}) orelse cmdline_len;
            const exe_path = cmdline[0..exe_end];

            // Get basename
            const exe_name = if (mem.lastIndexOf(u8, exe_path, "/")) |idx|
                exe_path[idx + 1 ..]
            else
                exe_path;

            if (self.profile_manager.getForProcess(exe_name)) |profile| {
                try self.applyProfile(profile, pid);
                return;
            }
        }
    }

    /// Apply a game profile
    fn applyProfile(self: *Daemon, profile: *profiles.GameProfile, pid: i32) !void {
        std.debug.print("[nvsync] Applying profile: {s} (PID: {d})\n", .{ profile.name, pid });

        // Store active state
        self.active_profile = try self.allocator.dupe(u8, profile.executable);
        self.active_pid = pid;

        // Apply VRR settings
        if (profile.vrr_mode != .off) {
            if (profile.force_gsync) {
                // Force G-Sync on all displays
                self.display_manager.enableVrrAll() catch |err| {
                    std.debug.print("[nvsync] Failed to enable VRR: {}\n", .{err});
                };
            } else {
                // Enable on VRR-capable displays only
                for (self.display_manager.displays.items) |d| {
                    if (d.vrr_capable or d.gsync_compatible) {
                        self.display_manager.setVrrEnabled(d.name, true) catch continue;
                    }
                }
            }
        }

        // Frame limit is handled via environment variables by the caller (nvprime)
        // We just report the profile settings

        // Callback for external integration
        if (self.on_profile_applied) |callback| {
            callback(profile);
        }
    }

    /// Clear the active profile
    fn clearActiveProfile(self: *Daemon) void {
        if (self.active_profile) |p| {
            std.debug.print("[nvsync] Clearing profile: {s}\n", .{p});
            self.allocator.free(p);
            self.active_profile = null;
        }
        self.active_pid = null;

        // Callback for external integration
        if (self.on_profile_cleared) |callback| {
            callback();
        }
    }

    /// Check if a process is still running
    fn isProcessRunning(self: *Daemon, pid: i32) bool {
        _ = self;
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}", .{pid}) catch return false;

        const io = Io.Threaded.global_single_threaded.io();
        Dir.cwd().access(io, path, .{}) catch return false;
        return true;
    }

    /// Get current daemon status
    pub fn getStatus(self: *const Daemon) DaemonStatus {
        return .{
            .running = self.running,
            .active_profile = self.active_profile,
            .active_pid = self.active_pid,
            .profile_count = self.profile_manager.count(),
            .poll_interval_ms = self.poll_interval_ms,
        };
    }

    /// Set poll interval
    pub fn setPollInterval(self: *Daemon, ms: u32) void {
        self.poll_interval_ms = @max(500, @min(ms, 30000)); // 0.5s to 30s
    }
};

/// Daemon status for external queries
pub const DaemonStatus = struct {
    running: bool,
    active_profile: ?[]const u8,
    active_pid: ?i32,
    profile_count: usize,
    poll_interval_ms: u32,
};

/// Run daemon in background (forks)
pub fn runDaemonized(allocator: mem.Allocator) !void {
    // For proper daemonization, we'd fork and detach
    // For now, just run in foreground with a note
    std.debug.print("nvsync daemon starting (foreground mode)...\n", .{});
    std.debug.print("Press Ctrl+C to stop.\n", .{});

    var daemon = Daemon.init(allocator);
    defer daemon.deinit();

    try daemon.start();
}

/// Check once for matching profiles (non-blocking, for nvprime)
pub fn checkOnce(allocator: mem.Allocator, executable: []const u8) !?profiles.GameProfile {
    var pm = profiles.ProfileManager.init(allocator);
    defer pm.deinit();

    pm.load() catch return null;

    if (pm.getForProcess(executable)) |profile| {
        return profile.*;
    }

    return null;
}

/// Get environment variables for a profile (for nvprime to set)
pub fn getProfileEnvVars(profile: *const profiles.GameProfile) struct {
    frame_limit: ?u32,
    vrr_allowed: bool,
    gsync_allowed: bool,
} {
    return .{
        .frame_limit = if (profile.frame_limit > 0) profile.frame_limit else null,
        .vrr_allowed = profile.vrr_mode != .off,
        .gsync_allowed = profile.vrr_mode == .gsync or profile.force_gsync,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "Daemon init/deinit" {
    var daemon = Daemon.init(std.testing.allocator);
    defer daemon.deinit();

    try std.testing.expect(!daemon.running);
    try std.testing.expect(daemon.active_profile == null);
}

test "DaemonStatus" {
    var daemon = Daemon.init(std.testing.allocator);
    defer daemon.deinit();

    const status = daemon.getStatus();
    try std.testing.expect(!status.running);
    try std.testing.expectEqual(@as(u32, 2000), status.poll_interval_ms);
}
