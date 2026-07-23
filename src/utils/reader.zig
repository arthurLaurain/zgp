const c = @import("c");
const std = @import("std");

const zstbi = @import("zstbi");

pub const AnyImage = union(enum) {
    png: Image(u8),
    exr: Image(f32),
};

const FileOpenError = error{
    FormatNotSupported,
};

pub fn Image(comptime T: type) type {
    return struct {
        height: u32,
        width: u32,
        data: []T,
    };
}

pub fn loadFile(filename: [:0]u8, allocator: std.mem.Allocator) !AnyImage {
    const extension = std.fs.path.extension(filename);
    if (std.mem.eql(u8, extension, ".png")) {
        return loadPNG(filename, allocator) catch unreachable;
    } else if (std.mem.eql(u8, extension, ".exr")) {
        return loadEXR(filename.ptr);
    }
    std.log.debug("Error: file format not supported\n", .{});
    return FileOpenError.FormatNotSupported;
}
fn loadEXR(filename: [*:0]u8) AnyImage {
    var image = Image(f32){
        .height = 0,
        .width = 0,
        .data = &[_]f32{},
    };

    c.loadExr(
        filename,
        @ptrCast(&image.width),
        @ptrCast(&image.height),
        @ptrCast(&image.data),
    );
    return .{ .exr = image };
}

fn loadPNG(filename: [:0]const u8, allocator: std.mem.Allocator) !AnyImage {
    var tex_image = try zstbi.Image.loadFromFile(filename, 3);
    defer zstbi.Image.deinit(&tex_image);
    const img = Image(u8){
        .height = tex_image.height,
        .width = tex_image.width,
        .data = allocator.dupe(u8, tex_image.data) catch unreachable,
    };

    return .{ .png = img };
}
