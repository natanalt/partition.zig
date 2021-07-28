//! # partition.zig - a partitioning library
//! partition.zig is a partitioning library for Zig. It provides implementations
//! of various partition tables and lets you read, create and modify them.
//!
//! by Natalia Cholewa
//! Project repository: https://github.com/natanalt/partition.zig
//! Version: 0.1.0
//!

const std = @import("std");

pub const gpt = @import("gpt.zig");

pub const lib_version = std.builtin.Version{
    .major = 0,
    .minor = 1,
    .patch = 0,
};

pub const DeviceParam = struct {
    total_sectors: u64,
    sector_size: u64,

    pub fn lbaToOffset(self: DeviceParam, lba: u64) !u64 {
        return if (lba < self.total_sectors)
            self.sector_size * lba
        else
            error.OutOfBounds;
    }

    pub fn sectorAlignSize(self: DeviceParam, size: u64) u64 {
        return std.mem.alignForwardGeneric(u64, size, self.sector_size);
    }
};

pub const PartitionTableKind = enum {
    gpt,
};

pub const PartitionTable = union(PartitionTableKind) {
    gpt: gpt.GptDisk,
};

pub fn readPartitionTable(
    allocator: *std.mem.Allocator,
    device: DeviceParam,
    stream: *std.io.StreamSource,
) !?PartitionTable {

    const gpt_disk: ?gpt.Disk = gpt.GptDisk.read(allocator, device, stream) catch null;
    if (gpt_disk) |gd| return PartitionTable{ .gpt = gd };

    return null;
}

pub fn checkPartitionTable(
    allocator: *std.mem.Allocator,
    device: DeviceParam,
    stream: *std.io.StreamSource,
) !?PartitionTableKind {
    return if (try gpt.GptDisk.isValidGpt(allocator, device, stream))
        .gpt
    else
        null;
}

test {
    std.testing.refAllDecls(@This());
}
