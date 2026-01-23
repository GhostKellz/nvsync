//! Game Profile Management for nvsync
//!
//! Provides per-game VRR and frame limiting configuration.
//! Profiles are stored in JSON format at ~/.config/nvsync/profiles.json

const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const json = std.json;
const posix = std.posix;
const Io = std.Io;
const Dir = Io.Dir;

const nvsync = @import("root.zig");

/// A game profile configuration
pub const GameProfile = struct {
    /// Profile name (usually game name)
    name: []const u8,
    /// Executable name to match (e.g., "cyberpunk2077.exe")
    executable: []const u8,
    /// VRR mode for this game
    vrr_mode: nvsync.VrrMode,
    /// Frame limit (0 = unlimited)
    frame_limit: u32,
    /// Force G-Sync even if not auto-detected
    force_gsync: bool,
    /// Enable Low Framerate Compensation
    lfc_enabled: bool,
    /// Notes/comments
    notes: []const u8,

    pub fn deinit(self: *GameProfile, allocator: mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.executable);
        allocator.free(self.notes);
    }
};

/// Profile manager handles loading, saving, and matching profiles
pub const ProfileManager = struct {
    allocator: mem.Allocator,
    profiles: std.StringHashMap(GameProfile),
    config_path: []const u8,
    modified: bool,

    const Self = @This();

    /// Default config directory
    const CONFIG_DIR = ".config/nvsync";
    const CONFIG_FILE = "profiles.json";

    /// Initialize profile manager
    pub fn init(allocator: mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .profiles = std.StringHashMap(GameProfile).init(allocator),
            .config_path = "",
            .modified = false,
        };
    }

    /// Deinitialize and free all resources
    pub fn deinit(self: *Self) void {
        var iter = self.profiles.iterator();
        while (iter.next()) |entry| {
            var profile = entry.value_ptr.*;
            profile.deinit(self.allocator);
        }
        self.profiles.deinit();
        if (self.config_path.len > 0) {
            self.allocator.free(self.config_path);
        }
    }

    /// Get the config file path
    pub fn getConfigPath(self: *Self) ![]const u8 {
        if (self.config_path.len > 0) return self.config_path;

        // Get home directory
        const home_ptr = std.c.getenv("HOME") orelse std.c.getenv("XDG_CONFIG_HOME") orelse return error.NoHomeDir;
        const home_str = mem.sliceTo(home_ptr, 0);

        // Build path: $HOME/.config/nvsync/profiles.json
        self.config_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/{s}",
            .{ home_str, CONFIG_DIR, CONFIG_FILE },
        );

        return self.config_path;
    }

    /// Ensure config directory exists
    fn ensureConfigDir(self: *Self) !void {
        const home_ptr = std.c.getenv("HOME") orelse return error.NoHomeDir;
        const home_str = mem.sliceTo(home_ptr, 0);

        var path_buf: [512]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home_str, CONFIG_DIR }) catch return error.PathTooLong;

        // Create directory using Zig 0.16 Dir API
        const io = Io.Threaded.global_single_threaded.io();
        Dir.cwd().createDirPath(io, dir_path) catch |err| {
            // Ignore if directory already exists
            if (err != error.PathAlreadyExists) {
                return error.MkdirFailed;
            }
        };

        _ = self;
    }

    /// Load profiles from config file
    pub fn load(self: *Self) !void {
        const path = try self.getConfigPath();
        const io = Io.Threaded.global_single_threaded.io();

        const file = Dir.cwd().openFile(io, path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // No config file yet, that's OK
                return;
            }
            return err;
        };
        defer file.close(io);

        // Read file content
        var buf: [64 * 1024]u8 = undefined; // 64KB max
        const len = posix.read(file.handle, &buf) catch return error.ReadFailed;
        const content = buf[0..len];

        // Parse JSON
        try self.parseJson(content);
    }

    fn parseJson(self: *Self, content: []const u8) !void {
        var parsed = json.parseFromSlice(json.Value, self.allocator, content, .{}) catch return error.ParseFailed;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidFormat;

        const profiles_val = root.object.get("profiles") orelse return;
        if (profiles_val != .array) return error.InvalidFormat;

        for (profiles_val.array.items) |item| {
            if (item != .object) continue;

            const obj = item.object;

            const name = obj.get("name") orelse continue;
            const executable = obj.get("executable") orelse continue;

            if (name != .string or executable != .string) continue;

            const profile = GameProfile{
                .name = self.allocator.dupe(u8, name.string) catch continue,
                .executable = self.allocator.dupe(u8, executable.string) catch continue,
                .vrr_mode = blk: {
                    const vrr = obj.get("vrr_mode") orelse break :blk .gsync_compatible;
                    if (vrr != .string) break :blk .gsync_compatible;
                    break :blk if (mem.eql(u8, vrr.string, "off"))
                        .off
                    else if (mem.eql(u8, vrr.string, "gsync"))
                        .gsync
                    else if (mem.eql(u8, vrr.string, "vrr"))
                        .vrr
                    else
                        .gsync_compatible;
                },
                .frame_limit = blk: {
                    const fps = obj.get("frame_limit") orelse break :blk 0;
                    if (fps != .integer) break :blk 0;
                    break :blk @intCast(@max(0, fps.integer));
                },
                .force_gsync = blk: {
                    const force = obj.get("force_gsync") orelse break :blk false;
                    break :blk force == .bool and force.bool;
                },
                .lfc_enabled = blk: {
                    const lfc = obj.get("lfc_enabled") orelse break :blk true;
                    break :blk lfc != .bool or lfc.bool;
                },
                .notes = blk: {
                    const notes = obj.get("notes") orelse break :blk self.allocator.dupe(u8, "") catch "";
                    if (notes != .string) break :blk self.allocator.dupe(u8, "") catch "";
                    break :blk self.allocator.dupe(u8, notes.string) catch "";
                },
            };

            self.profiles.put(profile.executable, profile) catch continue;
        }
    }

    /// Save profiles to config file
    pub fn save(self: *Self) !void {
        try self.ensureConfigDir();
        const path = try self.getConfigPath();

        // Build JSON content using allocPrint
        var json_content = std.ArrayList(u8).empty;
        defer json_content.deinit(self.allocator);

        // Header
        try json_content.appendSlice(self.allocator, "{\n  \"version\": 1,\n  \"profiles\": [\n");

        var first = true;
        var iter = self.profiles.iterator();
        while (iter.next()) |entry| {
            const profile = entry.value_ptr.*;

            if (!first) try json_content.appendSlice(self.allocator, ",\n");
            first = false;

            // Build profile JSON
            const profile_json = std.fmt.allocPrint(self.allocator,
                \\    {{
                \\      "name": "{s}",
                \\      "executable": "{s}",
                \\      "vrr_mode": "{s}",
                \\      "frame_limit": {d},
                \\      "force_gsync": {s},
                \\      "lfc_enabled": {s},
                \\      "notes": "{s}"
                \\    }}
            , .{
                profile.name,
                profile.executable,
                profile.vrr_mode.name(),
                profile.frame_limit,
                if (profile.force_gsync) "true" else "false",
                if (profile.lfc_enabled) "true" else "false",
                profile.notes,
            }) catch return error.OutOfMemory;
            defer self.allocator.free(profile_json);

            try json_content.appendSlice(self.allocator, profile_json);
        }

        try json_content.appendSlice(self.allocator, "\n  ]\n}\n");

        // Write to file using Zig 0.16 Io API
        const io = Io.Threaded.global_single_threaded.io();

        // Open file for writing (create if not exists)
        var file = Dir.cwd().createFile(io, path, .{}) catch return error.WriteFailed;
        defer file.close(io);

        // Write the content using writeStreamingAll
        file.writeStreamingAll(io, json_content.items) catch return error.WriteFailed;

        self.modified = false;
    }

    /// Get profile for a process name
    pub fn getForProcess(self: *Self, process_name: []const u8) ?*GameProfile {
        // Exact match first
        if (self.profiles.getPtr(process_name)) |profile| {
            return profile;
        }

        // Try case-insensitive match
        var iter = self.profiles.iterator();
        while (iter.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, process_name)) {
                return entry.value_ptr;
            }
        }

        return null;
    }

    /// Add or update a profile
    pub fn set(self: *Self, profile: GameProfile) !void {
        // Remove existing if present
        if (self.profiles.fetchRemove(profile.executable)) |removed| {
            var p = removed.value;
            p.deinit(self.allocator);
        }

        try self.profiles.put(profile.executable, profile);
        self.modified = true;
    }

    /// Remove a profile
    pub fn remove(self: *Self, executable: []const u8) bool {
        if (self.profiles.fetchRemove(executable)) |removed| {
            var p = removed.value;
            p.deinit(self.allocator);
            self.modified = true;
            return true;
        }
        return false;
    }

    /// Get number of profiles
    pub fn count(self: *const Self) usize {
        return self.profiles.count();
    }

    /// List all profiles (returns iterator)
    pub fn list(self: *Self) std.StringHashMap(GameProfile).Iterator {
        return self.profiles.iterator();
    }
};

