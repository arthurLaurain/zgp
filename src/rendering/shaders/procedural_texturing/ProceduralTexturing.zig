const ProceduralTexturing = @This();

const zstbi = @import("zstbi");
const std = @import("std");
const gl = @import("gl");

const Shader = @import("../../Shader.zig");
const VAO = @import("../../VAO.zig");
const VBO = @import("../../VBO.zig");
const IBO = @import("../../IBO.zig");
const TEXTURE2D = @import("../../Texture2D.zig");
const SSBO = @import("../../SSBO.zig");

const vec = @import("../../../geometry/vec.zig");
const Vec3f = vec.Vec3f;

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
exemplar_texture_uniform: c_int = undefined,
scale_tex_coords_uniform: c_int = undefined,
u_scale_distorsion_uniform: c_int = undefined,
visu_rotate_dist_uniform: c_int = undefined,
visu_stretch_dist_uniform: c_int = undefined,

position_attrib: VAO.VertexAttribInfo = undefined,
vector_attrib: VAO.VertexAttribInfo = undefined,

const VertexAttrib = enum {
    position,
    vector,
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
    pt.exemplar_texture_uniform = gl.GetUniformLocation(pt.program.index, "u_exemplar_texture");
    pt.scale_tex_coords_uniform = gl.GetUniformLocation(pt.program.index, "u_scale_tex_coords");
    pt.u_scale_distorsion_uniform = gl.GetUniformLocation(pt.program.index, "u_scale_distorsion");
    pt.visu_rotate_dist_uniform = gl.GetUniformLocation(pt.program.index, "u_visu_rotation_distorsion");
    pt.visu_stretch_dist_uniform = gl.GetUniformLocation(pt.program.index, "u_visu_stretch_distorsion");
    pt.position_attrib = .{
        .index = @intCast(gl.GetAttribLocation(pt.program.index, "a_position")),
        .size = 3,
        .type = gl.FLOAT,
        .normalized = false,
    };
    // pt.vector_attrib = .{
    //     .index = @intCast(gl.GetAttribLocation(pt.program.index, "a_edge_ref")),
    //     .size = 3,
    //     .type = gl.FLOAT,
    //     .normalized = false,
    // };
    return pt;
}

pub fn deinit(tf: *ProceduralTexturing) void {
    tf.program.deinit();
}

