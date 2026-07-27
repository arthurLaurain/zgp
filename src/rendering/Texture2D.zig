const Texture2D = @This();

const std = @import("std");
const zstbi = @import("zstbi");
const gl = @import("gl");
const Reader = @import("../utils/reader.zig");
index: c_uint = 0,
width: u32 = 0,
height: u32 = 0,

pub const Parameter = struct {
    name: c_uint,
    value: c_int,
};

pub fn init(parameters: []const Parameter) Texture2D {
    var t: Texture2D = .{};
    gl.GenTextures(1, (&t.index)[0..1]);
    gl.BindTexture(gl.TEXTURE_2D, t.index);
    defer gl.BindTexture(gl.TEXTURE_2D, 0);
    for (parameters) |param| {
        gl.TexParameteri(gl.TEXTURE_2D, param.name, param.value);
    }
    return t;
}

pub fn loadFromFile(t: *Texture2D, filename: [:0]u8, allocator: std.mem.Allocator) void {
    const tex_image = Reader.loadFile(filename, allocator) catch unreachable;
    gl.BindTexture(gl.TEXTURE_2D, t.index);
    defer gl.BindTexture(gl.TEXTURE_2D, 0);
    switch (tex_image) {
        .png => |img| {
            t.width = img.width;
            t.height = img.height;
            gl.TexImage2D(
                gl.TEXTURE_2D,
                0,
                gl.RGB,
                @intCast(img.width),
                @intCast(img.height),
                0,
                gl.RGB,
                gl.UNSIGNED_SHORT,
                @ptrCast(img.data.ptr),
            );

            allocator.free(img.data);
        },

        .exr => |img| {
            t.width = img.width;
            t.height = img.height;

            gl.TexImage2D(
                gl.TEXTURE_2D,
                0,
                gl.RGBA32F,
                @intCast(img.width),
                @intCast(img.height),
                0,
                gl.RGBA,
                gl.FLOAT,
                @ptrCast(img.data.ptr),
            );

            allocator.free(img.data);
        },
    }

    gl.GenerateMipmap(gl.TEXTURE_2D);
}

pub fn deinit(t: *Texture2D) void {
    if (t.index != 0) {
        gl.DeleteTextures(1, (&t.index)[0..1]);
        t.index = 0;
    }
}

pub fn resize(t: *Texture2D, width: c_int, height: c_int, internal_format: c_uint, format: c_uint, datatype: c_uint) void {
    gl.BindTexture(gl.TEXTURE_2D, t.index);
    defer gl.BindTexture(gl.TEXTURE_2D, 0);
    gl.TexImage2D(
        gl.TEXTURE_2D,
        0,
        @intCast(internal_format),
        width,
        height,
        0,
        format,
        datatype,
        null,
    );
}
