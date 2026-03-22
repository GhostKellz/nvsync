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

/// VRR range result from EDID parsing
pub const VrrRange = struct {
    min: u32,
    max: u32,
    lfc_supported: bool, // Low Framerate Compensation (when range > 2.4x)
    source: VrrSource,

    pub const VrrSource = enum {
        default, // Couldn't parse, using defaults
        display_range_limits, // EDID 1.4 Display Range Limits descriptor
        cta_vfpdb, // CTA-861 Video Format Preference Data Block
        freesync_vsdb, // AMD FreeSync Vendor-Specific Data Block
        displayid, // DisplayID 2.0 extension
    };
};

/// Parse EDID for VRR range
/// Supports:
/// - EDID 1.4 Display Range Limits (0xFD descriptor)
/// - CTA-861-G extension blocks
/// - AMD FreeSync VSDB
pub fn parseEdidVrrRange(edid: []const u8) VrrRange {
    // Default safe values
    var result = VrrRange{
        .min = 48,
        .max = 60,
        .lfc_supported = false,
        .source = .default,
    };

    if (edid.len < 128) return result;

    // Method 1: Look for Display Range Limits descriptor (tag 0xFD)
    // EDID detailed timing descriptors start at offset 54
    var offset: usize = 54;
    while (offset + 18 <= 126) : (offset += 18) {
        // Check for Display Range Limits descriptor
        // Format: 00 00 00 FD 00 min_v max_v ...
        if (edid[offset] == 0 and edid[offset + 1] == 0 and
            edid[offset + 2] == 0 and edid[offset + 3] == 0xFD)
        {
            const flags = edid[offset + 4];
            var min_v: u32 = edid[offset + 5];
            var max_v: u32 = edid[offset + 6];

            // Check for GTF/CVT secondary timing support
            // Bits 0-1 indicate offsets to min/max V rates
            if (flags & 0x01 != 0) {
                // Bit 0: Add 255 to max vertical rate
                max_v += 255;
            }
            if (flags & 0x02 != 0) {
                // Bit 1: Add 255 to min vertical rate
                min_v += 255;
            }

            // Sanity check the values
            if (max_v > min_v and max_v <= 500 and min_v >= 1) {
                result.min = min_v;
                result.max = max_v;
                result.source = .display_range_limits;
                // LFC supported if range > 2.4x (e.g., 48-144Hz allows 24fps via doubling)
                result.lfc_supported = (max_v * 10 / min_v) >= 24;
            }
            break;
        }
    }

    // Method 2: Check CTA-861 extension blocks for VRR data
    if (edid.len >= 256 and edid[128] == 0x02) {
        // CTA-861 extension present
        const dtd_offset = edid[130]; // Offset to detailed timing descriptors
        if (dtd_offset > 4 and dtd_offset < 127) {
            var ext_offset: usize = 132; // Start of data blocks (after header)

            while (ext_offset < 128 + @as(usize, dtd_offset)) {
                if (ext_offset >= edid.len) break;

                const header = edid[ext_offset];
                const tag = (header & 0xE0) >> 5;
                const length = header & 0x1F;

                if (ext_offset + length + 1 > edid.len) break;

                if (tag == 3 and length >= 3) {
                    // Vendor-Specific Data Block (VSDB)
                    const oui = (@as(u32, edid[ext_offset + 3]) << 16) |
                        (@as(u32, edid[ext_offset + 2]) << 8) |
                        @as(u32, edid[ext_offset + 1]);

                    // AMD FreeSync OUI: 0x00001A (little-endian: 1A 00 00)
                    if (oui == 0x00001A and length >= 9) {
                        // FreeSync VSDB format:
                        // Byte 4: Version
                        // Byte 5: Min refresh (offset by VSDB specific value)
                        // Byte 6: Max refresh
                        const fs_min = edid[ext_offset + 8];
                        const fs_max = edid[ext_offset + 9];

                        if (fs_max > fs_min and fs_max <= 255 and fs_min >= 24) {
                            result.min = fs_min;
                            result.max = fs_max;
                            result.source = .freesync_vsdb;
                            result.lfc_supported = (fs_max * 10 / fs_min) >= 24;
                        }
                    }
                } else if (tag == 7 and length >= 2) {
                    // Extended tag block
                    const ext_tag = edid[ext_offset + 1];

                    if (ext_tag == 0x1A and length >= 3) {
                        // VFPDB (Video Format Preference Data Block)
                        // Contains preferred VRR range
                        // This is less common but some monitors use it
                        result.source = .cta_vfpdb;
                    }
                }

                ext_offset += @as(usize, length) + 1;
            }
        }
    }

    // Method 3: Check for DisplayID 2.0 extension (rare but modern)
    // DisplayID uses tag 0x70 at offset 128
    if (edid.len >= 256 and edid[128] == 0x70) {
        // DisplayID 2.0 extension present
        // Would need more complex parsing for Dynamic Video Timing Range Block
        result.source = .displayid;
    }

    return result;
}

