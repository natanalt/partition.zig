# partition.zig
partition.zig is a Zig library for managing partition tables. Note, that it just supports partition
tables, like GPT or MBR, but not individual filesystems, like EXTx, FATx, NTFS, etc.

It should work in Zig 0.8.0 and maybe newer master builds (or 0.9.0+ in the future)

Everything is WIP btw

## Usage
See `example/main.zig` for an example program. You can run it by running `zig build run`.
