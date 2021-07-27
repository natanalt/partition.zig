const std = @import("std");
const partition = @import("partition.zig");
const DeviceParam = partition.DeviceParam;

const Crc32 = std.hash.Crc32;
const native_endian: std.builtin.Endian = std.Target.current.cpu.arch.endian();

pub const Guid = extern struct {
    /// Raw byte data of the GUID
    data: [16]u8,

    /// Creates a fully zeroed GUID
    pub fn zero() Guid {
        return .{ .data = [_]u8{0} ** 16 };
    }

    pub fn fromBytes(data: *const [16]u8) Guid {
        return .{ .data = data.* };
    }

    /// Creates a randomized GUID
    pub fn createRandom() Guid {
        var self = Guid.zero();
        std.crypto.random.bytes(&self.data);
        // TODO: Check if those are correct values
        self.data[7] &= 0x0F;
        self.data[7] |= 0x10;
        self.data[8] &= 0x0F;
        self.data[8] |= 0xB0;
        return self;
    }

    pub fn format(
        self: Guid,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        // Format: {xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}
        //  * first 3 sequences are little endian
        //  * last 2 sequences are big endian
        //  * apparently?????
        try writer.print("{{", .{});
        comptime var i = 0;
        inline while (i < 4) : (i += 1) try writer.print("{X:0>2}", .{self.data[3 - i]});
        try writer.print("-", .{});
        inline while (i < 6) : (i += 1) try writer.print("{X:0>2}", .{self.data[(1 - (i - 4)) + 4]});
        try writer.print("-", .{});
        inline while (i < 8) : (i += 1) try writer.print("{X:0>2}", .{self.data[(1 - (i - 6)) + 6]});
        try writer.print("-", .{});
        inline while (i < 10) : (i += 1) try writer.print("{X:0>2}", .{self.data[i]});
        try writer.print("-", .{});
        inline while (i < 16) : (i += 1) try writer.print("{X:0>2}", .{self.data[i]});
        try writer.print("}}", .{});
    }
};

pub const GptKind = enum { primary, backup };

// TODO: add verifications for
//  * no partition overlaps
//  * no partitions going out of bounds
//  * fields like first_usable_lba not overlapping primary/backup GPTs
//
// They aren't super necessary, but are just making the library more bulletproof
// Ideally, every invalid case should be caught, no matter how small and impossible to find on normal systems.

