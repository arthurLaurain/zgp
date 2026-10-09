const TextureBuffer = @This();

const std = @import("std");
const gl = @import("gl");

const SurfaceMesh = @import("../models/surface/SurfaceMesh.zig");
const vec = @import("../geometry/vec.zig");
const Vec3f = vec.Vec3f;
const Data = @import("../utils/data.zig").Data;

texture_index: c_uint = 0,
buffer_index: c_uint = 0,
own_buffer: bool = false,

pub fn init() TextureBuffer {
    var t: TextureBuffer = .{};

    gl.GenTextures(1, (&t.texture_index)[0..1]);

    return t;
}

pub fn bufferMemoryAllocation(t: *TextureBuffer, size: isize, internal_format: u32, format: u32, datatype: u32) void {
    gl.GenBuffers(1, (&t.buffer_index)[0..1]);
    t.own_buffer = true;
    gl.BindBuffer(gl.TEXTURE_BUFFER, t.buffer_index);
    defer gl.BindBuffer(gl.TEXTURE_BUFFER, 0);
    gl.BufferData(gl.TEXTURE_BUFFER, size, null, gl.DYNAMIC_DRAW);
    gl.ClearBufferData(gl.TEXTURE_BUFFER, internal_format, format, datatype, null);
    gl.BindTexture(gl.TEXTURE_BUFFER, t.texture_index);
    defer gl.BindTexture(gl.TEXTURE_BUFFER, 0);
    gl.TexBuffer(gl.TEXTURE_BUFFER, internal_format, t.buffer_index);
}

pub fn clearBuffer(t: *TextureBuffer, internal_format: u32, format: u32, datatype: u32) void {
    gl.BindBuffer(gl.TEXTURE_BUFFER, t.buffer_index);
    defer gl.BindBuffer(gl.TEXTURE_BUFFER, 0);
    gl.ClearBufferData(gl.TEXTURE_BUFFER, internal_format, format, datatype, null);
}

pub fn updateTextureBufferObject(tbo: *TextureBuffer, index: usize, comptime T: type, value: T) void {
    const offset = index * @sizeOf(T);
    const size = @sizeOf(T);

    gl.BindBuffer(gl.TEXTURE_BUFFER, tbo.buffer_index);
    defer gl.BindBuffer(gl.TEXTURE_BUFFER, 0);

    gl.BufferSubData(gl.TEXTURE_BUFFER, @intCast(offset), @intCast(size), @ptrCast(&value));
}

pub fn bindBufferToShader(t: *TextureBuffer, texture_unit: u32, srcBuffer: u32, internalFormat: u32) void {
    t.buffer_index = srcBuffer;
    gl.ActiveTexture(gl.TEXTURE0 + texture_unit);
    gl.BindTexture(gl.TEXTURE_BUFFER, t.texture_index);
    gl.TexBuffer(gl.TEXTURE_BUFFER, internalFormat, srcBuffer);
}

pub fn deinit(t: *TextureBuffer) void {
    if (t.own_buffer and t.buffer_index != 0) {
        gl.DeleteBuffers(1, (&t.buffer_index)[0..1]);
        t.buffer_index = 0;
    }

    if (t.texture_index != 0) {
        gl.DeleteTextures(1, (&t.texture_index)[0..1]);
        t.texture_index = 0;
    }
}