pub const Parameters = struct {
    shader: *ProceduralTexturing,
    vao: VAO,
    exemplar_texture: TEXTURE2D,
    model_view_matrix: [16]f32 = undefined,
    projection_matrix: [16]f32 = undefined,
    ambiant_color: [4]f32 = .{ 0.1, 0.1, 0.1, 1 },
    light_position: [3]f32 = .{ 10, 0, 100 },
    ssbo_info_triangles: SSBO = undefined,
    ssbo_info_vertices: SSBO = undefined,
    ssbo_edge_ref: SSBO = undefined,
    ssbo_normal_vertices: SSBO = undefined,
    ssbo_distorsion_primitives: SSBO = undefined,
    vertices_normal_vbo: VBO = undefined,
    vertices_position_vbo: VBO = undefined,
    edge_ref_vbo: VBO = undefined,
    scale_tex_coords: f32 = 1,
    scale_distorsion: f32 = 1,
    visu_rotate_dist: bool = false,
    visu_scale_dist: bool = false,

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
        p.ssbo_info_triangles.deinit();
        p.ssbo_info_vertices.deinit();
        p.ssbo_edge_ref.deinit();
        p.ssbo_normal_vertices.deinit();
        p.ssbo_distorsion_primitives.deinit();
        // p.vertices_position_vbo.deinit();
    }

    pub fn setVertexAttribArray(p: *Parameters, attrib: VertexAttrib, vbo: VBO, stride: isize, pointer: usize) void {
        const attrib_info = switch (attrib) {
            .position => p.shader.position_attrib,
            .vector => p.shader.vector_attrib,
        };
        p.vao.enableVertexAttribArray(attrib_info, vbo, stride, pointer);
    }
    pub fn unsetVertexAttribArray(p: *Parameters, attrib: VertexAttrib) void {
        const attrib_info = switch (attrib) {
            .position => p.shader.position_attrib,
            .vector => p.shader.vector_attrib,
        };
        p.vao.disableVertexAttribArray(attrib_info);
    }

    pub fn computeDistorsion(p: *Parameters, id_triangle: [3]u32, vbo_position: [*]Vec3f, vbo_normal: [*]Vec3f) [4]f32 {
        const p1: [3]f32 = .{ vbo_position[id_triangle[0] * 3], vbo_position[id_triangle[0] * 3 + 1], vbo_position[id_triangle[0] * 3 + 2] };
        const p2: [3]f32 = .{ vbo_position[id_triangle[1] * 3], vbo_position[id_triangle[1] * 3 + 1], vbo_position[id_triangle[1] * 3 + 2] };
        const p3: [3]f32 = .{ vbo_position[id_triangle[2] * 3], vbo_position[id_triangle[2] * 3 + 1], vbo_position[id_triangle[2] * 3 + 2] };

        const n1: [3]f32 = .{ vbo_normal[id_triangle[0] * 3], vbo_normal[id_triangle[0] * 3 + 1], vbo_normal[id_triangle[0] * 3 + 2] };
        const n2: [3]f32 = .{ vbo_normal[id_triangle[1] * 3], vbo_normal[id_triangle[1] * 3 + 1], vbo_normal[id_triangle[1] * 3 + 2] };
        const n3: [3]f32 = .{ vbo_normal[id_triangle[2] * 3], vbo_normal[id_triangle[2] * 3 + 1], vbo_normal[id_triangle[2] * 3 + 2] };
    }

    pub fn fillDistorsionSSBO(p: *Parameters, ssbo: *SSBO, ibo: *IBO) void {

        // vertices position
        gl.BindBuffer(gl.ARRAY_BUFFER, p.vertices_position_vbo.index);
        const ptr_vbo_position = gl.MapBuffer(gl.ARRAY_BUFFER, gl.READ_ONLY);
        const array_vbo_position: [*]Vec3f = @ptrCast(@alignCast(ptr_vbo_position));
        gl.BindBuffer(gl.ARRAY_BUFFER, 0);

        // id vertices per triangle
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ibo.index);
        const ptr_ibo = gl.MapBuffer(gl.ELEMENT_ARRAY_BUFFER, gl.READ_ONLY);
        const array_ibo: [*]u32 = @ptrCast(@alignCast(ptr_ibo));
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, 0);

        // vertices normal
        gl.BindBuffer(gl.ARRAY_BUFFER, p.vertices_normal_vbo.index);
        const ptr_vbo_normal = gl.MapBuffer(gl.ARRAY_BUFFER, gl.READ_ONLY);
        const array_vbo_normal: [*]Vec3f = @ptrCast(@alignCast(ptr_vbo_normal));
        gl.BindBuffer(gl.ARRAY_BUFFER, 0);

        // empty SSBO to fill
        gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, ssbo.index);
        defer gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0);
        const ptr_ssbo = gl.MapBuffer(gl.SHADER_STORAGE_BUFFER, gl.WRITE_ONLY);
        const array_ssbo: [*]f32 = @ptrCast(@alignCast(ptr_ssbo));

        const nb_triangle: usize = ibo.nb_indices / 3; // Only for triangles

        for (0..nb_triangle) |i| {
            const id_triangle: [3]u32 = array_ibo[i][0..3].*;
            const distorsion: [4]f32 = computeDistorsion(id_triangle, array_vbo_position, array_vbo_normal);
            array_ssbo[i][0..4].* = distorsion;
            i = i + 4;
        }
    }

    pub fn draw(p: *Parameters, ibo: IBO) void {
        gl.UseProgram(p.shader.program.index);
        defer gl.UseProgram(0);
        gl.ActiveTexture(gl.TEXTURE0);
        gl.BindTexture(gl.TEXTURE_2D, p.exemplar_texture.index);
        p.ssbo_info_vertices.bindBufferToShader(0, ibo.index);
        p.ssbo_info_triangles.bindBufferToShader(1, p.vertices_position_vbo.index);
        p.ssbo_edge_ref.bindBufferToShader(2, p.edge_ref_vbo.index);
        p.ssbo_normal_vertices.bindBufferToShader(3, p.vertices_normal_vbo.index);
        gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 4, p.ssbo_distorsion_primitives.index);
        gl.Uniform1i(p.shader.exemplar_texture_uniform, 0);
        defer gl.BindTexture(gl.TEXTURE_2D, 0);
        gl.Uniform4fv(p.shader.ambiant_color_uniform, 1, @ptrCast(&p.ambiant_color));
        gl.Uniform3fv(p.shader.light_position_uniform, 1, @ptrCast(&p.light_position));
        gl.UniformMatrix4fv(p.shader.model_view_matrix_uniform, 1, gl.FALSE, @ptrCast(&p.model_view_matrix));
        gl.UniformMatrix4fv(p.shader.projection_matrix_uniform, 1, gl.FALSE, @ptrCast(&p.projection_matrix));
        gl.Uniform1f(p.shader.scale_tex_coords_uniform, p.scale_tex_coords);
        gl.Uniform1f(p.shader.u_scale_distorsion_uniform, p.scale_distorsion);
        gl.Uniform1i(p.shader.visu_rotate_dist_uniform, @intFromBool(p.visu_rotate_dist));
        gl.Uniform1i(p.shader.visu_stretch_dist_uniform, @intFromBool(p.visu_scale_dist));
        gl.BindVertexArray(p.vao.index);
        defer gl.BindVertexArray(0);
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ibo.index);
        defer gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, 0);
        gl.DrawElements(gl.TRIANGLES, @intCast(ibo.nb_indices), gl.UNSIGNED_INT, 0);
    }
};