/// Representation of a GPT formatted disk
pub const GptDisk = struct {
    pub const max_partitions = 128;
    pub const header_size = @sizeOf(raw.Header);

    pub const ReadWarnings = struct {
        primary_gpt_corrupt: bool = false,
        backup_gpt_corrupt: bool = false,

        pub fn isEverythingOk(self: ReadWarnings) bool {
            inline for (std.meta.fields(T)) |f| {
                if (!@field(self, f.name)) {
                    return false;
                }
            }
            return true;
        }
    };

    device: DeviceParam,
    disk_guid: Guid,
    partitions: [max_partitions]?GptPartition,
    first_usable_lba: u64,
    last_usable_lba: u64,
    placement: struct {
        primary_header_lba: u64,
        primary_table_lba: u64,
        backup_header_lba: u64,
        backup_table_lba: u64,
        partition_entry_size: u32,
    },

    /// Modified by GptDisk.read() to signal anything that could've partially gone wrong during
    /// the read.
    read_warnings: ReadWarnings = .{},

    pub fn new(device: DeviceParam) GptDisk {
        const partition_table_sectors = std.math.divCeil(
            u64, 
            @sizeOf(raw.PartitionEntry) * max_partitions,
            device.sector_size,
        ) catch unreachable;
        return .{
            .device = device,
            .disk_guid = Guid.createRandom(),
            .partitions = [_]?GptPartition{null} ** max_partitions,
            .first_usable_lba = 1 + 1 + partition_table_sectors,
            .last_usable_lba = device.total_sectors - 1 - 1 - partition_table_sectors,
            .placement = .{
                .primary_header_lba = 1,
                .primary_table_lba = 2,
                .backup_header_lba = device.total_sectors - 1,
                .backup_table_lba = device.total_sectors - partition_table_sectors - 1,
                .partition_entry_size = @sizeOf(raw.PartitionEntry),
            }
        };
    }

    /// Attempts to read a GPT formatted disk
    /// Returns error.NoGpt if no GPTs are found on the disk
    /// Returns error.GptsNotEqual if primary and backup GPTs are valid, but not equal
    /// May also return any error from the stream, device, and some other things
    pub fn read(
        allocator: *std.mem.Allocator,
        device: DeviceParam,
        stream: *std.io.StreamSource,
    ) !GptDisk {
        // TODO: check for a protective MBR before parsing GPT stuff
        // A present and valid GPT does not necessarily mean that the disk is actually meant to be
        // a valid GPT disk. If a GPT device is reformatted to MBR, the partitioning software may
        // not wipe the GPT structures, causing problems.
        //
        // The solution for that is to analyze the MBR at LBA 0.
        // If the MBR is not valid, or contains a partition of type 0xEE (GPT protective), then
        // this disk may be considered a potentially valid GPT disk. Any other MBR present suggests
        // that this device is actually MBR formatted and GPT operations should not be preformed
        // on it.
        //
        // It's also needed by util-linux's fdisk to consider a GPT disk as valid
        // 

        // Arena used for temporary parsing allocations
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const temp_allocator = &arena.allocator;

        var read_warnings = ReadWarnings{};
        
        const primary_gpt_opt: ?RawGpt = RawGpt.read(
            temp_allocator, 
            device, 
            stream, 
            1,
        ) catch |e| blk: {
            if (e == error.InvalidGpt) {
                read_warnings.primary_gpt_corrupt = true;
                break :blk null;
            } else {
                return e;
            }
        };
        
        const backup_lba = if (primary_gpt_opt) |gpt|
            gpt.getHeader().alternate_lba
        else
            device.total_sectors - 1;
        
        const backup_gpt_opt: ?RawGpt = RawGpt.read(
            temp_allocator, 
            device, 
            stream, 
            backup_lba,
        ) catch |e| blk: {
            if (e == error.InvalidGpt) {
                read_warnings.backup_gpt_corrupt = true;
                break :blk null;
            } else {
                return e;
            }
        };

        if (read_warnings.primary_gpt_corrupt and read_warnings.backup_gpt_corrupt)
            return error.NoGpt;
        
        if (!read_warnings.primary_gpt_corrupt and !read_warnings.backup_gpt_corrupt)
            if (!RawGpt.areGptsEqual(primary_gpt_opt.?, backup_gpt_opt.?))
                return error.GptsNotEqual;
        
        const source_gpt: RawGpt = if (read_warnings.primary_gpt_corrupt)
            backup_gpt_opt.?
        else
            primary_gpt_opt.?;
        const source_header = source_gpt.getHeader();
        
        var result = GptDisk.new(device);
        result.read_warnings = read_warnings;
        result.disk_guid = Guid.fromBytes(&source_header.disk_guid);
        result.placement.partition_entry_size = source_header.size_of_partition_entry;
        if (!read_warnings.primary_gpt_corrupt) {
            result.placement.primary_header_lba = 1;
            result.placement.primary_table_lba = primary_gpt_opt.?.getHeader().partition_entry_lba;
        }
        if (!read_warnings.backup_gpt_corrupt) {
            result.placement.backup_header_lba = backup_lba;
            result.placement.backup_table_lba = backup_gpt_opt.?.getHeader().partition_entry_lba;
        }

        errdefer for (result.partitions) |v| if (v) |part| allocator.free(part.name);
        for (result.partitions) |_, i| {
            const raw_entry = source_gpt.getPartitionEntry(@intCast(u32, i));
            if (!std.mem.allEqual(u8, &raw_entry.partition_type_guid, 0)) {
                result.partitions[i] = GptPartition{
                    .partition_type = Guid.fromBytes(&raw_entry.partition_type_guid),
                    .partition_guid = Guid.fromBytes(&raw_entry.unique_partition_guid),
                    .starting_lba = raw_entry.starting_lba,
                    .ending_lba = raw_entry.ending_lba,
                    .attributes = try GptPartition.Attributes.unpack(raw_entry.attributes),
                    .name = try ucs2ToUtf8Alloc(allocator, for (raw_entry.partition_name) |v, j| {
                        if (v == 0)
                            break raw_entry.partition_name[0..j];
                    } else &raw_entry.partition_name),
                };
            }   
        }

        return result;
    }

    /// Verifies whether provided device is a valid GPT device
    pub fn isValidGpt(
        allocator: *std.mem.Allocator,
        device: DeviceParam,
        stream: *std.io.StreamSource,
    ) !bool {
        // TODO: write a better implementation of that instead of just hooking GptDisk.read
        
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        
        _ = GptDisk.read(&arena.allocator, device, stream) catch |err| {
            switch (err) {
                error.NoGpt,
                error.GptsNotEqual => return false,
                else => return err,
            }
        };
        return true;
    }

    /// Writes this GPT structure onto the target stream.
    /// This will overwrite any already present GPT and MBR structures
    /// Takes a temporary allocator, any memory allocated by it will be freed after this function
    /// returns.
    pub fn write(
        self: GptDisk,
        allocator: *std.mem.Allocator,
        stream: *std.io.StreamSource,
    ) !void {

        // TODO: get rid of the allocator by writing the partition table directly into the target
        //       device, calculating its CRC on the fly

        var pea_stream = std.io.FixedBufferStream([]u8){
            .pos = 0,
            .buffer = try allocator.alloc(u8, self.device.sectorAlignSize(
                self.partitions.len * self.placement.partition_entry_size,
            )),
        };
        defer allocator.free(pea_stream.buffer);

        // Note: hardcoded minimal part entry size
        if (self.placement.partition_entry_size < 128)
            return error.PartitionEntrySizeTooSmall;

        // Write the partition table into a temporary buffer (allocated above)
        for (self.partitions) |part_opt| {
            if (part_opt) |part| {
                const raw_entry = raw.PartitionEntry{
                    .partition_type_guid = part.partition_type.data,
                    .unique_partition_guid = part.partition_guid.data,
                    .starting_lba = part.starting_lba,
                    .ending_lba = part.ending_lba,
                    .attributes = part.attributes.pack(),
                    .partition_name = blk: {
                        var result = [_]u16{0} ** 36;
                        _ = try utf8ToUcs2Le(part.name, result[0..35]);
                        break :blk result;
                    },
                };
                // Technically those aren't "sectors", but use case is the same
                try writeSectorsPadWithZeros(
                    pea_stream.writer(),
                    raw.toBytes(raw.PartitionEntry, raw_entry)[0..std.math.min(
                        self.placement.partition_entry_size,
                        @sizeOf(raw.PartitionEntry),
                    )],
                    self.placement.partition_entry_size,
                );
            } else {
                try pea_stream.writer().writeByteNTimes(0, self.placement.partition_entry_size);
            }
        }

        // TODO: write a protective MBR instead of overwriting it with 0s
        try stream.seekTo(try self.device.lbaToOffset(0));
        try stream.writer().writeByteNTimes(0, self.device.sector_size);

        const pea_hash = Crc32.hash(pea_stream.buffer);
        try self.writeGpt(stream, .primary, pea_stream.buffer, pea_hash);
        try self.writeGpt(stream, .backup, pea_stream.buffer, pea_hash);
    }

    fn writeGpt(
        self: GptDisk,
        stream: *std.io.StreamSource,
        kind: GptKind,
        part_table: []const u8,
        part_table_crc: u32,
    ) !void {
        var header = raw.Header{
            .signature = raw.Header.valid_signature,
            .revision = raw.Header.valid_revision,
            .header_size = 92, // Note: hardcoding this because of some weird size issues with raw.Header
            .header_crc32 = 0,
            .reserved = 0,
            .my_lba = switch (kind) {
                .primary => self.placement.primary_header_lba,
                .backup => self.placement.backup_header_lba,
            },
            .alternate_lba = switch (kind) {
                .primary => self.placement.backup_header_lba,
                .backup => self.placement.primary_header_lba,
            },
            .first_usable_lba = self.first_usable_lba,
            .last_usable_lba = self.last_usable_lba,
            .disk_guid = self.disk_guid.data,
            .partition_entry_lba = switch (kind) {
                .primary => self.placement.primary_table_lba,
                .backup => self.placement.backup_table_lba,
            },
            .number_of_partition_entries = self.partitions.len,
            .size_of_partition_entry = self.placement.partition_entry_size,
            .partition_entry_array_crc32 = part_table_crc,
        };
        header.header_crc32 = Crc32.hash(raw.toBytes(raw.Header, header)[0..header.header_size]);

        try stream.seekTo(try self.device.lbaToOffset(header.my_lba));
        try writeSectorsPadWithZeros(
            stream.writer(),
            raw.toBytes(raw.Header, header)[0..header.header_size],
            self.device.sector_size,
        );

        try stream.seekTo(try self.device.lbaToOffset(header.partition_entry_lba));
        try writeSectorsPadWithZeros(
            stream.writer(), 
            part_table, 
            self.device.sector_size,
        );
    }
};

