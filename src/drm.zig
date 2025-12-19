//! DRM/KMS VRR Control
//!
//! Direct kernel mode setting interface for VRR control.
//! This provides the lowest-level VRR management.

const std = @import("std");
const posix = std.posix;
const fs = std.fs;
const mem = std.mem;

/// DRM device path
pub const DRM_DIR = "/dev/dri";
pub const DRM_SYS_DIR = "/sys/class/drm";

/// DRM connector VRR properties
pub const VrrProperty = enum {
    vrr_capable,
    vrr_enabled,
    max_bpc,
    content_type,
    hdr_output_metadata,

    pub fn sysfsName(self: VrrProperty) []const u8 {
        return switch (self) {
            .vrr_capable => "vrr_capable",
            .vrr_enabled => "vrr_enabled",
            .max_bpc => "max_bpc",
            .content_type => "content_type",
            .hdr_output_metadata => "hdr_output_metadata",
        };
    }
};

/// DRM connector information
pub const DrmConnector = struct {
    allocator: mem.Allocator,
    /// Connector name (e.g., "DP-1", "HDMI-A-1")
    name: []const u8,
    /// Card number
    card: u32,
    /// Connector ID
    connector_id: u32,
    /// Connection status
    connected: bool,
    /// EDID data
    edid: ?[]const u8,
    /// VRR capable (from EDID or driver)
    vrr_capable: bool,
    /// VRR currently enabled
    vrr_enabled: bool,
    /// Min VRR refresh rate
    min_vrefresh: u32,
    /// Max VRR refresh rate
    max_vrefresh: u32,

    pub fn deinit(self: *DrmConnector) void {
        self.allocator.free(self.name);
        if (self.edid) |e| self.allocator.free(e);
    }
};