/// Parse EDID to get monitor name
pub fn parseEdidMonitorName(edid: []const u8) ?[]const u8 {
    if (edid.len < 128) return null;

    // Look for Monitor Name descriptor (tag 0xFC)
    var offset: usize = 54;
    while (offset + 18 <= 126) : (offset += 18) {
        if (edid[offset] == 0 and edid[offset + 1] == 0 and
            edid[offset + 2] == 0 and edid[offset + 3] == 0xFC)
        {
            // Name is at offset + 5, up to 13 characters, terminated by 0x0A
            const name_start = offset + 5;
            var name_end = name_start;
            while (name_end < offset + 18 and edid[name_end] != 0x0A and edid[name_end] != 0) {
                name_end += 1;
            }
            if (name_end > name_start) {
                return edid[name_start..name_end];
            }
        }
    }
    return null;
}

/// Parse EDID to get native resolution
pub fn parseEdidNativeResolution(edid: []const u8) ?struct { width: u32, height: u32 } {
    if (edid.len < 128) return null;

    // First detailed timing descriptor (at offset 54) is typically native resolution
    // Only parse if it's a timing descriptor (first two bytes non-zero = pixel clock)
    if (edid[54] != 0 or edid[55] != 0) {
        // Horizontal active pixels: bytes 56-57 (lower 8 bits) + byte 58 upper nibble
        const h_active_low = edid[56];
        const h_active_high = (edid[58] >> 4) & 0x0F;
        const h_active: u32 = (@as(u32, h_active_high) << 8) | h_active_low;

        // Vertical active lines: bytes 59-60 (lower 8 bits) + byte 61 upper nibble
        const v_active_low = edid[59];
        const v_active_high = (edid[61] >> 4) & 0x0F;
        const v_active: u32 = (@as(u32, v_active_high) << 8) | v_active_low;

        if (h_active > 0 and v_active > 0) {
            return .{ .width = h_active, .height = v_active };
        }
    }
    return null;
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

/// DRM object types
pub const DRM_MODE_OBJECT_CONNECTOR: u32 = 0xc0c0c0c1;

/// drm_mode_obj_set_property structure for ioctl
const drm_mode_obj_set_property = extern struct {
    value: u64,
    prop_id: u32,
    obj_id: u32,
    obj_type: u32,
    pad: u32 = 0,
};

/// drm_mode_obj_get_properties structure for ioctl
const drm_mode_obj_get_properties = extern struct {
    props_ptr: u64, // pointer to u32 array
    prop_values_ptr: u64, // pointer to u64 array
    count_props: u32,
    obj_id: u32,
    obj_type: u32,
    pad: u32 = 0,
};

/// drm_mode_get_property structure for property info
const drm_mode_get_property = extern struct {
    values_ptr: u64,
    enum_blob_ptr: u64,
    prop_id: u32,
    flags: u32,
    name: [32]u8,
    count_values: u32,
    count_enum_blobs: u32,
};

/// Set VRR enabled via DRM (requires root or DRM master)
/// Note: DRM ioctl method requires DRM master privileges which most applications don't have.
/// The sysfs method in DisplayManager.setVrrViaSysfs is preferred.
pub fn setVrrEnabled(card: u32, connector_id: u32, enabled: bool) !void {
    // DRM ioctl requires DRM master privileges which games/apps typically don't have.
    // The compositor holds DRM master. Use sysfs or compositor APIs instead.
    _ = card;
    _ = connector_id;
    _ = enabled;
    return error.DrmMasterRequired;
}

/// Find a property ID by name for a connector
fn findPropertyId(fd: posix.fd_t, connector_id: u32, prop_name: []const u8) !u32 {
    // First, get property count
    var get_props = drm_mode_obj_get_properties{
        .props_ptr = 0,
        .prop_values_ptr = 0,
        .count_props = 0,
        .obj_id = connector_id,
        .obj_type = DRM_MODE_OBJECT_CONNECTOR,
    };

    var result = std.posix.system.ioctl(fd, DRM_IOCTL.MODE_OBJ_GETPROPERTIES, @intFromPtr(&get_props));
    if (result != 0) return error.IoctlFailed;

    if (get_props.count_props == 0) return error.PropertyNotFound;

    // Allocate arrays for property IDs and values
    var prop_ids: [64]u32 = undefined;
    var prop_values: [64]u64 = undefined;

    const count = @min(get_props.count_props, 64);
    get_props.props_ptr = @intFromPtr(&prop_ids);
    get_props.prop_values_ptr = @intFromPtr(&prop_values);
    get_props.count_props = count;

    result = std.posix.system.ioctl(fd, DRM_IOCTL.MODE_OBJ_GETPROPERTIES, @intFromPtr(&get_props));
    if (result != 0) return error.IoctlFailed;

    // Iterate through properties to find the one we want
    for (prop_ids[0..count]) |prop_id| {
        var get_prop = drm_mode_get_property{
            .values_ptr = 0,
            .enum_blob_ptr = 0,
            .prop_id = prop_id,
            .flags = 0,
            .name = [_]u8{0} ** 32,
            .count_values = 0,
            .count_enum_blobs = 0,
        };

        result = std.posix.system.ioctl(fd, DRM_IOCTL.MODE_GETPROPERTY, @intFromPtr(&get_prop));
        if (result != 0) continue;

        // Compare property name
        const name_slice = mem.sliceTo(&get_prop.name, 0);
        if (mem.eql(u8, name_slice, prop_name)) {
            return prop_id;
        }
    }

    return error.PropertyNotFound;
}

/// Get VRR enabled state via DRM
/// Note: Use sysfs method instead - reads /sys/class/drm/*/vrr_enabled
pub fn getVrrEnabled(card: u32, connector_id: u32) !bool {
    // Use sysfs instead of DRM ioctl for reading VRR state
    _ = connector_id;

    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/card{d}-*/vrr_enabled", .{card}) catch return false;
    _ = path;

    // The sysfs reading is done in DisplayManager.scanDrmDevices()
    // This function is kept for API compatibility but prefers sysfs
    return error.UseSysfsInstead;
}

test "DrmManager init" {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();

    var manager = DrmManager.init(debug_alloc.allocator());
    defer manager.deinit();
}

test "parseEdidVrrRange defaults" {
    const empty: [0]u8 = .{};
    const result = parseEdidVrrRange(&empty);
    try std.testing.expectEqual(@as(u32, 48), result.min);
    try std.testing.expectEqual(@as(u32, 60), result.max);
    try std.testing.expectEqual(VrrRange.VrrSource.default, result.source);
}

test "parseEdidVrrRange display range limits" {
    // Minimal EDID with Display Range Limits descriptor at offset 54
    var edid: [128]u8 = [_]u8{0} ** 128;

    // Set up a valid Display Range Limits descriptor
    // Offset 54-71 is first detailed timing/descriptor block
    edid[54] = 0x00; // Indicates it's a descriptor, not timing
    edid[55] = 0x00;
    edid[56] = 0x00;
    edid[57] = 0xFD; // Display Range Limits tag
    edid[58] = 0x00; // Flags
    edid[59] = 48; // Min vertical rate: 48Hz
    edid[60] = 144; // Max vertical rate: 144Hz

    const result = parseEdidVrrRange(&edid);
    try std.testing.expectEqual(@as(u32, 48), result.min);
    try std.testing.expectEqual(@as(u32, 144), result.max);
    try std.testing.expectEqual(VrrRange.VrrSource.display_range_limits, result.source);
    try std.testing.expect(result.lfc_supported); // 144/48 = 3x > 2.4x
}

test "VrrRange lfc calculation" {
    // LFC is supported when max/min ratio >= 2.4
    // 144/48 = 3.0 -> LFC supported
    // 60/48 = 1.25 -> LFC not supported
    var edid: [128]u8 = [_]u8{0} ** 128;
    edid[54] = 0x00;
    edid[55] = 0x00;
    edid[56] = 0x00;
    edid[57] = 0xFD;
    edid[58] = 0x00;
    edid[59] = 48;
    edid[60] = 60; // Only 60Hz max

    const result = parseEdidVrrRange(&edid);
    try std.testing.expect(!result.lfc_supported); // 60/48 = 1.25x < 2.4x
}
