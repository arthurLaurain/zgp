const TextureBuffer = @This();

const std = @import("std");
const gl = @import("gl");

const SurfaceMesh = @import("../models/surface/SurfaceMesh.zig");
const vec = @import("../geometry/vec.zig");
const Vec3f = vec.Vec3f;
const Data = @import("../utils/data.zig").Data;

index: c_uint = 0,
allocated_size: usize = 0,

pub fn init() TextureBuffer {
    var t: TextureBuffer = .{};
    gl.GenTextures(1, (&t.index)[0..1]);
    return t;
}

pub fn memoryAllocationForMapping(t: *TextureBuffer, size: isize, internal_format: u32, format: u32, datatype: u32) void {
    if (t.allocated_size != 0) return; // Memory already allocated
    gl.BindBuffer(gl.TEXTURE_BUFFER, t.index);
    defer gl.BindBuffer(gl.TEXTURE_BUFFER, 0);
    gl.BufferData(gl.TEXTURE_BUFFER, size, null, gl.DYNAMIC_DRAW);
    gl.ClearBufferData(
        gl.TEXTURE_BUFFER,
        internal_format,
        format,
        datatype,
        null,
    );
    t.allocated_size = @intCast(size);
}

pub fn bindBufferToShader(t: *TextureBuffer, texture_unit: u32, srcBuffer: u32, internalFormat: u32) void {
    gl.ActiveTexture(gl.TEXTURE0 + texture_unit);
    gl.BindTexture(gl.TEXTURE_BUFFER, t.index);

    gl.TexBuffer(
        gl.TEXTURE_BUFFER,
        internalFormat,
        srcBuffer,
    );
}

pub fn deinit(t: *TextureBuffer) void {
    if (t.index != 0) {
        gl.DeleteTextures(1, (&t.index)[0..1]);
        t.index = 0;
    }
}