/// DRM VRR Manager
pub const DrmManager = struct {
    allocator: mem.Allocator,
    connectors: std.ArrayListUnmanaged(DrmConnector),

    pub fn init(allocator: mem.Allocator) DrmManager {
        return .{
            .allocator = allocator,
            .connectors = .empty,
        };
    }

    pub fn deinit(self: *DrmManager) void {
        for (self.connectors.items) |*c| {
            c.deinit();
        }
        self.connectors.deinit(self.allocator);
    }

    /// Scan all DRM connectors
    pub fn scan(self: *DrmManager) !void {
        var dir = fs.cwd().openDir(DRM_SYS_DIR, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            // Look for card*-CONNECTOR patterns
            if (!mem.startsWith(u8, entry.name, "card")) continue;

            // Parse card number and connector name
            const dash_idx = mem.indexOf(u8, entry.name, "-") orelse continue;
            const card_str = entry.name[4..dash_idx];
            const connector_name = entry.name[dash_idx + 1 ..];

            const card = std.fmt.parseInt(u32, card_str, 10) catch continue;

            // Check if connected
            var path_buf: [512]u8 = undefined;
            const status_path = std.fmt.bufPrint(&path_buf, "{s}/{s}/status", .{ DRM_SYS_DIR, entry.name }) catch continue;

            const status = self.readSysfs(status_path) orelse continue;
            defer self.allocator.free(status);

            const connected = mem.eql(u8, mem.trim(u8, status, "\n \t\r"), "connected");

            // Read VRR capable
            const vrr_cap_path = std.fmt.bufPrint(&path_buf, "{s}/{s}/vrr_capable", .{ DRM_SYS_DIR, entry.name }) catch "";
            const vrr_capable = if (vrr_cap_path.len > 0) blk: {
                const v = self.readSysfs(vrr_cap_path) orelse break :blk false;
                defer self.allocator.free(v);
                break :blk mem.eql(u8, mem.trim(u8, v, "\n \t\r"), "1");
            } else false;

            // Read VRR enabled (if available, requires compositor support)
            const vrr_en_path = std.fmt.bufPrint(&path_buf, "{s}/{s}/vrr_enabled", .{ DRM_SYS_DIR, entry.name }) catch "";
            const vrr_enabled = if (vrr_en_path.len > 0) blk: {
                const v = self.readSysfs(vrr_en_path) orelse break :blk false;
                defer self.allocator.free(v);
                break :blk mem.eql(u8, mem.trim(u8, v, "\n \t\r"), "1");
            } else false;

            // Read EDID for VRR range
            var min_vrefresh: u32 = 48;
            var max_vrefresh: u32 = 60;
            const edid_path = std.fmt.bufPrint(&path_buf, "{s}/{s}/edid", .{ DRM_SYS_DIR, entry.name }) catch "";
            const edid = if (edid_path.len > 0) blk: {
                const e = self.readSysfsBinary(edid_path) orelse break :blk null;
                // Parse EDID for VRR range (DisplayID extension or CTA-861)
                const range = parseEdidVrrRange(e);
                min_vrefresh = range.min;
                max_vrefresh = range.max;
                break :blk e;
            } else null;

            const connector = DrmConnector{
                .allocator = self.allocator,
                .name = self.allocator.dupe(u8, connector_name) catch continue,
                .card = card,
                .connector_id = 0, // Would need ioctl to get
                .connected = connected,
                .edid = edid,
                .vrr_capable = vrr_capable,
                .vrr_enabled = vrr_enabled,
                .min_vrefresh = min_vrefresh,
                .max_vrefresh = max_vrefresh,
            };

            self.connectors.append(self.allocator, connector) catch continue;
        }
    }

    fn readSysfs(self: *DrmManager, path: []const u8) ?[]const u8 {
        const file = fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();

        var buf: [256]u8 = undefined;
        const len = file.read(&buf) catch return null;
        return self.allocator.dupe(u8, buf[0..len]) catch null;
    }

    fn readSysfsBinary(self: *DrmManager, path: []const u8) ?[]const u8 {
        const file = fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();

        var buf: [512]u8 = undefined;
        const len = file.read(&buf) catch return null;
        return self.allocator.dupe(u8, buf[0..len]) catch null;
    }

    /// Find connector by name
    pub fn findConnector(self: *DrmManager, name: []const u8) ?*DrmConnector {
        for (self.connectors.items) |*c| {
            if (mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }

    /// Get all VRR-capable connectors
    pub fn getVrrCapable(self: *DrmManager) []DrmConnector {
        var result = std.ArrayListUnmanaged(DrmConnector).empty;
        for (self.connectors.items) |c| {
            if (c.vrr_capable) {
                result.append(self.allocator, c) catch continue;
            }
        }
        return result.items;
    }
};

/// Parse EDID for VRR range
fn parseEdidVrrRange(edid: []const u8) struct { min: u32, max: u32 } {
    // Default safe values
    var result = .{ .min = 48, .max = 60 };

    if (edid.len < 128) return result;

    // Look for Display Range Limits descriptor (tag 0xFD)
    // EDID detailed timing descriptors start at offset 54
    var offset: usize = 54;
    while (offset + 18 <= 126) : (offset += 18) {
        // Check for Display Range Limits descriptor
        if (edid[offset] == 0 and edid[offset + 1] == 0 and edid[offset + 2] == 0 and edid[offset + 3] == 0xFD) {
            // Byte 5: Min vertical rate
            // Byte 6: Max vertical rate
            result.min = edid[offset + 5];
            result.max = edid[offset + 6];

            // Check for extended timing support (offset flags)
            if (edid[offset + 4] & 0x02 != 0) {
                // Bit 1 set means add 255 to max
                result.max += 255;
            }
            break;
        }
    }

    // Also check CTA-861 extension blocks for VRR
    if (edid.len >= 256 and edid[128] == 0x02) {
        // CTA-861 extension present
        // Look for VFPDB (Video Format Preference Data Block) or VSVDB
        // This is where FreeSync/G-Sync Compatible range is stored
        var ext_offset: usize = 132; // Start of data blocks
        const dtd_start = edid[130]; // Offset to detailed timing descriptors

        while (ext_offset < 128 + dtd_start) {
            const tag = (edid[ext_offset] & 0xE0) >> 5;
            const length = edid[ext_offset] & 0x1F;

            if (tag == 7 and length >= 3) {
                // Extended tag
                const ext_tag = edid[ext_offset + 1];
                if (ext_tag == 0x1A) {
                    // VFPDB - contains VRR info
                    // Implementation would parse this
                }
            }

            ext_offset += length + 1;
            if (ext_offset >= 256) break;
        }
    }

    return result;
}

/// DRM ioctl definitions for VRR control
pub const DRM_IOCTL = struct {
    pub const BASE = 'd';

    // Mode setting ioctls
    pub const MODE_GETCONNECTOR = ioctl_rw(0xA7);
    pub const MODE_SETPROPERTY = ioctl_rw(0xAB);
    pub const MODE_GETPROPERTY = ioctl_rw(0xAA);
    pub const MODE_OBJ_GETPROPERTIES = ioctl_rw(0xB9);
    pub const MODE_OBJ_SETPROPERTY = ioctl_rw(0xBA);

    fn ioctl_rw(nr: u8) u32 {
        return @as(u32, 0xC0000000) | (@as(u32, BASE) << 8) | nr;
    }
};

/// Set VRR enabled via DRM (requires root or DRM master)
pub fn setVrrEnabled(card: u32, connector_id: u32, enabled: bool) !void {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/dev/dri/card{d}", .{card}) catch return error.PathError;

    const fd = posix.open(path, .{ .ACCMODE = .RDWR }, 0) catch return error.OpenFailed;
    defer posix.close(fd);

    // Would need to:
    // 1. Get connector properties (DRM_IOCTL_MODE_OBJ_GETPROPERTIES)
    // 2. Find "vrr_enabled" property ID
    // 3. Set property (DRM_IOCTL_MODE_OBJ_SETPROPERTY)

    // For now, this requires libdrm or direct ioctl implementation
    _ = connector_id;
    _ = enabled;
    return error.NotImplemented;
}

test "DrmManager init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var manager = DrmManager.init(gpa.allocator());
    defer manager.deinit();
}

test "parseEdidVrrRange defaults" {
    const empty: [0]u8 = .{};
    const result = parseEdidVrrRange(&empty);
    try std.testing.expectEqual(@as(u32, 48), result.min);
    try std.testing.expectEqual(@as(u32, 60), result.max);
}
