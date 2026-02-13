const SSBO = @This();
const std = @import("std");
const gl = @import("gl");
const SurfaceMesh = @import("../models/surface/SurfaceMesh.zig");
const vec = @import("../geometry/vec.zig");
const Vec3f = vec.Vec3f;
const Data = @import("../utils/Data.zig").Data;

index: c_uint = 0,

pub fn init() SSBO {
    var s: SSBO = .{};

    gl.GenBuffers(1, (&s.index)[0..1]);
    return s;
}

// Operation creates a full copy of the buffer content, use for debug only
pub fn copyDataFromBufferObject(s: *SSBO, srcBuffer: u32, size: isize) void {
    gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, s.index);
    gl.BufferData(gl.SHADER_STORAGE_BUFFER, size, null, gl.DYNAMIC_COPY);

    gl.BindBuffer(gl.COPY_READ_BUFFER, srcBuffer);
    gl.BindBuffer(gl.COPY_WRITE_BUFFER, s.index);

    gl.CopyBufferSubData(
        gl.COPY_READ_BUFFER,
        gl.COPY_WRITE_BUFFER,
        0,
        0,
        size,
    );

    gl.BindBuffer(gl.COPY_READ_BUFFER, 0);
    gl.BindBuffer(gl.COPY_WRITE_BUFFER, 0);
}

pub fn print(s: *SSBO, rawSize: usize, T: type) void {
    gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, s.index);
    defer gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0);
    const ptr = gl.MapBuffer(
        gl.SHADER_STORAGE_BUFFER,
        gl.READ_ONLY,
    );
    if (ptr == null) unreachable;

    const data: [*]T = @ptrCast(@alignCast(ptr));

    switch (T) {
        u32 => {
            const size = rawSize / @sizeOf(u32);
            for (data[0..size], 0..) |v, i| {
                std.debug.print("ssbo[{d}] = {d}\n", .{ i, v });
            }
        },

        Vec3f => {
            const size = rawSize / @sizeOf(Vec3f);
            for (data[0..size], 0..) |v, i| {
                std.debug.print("ssbo[{d}] = {d} {d} {d}\n", .{ i, v[0], v[1], v[2] });
            }
        },

        else => @compileError("Unsupported type for SSBO debug print"),
    }
    _ = gl.UnmapBuffer(gl.SHADER_STORAGE_BUFFER);
}
pub fn bindBufferToShader(s: *SSBO, binding_id: u32, srcBuffer: u32) void {
    gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, s.index);
    defer gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0);
    gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, binding_id, srcBuffer);
}

pub fn deinit(s: *SSBO) void {
    if (s.index != 0) {
        gl.DeleteBuffers(1, (&s.index)[0..1]);
        s.index = 0;
    }
}
