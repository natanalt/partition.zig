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
    placement: struct {
        primary_header_lba: u64,
        primary_table_lba: u64,
        backup_header_lba: u64,
        backup_table_lba: u64,
        partition_entry_size: u64,
    },

    /// Only used by GptDisk.read()
    read_warnings: ReadWarnings = .{},

    pub fn new(device: DeviceParam) GptDisk {
        return .{
            .device = device,
            .disk_guid = Guid.createRandom(),
            .partitions = [_]?GptPartition{null} ** max_partitions,
            .placement = .{
                .primary_header_lba = 1,
                .primary_table_lba = 2,
                .backup_header_lba = device.total_sectors - 1,
                .backup_table_lba = blk: {
                    const partition_table_sectors = std.math.divCeil(
                        u64, 
                        @sizeOf(raw.PartitionEntry) * max_partitions,
                        device.sector_size,
                    ) catch unreachable;
                    break :blk device.total_sectors - partition_table_sectors - 1;
                },
                .partition_entry_size = @sizeOf(raw.PartitionEntry),
            }
        };
    }

    pub fn read(
        allocator: *std.mem.Allocator,
        device: DeviceParam,
        stream: *std.io.StreamSource,
    ) !GptDisk {

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
        ) catch blk: {
            read_warnings.primary_gpt_corrupt = true;
            break :blk null;
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
        ) catch blk: {
            read_warnings.backup_gpt_corrupt = true;
            break :blk null;
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
                    .name = try std.unicode.utf16leToUtf8Alloc(allocator, for (raw_entry.partition_name) |v, j| {
                        if (v == 0)
                            break raw_entry.partition_name[0..j];
                    } else &raw_entry.partition_name),
                };
            }   
        }

        return result;
    }

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

    pub fn write(self: GptDisk, stream: *std.io.StreamSource) !void {
        const writer = stream.writer();
        const seekable = stream.seekableStream();
        @compileError("nya uwu");
    }

};

pub const GptPartition = struct {
    pub const Attributes = struct {
        required_by_system: bool,
        no_block_io: bool,
        legacy_boot: bool,
        fs_reserved: u16,

        pub fn pack(self: Attributes) u64 {
            var result: u64 = 0;
            result |= if (self.required_by_system) 1 << 0 else 0;
            result |= if (self.no_block_io) 1 << 1 else 0;
            result |= if (self.legacy_boot) 1 << 2 else 0;
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

    pub fn fromReader(
        comptime T: type,
        reader: anytype
    ) !T {
        var bytes: [@sizeOf(T)]u8 = undefined;
        const n = try reader.read(&bytes);
        if (n != bytes.len) {
            return error.UnexpectedEof;
        }
        return fromBytes(T, &bytes);
    }

    pub fn toWriter(
        comptime T: type,
        value: T,
        writer: anytype,
    ) !void {
        const bytes = toBytes(T, value);
        try writer.writeAll(&bytes);
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

    pub fn read(
        allocator: *std.mem.Allocator,
        device: DeviceParam,
        stream: *std.io.StreamSource,
        header_lba: u64,
    ) !RawGpt {
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
            return error.InvalidSignature;
        if (header.header_crc32 != self.getHeaderCrc())
            return error.InvalidHeaderCrc32;
        if (!std.mem.eql(u8, &header.revision, &raw.Header.valid_revision))
            return error.InvalidRevision;
        if (header.my_lba != header_lba)
            return error.InvalidMyLba;
        
        const pea_size = header.size_of_partition_entry * header.number_of_partition_entries;
        self.raw_pea = try allocator.alloc(u8, pea_size);
        errdefer allocator.free(self.raw_pea);
        try stream.seekTo(try device.lbaToOffset(header.partition_entry_lba));
        try readFullOrError(stream.reader(), self.raw_pea);

        if (header.partition_entry_array_crc32 != std.hash.Crc32.hash(self.raw_pea))
            return error.InvalidTableCrc32;

        return self;
    }

    pub fn getHeader(self: Self) raw.Header {
        return raw.fromBytes(raw.Header, self.raw_header[0..@sizeOf(raw.Header)]);
    }

    pub fn getHeaderCrc(self: Self) u32 {
        const header = std.mem.bytesAsValue(raw.Header, self.raw_header[0..@sizeOf(raw.Header)]);
        const old_crc = header.header_crc32;
        header.header_crc32 = 0;
        const hash = std.hash.Crc32.hash(self.raw_header[0..self.getHeader().header_size]);
        header.header_crc32 = old_crc;
        return hash;
    }

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

fn readFullOrError(
    reader: anytype,
    buf: []u8,
) !void {
    const n = try reader.read(buf);
    if (n != buf.len)
        return error.UnexpectedEof;
}