/// Representation of a GPT partition.
/// Note, that the name stored in here is meant to be UTF-8 and is validated and covnerted to UCS-2
/// when GPT is written to a target device.
pub const GptPartition = struct {
    pub const Attributes = struct {
        required_by_system: bool = false,
        no_block_io: bool = false,
        legacy_boot: bool = false,
        fs_reserved: u16 = 0,

        pub fn pack(self: Attributes) u64 {
            var result: u64 = 0;
            result |= if (self.required_by_system) @as(u64, 1) << 0 else 0;
            result |= if (self.no_block_io) @as(u64, 1) << 1 else 0;
            result |= if (self.legacy_boot) @as(u64, 1) << 2 else 0;
            result |= @intCast(u64, self.fs_reserved) << 48;
            return result;
        }

        pub fn unpack(att: u64) !Attributes {
            if (att & 0x0000FFFFFFFFFFF8 != 0)
                return error.InvalidValue;
            
            return Attributes{
                .required_by_system = @truncate(u1, att >> 0) == 1,
                .no_block_io = @truncate(u1, att >> 1) == 1,
                .legacy_boot = @truncate(u1, att >> 2) == 1,
                .fs_reserved = @truncate(u16, att >> 48),
            };
        }
    };

    partition_type: Guid,
    partition_guid: Guid,
    name: []const u8,
    starting_lba: u64,
    ending_lba: u64,
    attributes: Attributes,

    pub fn isNameValid(self: GptPartition) bool {
        var buffer: [512]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        const str = std.unicode.utf8ToUtf16LeWithNull(&fba.allocator, self.name) catch return false;
        return str.len <= 35;
    }
};

