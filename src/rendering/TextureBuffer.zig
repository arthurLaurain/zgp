const TextureBuffer = @This();

const std = @import("std");
const gl = @import("gl");

const SurfaceMesh = @import("../models/surface/SurfaceMesh.zig");
const vec = @import("../geometry/vec.zig");
const Vec3f = vec.Vec3f;
const Data = @import("../utils/data.zig").Data;

index: c_uint = 0,

pub fn init() TextureBuffer {
    var t: TextureBuffer = .{};
    gl.GenTextures(1, (&t.index)[0..1]);
    return t;
}

pub fn memoryAllocationForMapping(t: *TextureBuffer, size: isize) void {
    gl.BindBuffer(gl.TEXTURE_BUFFER, t.index);
    defer gl.BindBuffer(gl.TEXTURE_BUFFER, 0);

    gl.BufferData(gl.TEXTURE_BUFFER, size, null, gl.DYNAMIC_DRAW);
}

pub fn bindBufferToShader(t: *TextureBuffer, texture_unit: u32, srcBuffer: u32, internalFormat: u32) void {
    gl.ActiveTexture(gl.TEXTURE0 + texture_unit);
    gl.BindTexture(gl.TEXTURE_BUFFER, t.index);
    defer gl.BindTexture(gl.TEXTURE_BUFFER, 0);

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
