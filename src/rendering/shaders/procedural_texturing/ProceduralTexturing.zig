const ProceduralTexturing = @This();

const zstbi = @import("zstbi");
const std = @import("std");
const gl = @import("gl");

const Shader = @import("../../Shader.zig");
const VAO = @import("../../VAO.zig");
const VBO = @import("../../VBO.zig");
const IBO = @import("../../IBO.zig");
const TEXTURE2D = @import("../../Texture2D.zig");

var global_instance: ProceduralTexturing = undefined;
var init_global_once = std.once(init_global);
fn init_global() void {
    global_instance = init() catch unreachable;
}
pub fn instance() *ProceduralTexturing {
    init_global_once.call();
    return &global_instance;
}

program: Shader,

model_view_matrix_uniform: c_int = undefined,
projection_matrix_uniform: c_int = undefined,
ambiant_color_uniform: c_int = undefined,
light_position_uniform: c_int = undefined,
id_exemplar_texture: c_int = undefined,

position_attrib: VAO.VertexAttribInfo = undefined,

const VertexAttrib = enum {
    position,
};

fn init() !ProceduralTexturing {
    var pt: ProceduralTexturing = .{
        .program = Shader.init(),
    };

    const vertex_shader_source = @embedFile("vs.glsl");
    const fragment_shader_source = @embedFile("fs.glsl");

    try pt.program.setShader(.vertex, vertex_shader_source);
    try pt.program.setShader(.fragment, fragment_shader_source);
    try pt.program.linkProgram();

    pt.model_view_matrix_uniform = gl.GetUniformLocation(pt.program.index, "u_model_view_matrix");
    pt.projection_matrix_uniform = gl.GetUniformLocation(pt.program.index, "u_projection_matrix");
    pt.ambiant_color_uniform = gl.GetUniformLocation(pt.program.index, "u_ambiant_color");
    pt.light_position_uniform = gl.GetUniformLocation(pt.program.index, "u_light_position");
    pt.id_exemplar_texture = gl.GetUniformLocation(pt.program.index, "u_exemplar_texture");
    pt.position_attrib = .{
        .index = @intCast(gl.GetAttribLocation(pt.program.index, "a_position")),
        .size = 3,
        .type = gl.FLOAT,
        .normalized = false,
    };

    return pt;
}

pub fn deinit(tf: *ProceduralTexturing) void {
    tf.program.deinit();
}

pub const Parameters = struct {
    shader: *const ProceduralTexturing,
    vao: VAO,
    exemplar_texture: TEXTURE2D,
    model_view_matrix: [16]f32 = undefined,
    projection_matrix: [16]f32 = undefined,
    ambiant_color: [4]f32 = .{ 0.1, 0.1, 0.1, 1 },
    light_position: [3]f32 = .{ 10, 0, 100 },

    pub fn init() Parameters {
        return .{
            .shader = instance(),
            .vao = VAO.init(),
            .exemplar_texture = TEXTURE2D.init(&[_]TEXTURE2D.Parameter{
                .{ .name = gl.TEXTURE_WRAP_S, .value = gl.REPEAT },
                .{ .name = gl.TEXTURE_WRAP_T, .value = gl.REPEAT },
                .{ .name = gl.TEXTURE_MIN_FILTER, .value = gl.NEAREST },
                .{ .name = gl.TEXTURE_MAG_FILTER, .value = gl.LINEAR },
            }),
        };
    }

    pub fn deinit(p: *Parameters) void {
        p.vao.deinit();
    }

    pub fn setVertexAttribArray(p: *Parameters, attrib: VertexAttrib, vbo: VBO, stride: isize, pointer: usize) void {
        const attrib_info = switch (attrib) {
            .position => p.shader.position_attrib,
        };
        p.vao.enableVertexAttribArray(attrib_info, vbo, stride, pointer);
    }
    pub fn unsetVertexAttribArray(p: *Parameters, attrib: VertexAttrib) void {
        const attrib_info = switch (attrib) {
            .position => p.shader.position_attrib,
        };
        p.vao.disableVertexAttribArray(attrib_info);
    }

    pub fn draw(p: *Parameters, ibo: IBO) void {
        gl.UseProgram(p.shader.program.index);
        defer gl.UseProgram(0);
        gl.ActiveTexture(gl.TEXTURE0);
        gl.BindTexture(gl.TEXTURE_2D, p.exemplar_texture.index);
        gl.Uniform1ui(p.shader.id_exemplar_texture, 0);
        gl.Uniform4fv(p.shader.ambiant_color_uniform, 1, @ptrCast(&p.ambiant_color));
        gl.Uniform3fv(p.shader.light_position_uniform, 1, @ptrCast(&p.light_position));
        gl.UniformMatrix4fv(p.shader.model_view_matrix_uniform, 1, gl.FALSE, @ptrCast(&p.model_view_matrix));
        gl.UniformMatrix4fv(p.shader.projection_matrix_uniform, 1, gl.FALSE, @ptrCast(&p.projection_matrix));
        gl.BindVertexArray(p.vao.index);
        defer gl.BindVertexArray(0);
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ibo.index);
        defer gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, 0);
        gl.DrawElements(gl.TRIANGLES, @intCast(ibo.nb_indices), gl.UNSIGNED_INT, 0);
    }
};