pub const raw = struct {

    /// Raw GPT header, per UEFI specification
    pub const Header = extern struct {
        pub const valid_signature = [8]u8{ 'E', 'F', 'I', ' ', 'P', 'A', 'R', 'T' };
        pub const valid_revision = [4]u8{ 0, 0, 1, 0 };

        signature: [8]u8,
        revision: [4]u8,
        header_size: u32,
        header_crc32: u32,
        reserved: u32,
        my_lba: u64,
        alternate_lba: u64,
        first_usable_lba: u64,
        last_usable_lba: u64,
        disk_guid: [16]u8,
        partition_entry_lba: u64,
        number_of_partition_entries: u32,
        size_of_partition_entry: u32,
        partition_entry_array_crc32: u32,
    };

    /// Raw partition entry, per UEFI specification
    /// Note: according to some sources (like OSDev Wiki), size of partition_name should not be
    /// hardcoded. So this behavior may need to be adjusted as needed.
    pub const PartitionEntry = extern struct {
        partition_type_guid: [16]u8,
        unique_partition_guid: [16]u8,
        starting_lba: u64,
        ending_lba: u64,
        attributes: u64,
        partition_name: [72 / 2]u16,
    };

    pub fn fromBytes(
        comptime T: type,
        bytes: *[@sizeOf(T)]u8,
    ) T {
        var result = std.mem.bytesToValue(T, bytes);
        byteSwapAllIntegersOnBigEndian(T, &result);
        return result;
    }

    pub fn toBytes(
        comptime T: type,
        value: T,
    ) [@sizeOf(T)]u8 {
        var copy = value;
        byteSwapAllIntegersOnBigEndian(T, &copy);
        return std.mem.toBytes(copy);
    }

    fn byteSwapAllIntegersOnBigEndian(
        comptime T: type,
        value: *T,
    ) void {
        if (@typeInfo(T) != .Struct) {
            @compileError("Only structs are allowed");
        }

        if (native_endian != .Big) {
            return;
        }

        inline for (std.meta.fields(T)) |f| {
            switch (@typeInfo(f.field_type)) {
                .Int => @field(value, f.name) = @byteSwap(f.field_type, @field(value, f.name)),
                else => {},
            }
        }
    }
};

