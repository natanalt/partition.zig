const std = @import("std");

/// Writes a specified buffer, and pads it with zeroes based on specified alignment/sector_size
pub fn writeSectorsPadWithZeros(
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