/// Create a default profile for common games
pub fn createDefaultProfiles(allocator: mem.Allocator) !std.ArrayListUnmanaged(GameProfile) {
    var profiles: std.ArrayListUnmanaged(GameProfile) = .empty;

    // Cyberpunk 2077 - benefits from frame limiting for consistent frame pacing
    try profiles.append(allocator, .{
        .name = try allocator.dupe(u8, "Cyberpunk 2077"),
        .executable = try allocator.dupe(u8, "Cyberpunk2077.exe"),
        .vrr_mode = .gsync_compatible,
        .frame_limit = 0, // Let user decide
        .force_gsync = false,
        .lfc_enabled = true,
        .notes = try allocator.dupe(u8, "Enable DLSS for best performance"),
    });

    // Counter-Strike 2 - competitive, want low latency
    try profiles.append(allocator, .{
        .name = try allocator.dupe(u8, "Counter-Strike 2"),
        .executable = try allocator.dupe(u8, "cs2.exe"),
        .vrr_mode = .gsync_compatible,
        .frame_limit = 0, // Uncapped for competitive
        .force_gsync = false,
        .lfc_enabled = false, // Don't want LFC in competitive
        .notes = try allocator.dupe(u8, "Competitive: use highest refresh rate"),
    });

    // Baldur's Gate 3 - RPG, 60fps is fine
    try profiles.append(allocator, .{
        .name = try allocator.dupe(u8, "Baldur's Gate 3"),
        .executable = try allocator.dupe(u8, "bg3.exe"),
        .vrr_mode = .gsync_compatible,
        .frame_limit = 60,
        .force_gsync = false,
        .lfc_enabled = true,
        .notes = try allocator.dupe(u8, "RPG - 60fps provides good experience"),
    });

    return profiles;
}

// =============================================================================
// Tests
// =============================================================================

test "ProfileManager init/deinit" {
    var manager = ProfileManager.init(std.testing.allocator);
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 0), manager.count());
}

test "GameProfile creation" {
    const allocator = std.testing.allocator;

    var profile = GameProfile{
        .name = try allocator.dupe(u8, "Test Game"),
        .executable = try allocator.dupe(u8, "test.exe"),
        .vrr_mode = .gsync_compatible,
        .frame_limit = 144,
        .force_gsync = false,
        .lfc_enabled = true,
        .notes = try allocator.dupe(u8, "Test notes"),
    };
    defer profile.deinit(allocator);

    try std.testing.expectEqualStrings("Test Game", profile.name);
    try std.testing.expectEqual(@as(u32, 144), profile.frame_limit);
}