/// Parse-time utility structure
const RawGpt = struct {
    const Self = @This();

    raw_header: []u8,
    raw_pea: []u8,

    /// Reads a GPT, starting at the header at provided LBA.
    /// Returns a RawGpt on success, error.InvalidGpt if any of the verifications fail, or any
    /// other error if an allocation/seek/read failure occurs.
    pub fn read(
        allocator: *std.mem.Allocator,
        device: DeviceParam,
        stream: *std.io.StreamSource,
        header_lba: u64,
    ) !Self {
        var self = Self{
            .raw_header = undefined,
            .raw_pea = undefined,
        };

        self.raw_header = try allocator.alloc(u8, device.sector_size);
        errdefer allocator.free(self.raw_header);
        try stream.seekTo(try device.lbaToOffset(header_lba));
        try readFullOrError(stream.reader(), self.raw_header);
        
        const header = self.getHeader();
        if (!std.mem.eql(u8, &header.signature, &raw.Header.valid_signature))
            return error.InvalidGpt;
        if (header.header_crc32 != self.getHeaderCrc())
            return error.InvalidGpt;
        if (!std.mem.eql(u8, &header.revision, &raw.Header.valid_revision))
            return error.InvalidGpt;
        if (header.my_lba != header_lba)
            return error.InvalidGpt;
        
        const pea_size = header.size_of_partition_entry * header.number_of_partition_entries;
        self.raw_pea = try allocator.alloc(u8, pea_size);
        errdefer allocator.free(self.raw_pea);
        try stream.seekTo(try device.lbaToOffset(header.partition_entry_lba));
        try readFullOrError(stream.reader(), self.raw_pea);

        if (header.partition_entry_array_crc32 != std.hash.Crc32.hash(self.raw_pea))
            return error.InvalidGpt;

        return self;
    }

    /// Extracts the header from the raw header sector
    pub fn getHeader(self: Self) raw.Header {
        return raw.fromBytes(raw.Header, self.raw_header[0..@sizeOf(raw.Header)]);
    }

    /// Calculates a CRC32 hash of the header
    pub fn getHeaderCrc(self: Self) u32 {
        const header = std.mem.bytesAsValue(raw.Header, self.raw_header[0..@sizeOf(raw.Header)]);
        const old_crc = header.header_crc32;
        header.header_crc32 = 0;
        const hash = std.hash.Crc32.hash(self.raw_header[0..self.getHeader().header_size]);
        header.header_crc32 = old_crc;
        return hash;
    }

    /// Extracts a specified partition entry from the raw partition table buffer
    pub fn getPartitionEntry(self: Self, idx: u32) raw.PartitionEntry {
        const header = self.getHeader();
        if (idx >= header.number_of_partition_entries) {
            @panic("out of bounds access");
        }
        const offset = header.size_of_partition_entry * idx;
        return raw.fromBytes(
            raw.PartitionEntry,
            self.raw_pea[offset..][0..@sizeOf(raw.PartitionEntry)],
        );
    }

    /// Checks if both GPTs are effectively equal.
    /// Assumes that both GPTs are valid (including their hashes).
    /// This function is used in the parsing process, to verify that both primary and backup GPTs
    /// refer to the same values and each other.
    pub fn areGptsEqual(self: Self, other: Self) bool {
        const a = self.getHeader();
        const b = other.getHeader();

        if (a.header_size != b.header_size)
            return false;
        if (a.my_lba != b.alternate_lba)
            return false;
        if (a.alternate_lba != b.my_lba)
            return false;
        if (a.first_usable_lba != b.first_usable_lba)
            return false;
        if (a.last_usable_lba != b.last_usable_lba)
            return false;
        if (!std.mem.eql(u8, &a.disk_guid, &b.disk_guid))
            return false;
        if (a.number_of_partition_entries != b.number_of_partition_entries)
            return false;
        if (a.size_of_partition_entry != b.size_of_partition_entry)
            return false;
        if (a.partition_entry_array_crc32 != b.partition_entry_array_crc32)
            return false;
        return true;
    }
};

