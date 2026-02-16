const Texture2D = @This();

const std = @import("std");
const zstbi = @import("zstbi");
const gl = @import("gl");

index: c_uint = 0,
multisample: bool = false,
samples: c_int = 0,
width: u32 = 0,
height: u32 = 0,

pub const Parameter = struct {
    name: c_uint,
    value: c_int,
};

pub fn init(multisample: bool, samples: c_int, parameters: []const Parameter) Texture2D {
    var t: Texture2D = .{
        .multisample = multisample,
        .samples = samples,
    };

    gl.GenTextures(1, (&t.index)[0..1]);
    gl.BindTexture(if (multisample) gl.TEXTURE_2D_MULTISAMPLE else gl.TEXTURE_2D, t.index);
    defer gl.BindTexture(if (multisample) gl.TEXTURE_2D_MULTISAMPLE else gl.TEXTURE_2D, 0);
    for (parameters) |param| {
        gl.TexParameteri(
            if (multisample) gl.TEXTURE_2D_MULTISAMPLE else gl.TEXTURE_2D,
            param.name,
            param.value,
        );
    }
    return t;
}

pub fn loadFromFile(t: *Texture2D, filename: [:0]const u8) !void {
    var tex_image = zstbi.Image.loadFromFile(filename, 3) catch |err|
        {
            std.debug.print("Failed to load texture: {s}\n", .{filename});
            return err;
        };
    defer tex_image.deinit();

    gl.BindTexture(gl.TEXTURE_2D, t.index);
    defer gl.BindTexture(gl.TEXTURE_2D, 0);

    t.width = tex_image.width;
    t.height = tex_image.height;
    gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA, @intCast(tex_image.width), @intCast(tex_image.height), 0, gl.RGB, gl.UNSIGNED_BYTE, @ptrCast(tex_image.data));
    gl.GenerateMipmap(gl.TEXTURE_2D);
}

pub fn deinit(t: *Texture2D) void {
    if (t.index != 0) {
        gl.DeleteTextures(1, (&t.index)[0..1]);
        t.index = 0;
    }
}

pub fn resize(t: *Texture2D, width: c_int, height: c_int, internal_format: c_uint, format: c_uint, datatype: c_uint) void {
    gl.BindTexture(if (t.multisample) gl.TEXTURE_2D_MULTISAMPLE else gl.TEXTURE_2D, t.index);
    defer gl.BindTexture(if (t.multisample) gl.TEXTURE_2D_MULTISAMPLE else gl.TEXTURE_2D, 0);
    if (t.multisample) {
        gl.TexImage2DMultisample(
            gl.TEXTURE_2D_MULTISAMPLE,
            t.samples,
            @intCast(internal_format),
            width,
            height,
            gl.TRUE,
        );
    } else {
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
}
