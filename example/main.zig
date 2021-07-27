const std = @import("std");
const partition = @import("partition");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = &gpa.allocator;
    defer _ = gpa.deinit();

    const device = partition.DeviceParam{
        .total_sectors = 64*1024*1024/512,
        .sector_size = 512,
    };

    var disk = partition.gpt.GptDisk.new(device);
    disk.partitions[0] = partition.gpt.GptPartition{
        .partition_type = partition.gpt.Guid.createRandom(),
        .partition_guid = partition.gpt.Guid.createRandom(),
        .name = "nyaa uwu",
        .starting_lba = 2000,
        .ending_lba = 3000,
        .attributes = .{},
    };

    const file = try std.fs.cwd().createFile("nya.gpt", .{ .read = false });
    defer file.close();
    var stream = std.io.StreamSource{ .file = file };

    try disk.write(allocator, &stream);
}
