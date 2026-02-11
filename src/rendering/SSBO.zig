const SSBO = @This();
const std = @import("std");
const gl = @import("zgl");
const SurfaceMesh = @import("../models/surface/SurfaceMesh.zig");

const Data = @import("../utils/Data.zig").Data;

index: c_uint = 0,

pub fn init() SSBO {
    var s: SSBO = .{};
    gl.GenBuffers(1, (&s.index)[0..1]);
    return s;
}

pub fn deinit(s: *SSBO) void {
    if (s.index != 0) {
        gl.DeleteBuffers(1, (&s.index)[0..1]);
        s.index = 0;
    }
}
