const std = @import("std");
const partition = @import("partition");

test "GPT read test" {
    // The image is just 10 MiB, it'll be fine to add it in
    const image_data = @embedFile("gpt-test-image.img");
    const sector_size = 512;
    var stream = std.io.StreamSource{ .const_buffer = std.io.fixedBufferStream(image_data) };

    const table = (try partition.readPartitionTable(std.testing.allocator, partition.DeviceParam{
        .sector_size = sector_size,
        .total_sectors = try std.math.divExact(u64, image_data.len, sector_size),
    }, &stream)) orelse return error.NoPartitionTablesDetected;

    try std.testing.expectEqual(partition.PartitionTableKind.gpt, table);
    const gpt_table = table.gpt;
    defer gpt_table.deinit(std.testing.allocator);

    try std.testing.expect(!gpt_table.read_warnings.backup_gpt_corrupt);
    try std.testing.expect(!gpt_table.read_warnings.primary_gpt_corrupt);
    try std.testing.expect(gpt_table.read_warnings.isEverythingOk());

    try std.testing.expectEqualSlices(u8, &[16]u8{
        0xAA, 0xA2, 0x48, 0x4E,
        0xF9, 0xCC, 0x47, 0x5B,
        0x83, 0x14, 0x34, 0x5F,
        0xFC, 0x93, 0x55, 0xBA,
    }, &gpt_table.disk_guid.data);

    try std.testing.expectEqual(@as(u64, 2048), gpt_table.first_usable_lba);
    try std.testing.expectEqual(@as(u64, 20446), gpt_table.last_usable_lba);
    try std.testing.expectEqual(@as(u64, 1), gpt_table.placement.primary_header_lba);
    try std.testing.expectEqual(@as(u64, 2), gpt_table.placement.primary_table_lba);
    try std.testing.expectEqual(@as(u64, 20479), gpt_table.placement.backup_header_lba);
    try std.testing.expectEqual(@as(u64, 20447), gpt_table.placement.backup_table_lba);
    try std.testing.expectEqual(@as(u32, 128), gpt_table.placement.partition_entry_size);

    for (gpt_table.partitions) |partition_opt, i| {
        switch (i) {
            0 => {
                try std.testing.expect(partition_opt != null);
                const part = partition_opt.?;

                try std.testing.expectEqual(@as(u64, 3000), part.starting_lba);
                try std.testing.expectEqual(@as(u64, 8000), part.ending_lba);
                try std.testing.expectEqualStrings("Hello1", part.name);
                try std.testing.expectEqual(false, part.attributes.legacy_boot);
                try std.testing.expectEqual(false, part.attributes.no_block_io);
                try std.testing.expectEqual(true, part.attributes.required_by_system);
                try std.testing.expectEqual(@as(u16, 0x0001), part.attributes.fs_reserved);

                try std.testing.expectEqualSlices(u8, &[16]u8{
                    0xF1, 0x55, 0x36, 0x21,
                    0xA3, 0xA4, 0x4D, 0x15,
                    0xB9, 0x4B, 0x6E, 0x9C,
                    0x6C, 0x50, 0x65, 0xE3,
                }, &part.partition_guid.data);

                try std.testing.expectEqualSlices(u8, &[16]u8{
                    0xAF, 0x3D, 0xC6, 0x0F,
                    0x83, 0x84, 0x72, 0x47,
                    0x8E, 0x79, 0x3D, 0x69,
                    0xD8, 0x47, 0x7D, 0xE4,
                }, &part.partition_type.data);
            },
            2 => {
                try std.testing.expect(partition_opt != null);
                const part = partition_opt.?;

                try std.testing.expectEqual(@as(u64, 8192), part.starting_lba);
                try std.testing.expectEqual(@as(u64, 20446), part.ending_lba);
                try std.testing.expectEqualStrings("Trans Rights", part.name);
                try std.testing.expectEqual(true, part.attributes.legacy_boot);
                try std.testing.expectEqual(true, part.attributes.no_block_io);
                try std.testing.expectEqual(false, part.attributes.required_by_system);
                try std.testing.expectEqual(@as(u16, 0x0000), part.attributes.fs_reserved);

                try std.testing.expectEqualSlices(u8, &[16]u8{
                    0x3A, 0x5A, 0xF3, 0xBC,
                    0x58, 0xC2, 0x4D, 0xB5,
                    0x9C, 0x52, 0x13, 0x82,
                    0x78, 0x9D, 0x29, 0x27,
                }, &part.partition_guid.data);

                try std.testing.expectEqualSlices(u8, &[16]u8{
                    0x28, 0x73, 0x2A, 0xC1,
                    0x1F, 0xF8, 0xD2, 0x11,
                    0xBA, 0x4B, 0x00, 0xA0,
                    0xC9, 0x3E, 0xC9, 0x3B,
                }, &part.partition_type.data);
            },
            else => try std.testing.expect(partition_opt == null),
        }
    }
}