/// Reads data from given reader into specified buffer. If amount of read data doesn't equal the
/// buffer's size, error.UnexpectedEof is returned.
fn readFullOrError(
    reader: anytype,
    buf: []u8,
) !void {
    const n = try reader.read(buf);
    if (n != buf.len)
        return error.UnexpectedEof;
}

/// Writes a specified buffer, and pads it with zeroes based on specified alignment/sector_size
fn writeSectorsPadWithZeros(
    writer: anytype,
    buffer: []const u8,
    sector_size: u64,
) !void {
    try writer.writeAll(buffer);
    if ((buffer.len % sector_size) != 0) {
        const pad_size = sector_size - (buffer.len % sector_size);
        try writer.writeByteNTimes(0, pad_size);
    }
}

/// Converts a UCS2 string (made of simple u16 Unicode codepoints), with each u16 encoded in little
/// endian, into an allocated UTF-8 string
fn ucs2LeToUtf8Alloc(
    allocator: *std.mem.Allocator,
    string: []const u16,
) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();
    for (string) |c| {
        var next = [_]u8{0} ** 4;
        const len = try std.unicode.utf8Encode(std.mem.littleToNative(u16, c), &next);
        try list.appendSlice(next[0..len]);
    }
    return list.toOwnedSlice();
}

/// May return error.OutputTooSmall or error.InvalidCodePoint (if any codepoint is >0xFFFF)
/// Returns first unused index or in other words length of converted memory in u16 words
fn utf8ToUcs2Le(
    in: []const u8,
    out: []u16,
) !usize {
    var i: usize = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = in, .i = 0 };
    while (it.nextCodepoint()) |cp| : (i += 1) {
        if (cp > 0xFFFF)
            return error.InvalidCodePoint;
        if (i >= out.len) {
            return error.OutputTooSmall;
        } else {
            out[i] = std.mem.nativeToLittle(u16, @intCast(u16, cp));
        }
    }
    return i;
}
