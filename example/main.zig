const std = @import("std");
const partition = @import("partition");

const Crc32 = std.hash.Crc32;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = &gpa.allocator;

    const file = try std.fs.cwd().openFile("test.gpt", .{.read = true, .write = false});
    defer file.close();

    var source = std.io.StreamSource{.file = file};
    const device = partition.DeviceParam{
        .total_sectors = 64 * 1024 * 1024 / 512,
        .sector_size = 512,
    };

    std.debug.print("Is valid: {}\n", .{
        try partition.gpt.GptDisk.isValidGpt(allocator, device, &source),
    });

    //std.debug.print("Reading test.gpt (valid GPT test):\n", .{});
    //const gpt = try partition.gpt.GptDisk.read(allocator, device, &source);
    //inline for (std.meta.fields(partition.gpt.GptDisk)) |f| {
    //    std.debug.print("{s} = {any}\n", .{f.name, @field(gpt, f.name)});
    //}
}
