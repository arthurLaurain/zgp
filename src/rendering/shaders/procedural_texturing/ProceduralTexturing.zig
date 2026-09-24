const ProceduralTexturing = @This();

const zstbi = @import("zstbi");
const std = @import("std");
const gl = @import("gl");
const eigen = @import("../../../geometry/eigen.zig");

const Shader = @import("../../Shader.zig");
const VAO = @import("../../VAO.zig");
const VBO = @import("../../VBO.zig");
const IBO = @import("../../IBO.zig");
const TEXTURE2D = @import("../../Texture2D.zig");
const c = @import("c");
const BlendingMode = @import("../../../modules/SurfaceMeshProceduralTexturing.zig").BlendingMode;
const vec = @import("../../../geometry/vec.zig");
const TextureBuffer = @import("../../../rendering/TextureBuffer.zig");
const Vec3f = vec.Vec3f;
const Vec2f = vec.Vec2f;

const mat = @import("../../../geometry/mat.zig");

var global_instance: ?ProceduralTexturing = null;

fn init_global() void {
    if (global_instance) |_| return;

    global_instance = init() catch unreachable;
    Shader.register(&global_instance.?.program);
}
pub fn instance() *ProceduralTexturing {
    init_global();
    return &global_instance.?;
}

pub const TextureData = struct { exemplar_texture: TEXTURE2D, exemplar_texture_priority: ?TEXTURE2D, exemplar_texture_normal: ?TEXTURE2D, exemplar_texture_roughness: ?TEXTURE2D };

program: Shader,

view_matrix_uniform: c_int = undefined,
projection_matrix_uniform: c_int = undefined,
ambiant_color_uniform: c_int = undefined,
light_position_uniform: c_int = undefined,
id_exemplar_texture: c_int = undefined,
exemplar_texture_uniform: c_int = undefined,
exemplar_texture_priority_uniform: c_int = undefined,
exemplar_texture_normal_uniform: c_int = undefined,
exemplar_texture_roughness_uniform: c_int = undefined,
scale_tex_coords_uniform: c_int = undefined,
compense_distorsions_uniform: c_int = undefined,
micro_priority_uniform: c_int = undefined,
blending_mode_uniform: c_int = undefined,
tbo_info_triangles_uniform: c_int = undefined,
tbo_info_vertices_uniform: c_int = undefined,
tbo_vertices_normal_uniform: c_int = undefined,
tbo_uvs_triangles_uniform: c_int = undefined,
tbo_distorsions_uniform: c_int = undefined,
visu_option_uniform: c_int = undefined,
visu_sample_uniform: c_int = undefined,
override_param_uniform: c_int = undefined,

position_attrib: VAO.VertexAttribInfo = undefined,
scaling_field_attrib: VAO.VertexAttribInfo = undefined,
rotation_field_attrib: VAO.VertexAttribInfo = undefined,
edge_ref_attrib: VAO.VertexAttribInfo = undefined,

const VertexAttrib = enum { position, edge_ref, scaling_field, rotation_field };

fn init() !ProceduralTexturing {
    var pt: ProceduralTexturing = .{
        .program = Shader.init(),
    };

    const vertex_shader_source = @embedFile("vs.glsl");
    const fragment_shader_source = @embedFile("fs.glsl");

    try pt.program.setShader(.vertex, vertex_shader_source);
    try pt.program.setShader(.fragment, fragment_shader_source);
    try pt.program.linkProgram();
    try pt.linkAttributes();

    return pt;
}

pub fn reload(pt: *ProceduralTexturing, vertex_shader_source: []u8, fragment_shader_source: []u8) !void {
    pt.program = Shader.init();
    try pt.program.setShader(.vertex, vertex_shader_source);
    try pt.program.setShader(.fragment, fragment_shader_source);
    try pt.program.linkProgram();
}

pub fn linkAttributes(pt: *ProceduralTexturing) !void {
    pt.view_matrix_uniform = gl.GetUniformLocation(pt.program.index, "u_view_matrix");
    pt.projection_matrix_uniform = gl.GetUniformLocation(pt.program.index, "u_projection_matrix");
    pt.ambiant_color_uniform = gl.GetUniformLocation(pt.program.index, "u_ambiant_color");
    pt.light_position_uniform = gl.GetUniformLocation(pt.program.index, "u_light_position");
    pt.exemplar_texture_uniform = gl.GetUniformLocation(pt.program.index, "u_exemplar_texture");
    pt.exemplar_texture_priority_uniform = gl.GetUniformLocation(pt.program.index, "u_exemplar_texture_priority");
    pt.exemplar_texture_normal_uniform = gl.GetUniformLocation(pt.program.index, "u_exemplar_texture_normal");
    pt.exemplar_texture_roughness_uniform = gl.GetUniformLocation(pt.program.index, "u_exemplar_texture_roughness");
    pt.scale_tex_coords_uniform = gl.GetUniformLocation(pt.program.index, "u_scale_tex_coords");
    pt.compense_distorsions_uniform = gl.GetUniformLocation(pt.program.index, "u_compense_distorsions");
    pt.micro_priority_uniform = gl.GetUniformLocation(pt.program.index, "u_micro_priority");
    pt.blending_mode_uniform = gl.GetUniformLocation(pt.program.index, "u_blending_mode");
    pt.tbo_info_triangles_uniform = gl.GetUniformLocation(pt.program.index, "u_info_triangles");
    pt.tbo_info_vertices_uniform = gl.GetUniformLocation(pt.program.index, "u_info_vertices");
    pt.tbo_vertices_normal_uniform = gl.GetUniformLocation(pt.program.index, "u_vertices_normal");
    pt.tbo_uvs_triangles_uniform = gl.GetUniformLocation(pt.program.index, "u_triangle_uvs");
    pt.tbo_distorsions_uniform = gl.GetUniformLocation(pt.program.index, "u_distorsions");
    pt.visu_option_uniform = gl.GetUniformLocation(pt.program.index, "u_visu_option");
    pt.visu_sample_uniform = gl.GetUniformLocation(pt.program.index, "u_visu_sample");
    pt.override_param_uniform = gl.GetUniformLocation(pt.program.index, "u_override_param");

    pt.position_attrib = .{
        .index = @intCast(gl.GetAttribLocation(pt.program.index, "a_position")),
        .size = 3,
        .type = gl.FLOAT,
        .normalized = false,
    };

    pt.scaling_field_attrib = .{
        .index = @intCast(gl.GetAttribLocation(pt.program.index, "a_scaling_field")),
        .size = 1,
        .type = gl.FLOAT,
        .normalized = false,
    };

    pt.rotation_field_attrib = .{
        .index = @intCast(gl.GetAttribLocation(pt.program.index, "a_rotation_field")),
        .size = 3,
        .type = gl.FLOAT,
        .normalized = false,
    };

    pt.edge_ref_attrib = .{
        .index = @intCast(gl.GetAttribLocation(pt.program.index, "a_edge_ref")),
        .size = 3,
        .type = gl.FLOAT,
        .normalized = false,
    };
}

pub fn deinit(tf: *ProceduralTexturing) void {
    tf.program.deinit();
}

pub const Parameters = struct {
    shader: *ProceduralTexturing,
    vao: VAO,
    textureData: TextureData = undefined,
    view_matrix: [16]f32 = undefined,
    projection_matrix: [16]f32 = undefined,
    ambiant_color: [4]f32 = .{ 0.1, 0.1, 0.1, 1 },
    light_position: [3]f32 = .{ 10, 0, 100 },
    tbo_info_triangles: TextureBuffer,
    tbo_info_vertices: TextureBuffer,
    // tbo_edge_ref: TextureBuffer,
    tbo_normal_vertices: TextureBuffer,
    // tbo_distorsion_primitives: TextureBuffer,
    tbo_neigh_selected_vertices: TextureBuffer,
    tbo_triangle_uvs: TextureBuffer,
    tbo_distorsions: TextureBuffer,
    // tbo_scaling_tile: TextureBuffer,
    // tbo_rotation_tile: TextureBuffer,
    vertices_normal_vbo: ?VBO = undefined,
    vertices_position_vbo: ?VBO = undefined,
    vertices_scaling_vbo: ?VBO = undefined,
    vertices_rotation_vbo: ?VBO = undefined,
    face_triangle_uvs: ?VBO = undefined,
    edge_ref_vbo: VBO = undefined,
    scale_tex_coords: f32 = 1,
    compense_distorsions: bool = false,
    mixmax_micro_priority: f32 = 0.001,
    blending_mode: BlendingMode = BlendingMode.LINEAR,
    visu_option: u32 = 0,
    visu_sample: u32 = 0,
    override_param: bool = true,

    pub fn init() Parameters {
        return .{
            .shader = instance(),
            .vao = VAO.init(),
            .tbo_info_triangles = .init(),
            .tbo_info_vertices = .init(),
            // .tbo_edge_ref = .init(),
            .tbo_normal_vertices = .init(),
            // .tbo_distorsion_primitives = .init(),
            .tbo_neigh_selected_vertices = .init(),
            .tbo_triangle_uvs = .init(),
            .tbo_distorsions = .init(),
        };
    }

    pub fn deinit(p: *Parameters) void {
        p.vao.deinit();
        p.tbo_info_triangles.deinit();
        p.tbo_info_vertices.deinit();
        // p.tbo_edge_ref.deinit();
        p.tbo_normal_vertices.deinit();
        // p.tbo_distorsion_primitives.deinit();
        p.tbo_neigh_selected_vertices.deinit();
        // p.tbo_scaling_tile.deinit();
        // p.tbo_rotation_tile.deinit();
        p.tbo_triangle_uvs.deinit();
        p.textureData.exemplar_texture.deinit();
        p.tbo_distorsions.deinit();
        if (p.textureData.exemplar_texture_normal) |*t| {
            t.deinit();
        }
        if (p.textureData.exemplar_texture_priority) |*t| {
            t.deinit();
        }
        if (p.textureData.exemplar_texture_roughness) |*t| {
            t.deinit();
        }
        p.shader.deinit();
        p.edge_ref_vbo.deinit();
    }

    pub fn setVertexAttribArray(p: *Parameters, attrib: VertexAttrib, vbo: VBO, stride: isize, pointer: usize) void {
        const attrib_info = switch (attrib) {
            .position => p.shader.position_attrib,
            .edge_ref => p.shader.edge_ref_attrib,
            .scaling_field => p.shader.scaling_field_attrib,
            .rotation_field => p.shader.rotation_field_attrib,
        };
        p.vao.enableVertexAttribArray(attrib_info, vbo, stride, pointer);
    }
    pub fn unsetVertexAttribArray(p: *Parameters, attrib: VertexAttrib) void {
        const attrib_info = switch (attrib) {
            .position => p.shader.position_attrib,
            .edge_ref => p.shader.edge_ref_attrib,
            .scaling_field => p.shader.scaling_field_attrib,
            .rotation_field => p.shader.rotation_field_attrib,
        };
        p.vao.disableVertexAttribArray(attrib_info);
    }

    pub fn draw(p: *Parameters, ibo: IBO) void {
        gl.UseProgram(p.shader.program.index);
        defer gl.UseProgram(0);

        gl.ActiveTexture(gl.TEXTURE0);
        gl.BindTexture(gl.TEXTURE_2D, p.textureData.exemplar_texture.index);
        gl.Uniform1i(p.shader.exemplar_texture_uniform, 0);
        defer gl.BindTexture(gl.TEXTURE_BUFFER, 0);

        if (p.textureData.exemplar_texture_normal) |t| {
            gl.ActiveTexture(gl.TEXTURE1);
            gl.BindTexture(gl.TEXTURE_2D, t.index);
            gl.Uniform1i(p.shader.exemplar_texture_normal_uniform, 1);
        }

        if (p.textureData.exemplar_texture_priority) |t| {
            gl.ActiveTexture(gl.TEXTURE2);
            gl.BindTexture(gl.TEXTURE_2D, t.index);
            gl.Uniform1i(p.shader.exemplar_texture_priority_uniform, 2);
        }

        if (p.textureData.exemplar_texture_roughness) |t| {
            gl.ActiveTexture(gl.TEXTURE3);
            gl.BindTexture(gl.TEXTURE_2D, t.index);
            gl.Uniform1i(p.shader.exemplar_texture_roughness_uniform, 3);
        }

        p.tbo_info_vertices.bindBufferToShader(
            4,
            ibo.index,
            gl.R32UI,
        );
        gl.Uniform1i(
            p.shader.tbo_info_triangles_uniform,
            4,
        );

        p.tbo_info_triangles.bindBufferToShader(
            5,
            p.vertices_position_vbo.?.index,
            gl.R32F,
        );
        gl.Uniform1i(
            p.shader.tbo_info_vertices_uniform,
            5,
        );

        p.tbo_normal_vertices.bindBufferToShader(
            6,
            p.vertices_normal_vbo.?.index,
            gl.R32F,
        );
        gl.Uniform1i(
            p.shader.tbo_vertices_normal_uniform,
            6,
        );

        p.tbo_triangle_uvs.bindBufferToShader(7, p.face_triangle_uvs.?.index, gl.R32UI);
        gl.Uniform1i(p.shader.tbo_uvs_triangles_uniform, 7);

        gl.ActiveTexture(gl.TEXTURE0 + 8);
        gl.BindBuffer(gl.TEXTURE_BUFFER, p.tbo_distorsions.index);
        gl.Uniform1i(p.shader.tbo_distorsions_uniform, 8);

        gl.Uniform4fv(p.shader.ambiant_color_uniform, 1, @ptrCast(&p.ambiant_color));
        gl.Uniform3fv(p.shader.light_position_uniform, 1, @ptrCast(&p.light_position));
        gl.UniformMatrix4fv(p.shader.view_matrix_uniform, 1, gl.FALSE, @ptrCast(&p.view_matrix));
        gl.UniformMatrix4fv(p.shader.projection_matrix_uniform, 1, gl.FALSE, @ptrCast(&p.projection_matrix));
        gl.Uniform1f(p.shader.scale_tex_coords_uniform, p.scale_tex_coords);
        gl.Uniform1i(p.shader.compense_distorsions_uniform, @intFromBool(p.compense_distorsions));
        gl.Uniform1f(p.shader.micro_priority_uniform, p.mixmax_micro_priority);
        gl.Uniform1i(p.shader.blending_mode_uniform, @intFromEnum(p.blending_mode));
        gl.Uniform1ui(p.shader.visu_option_uniform, p.visu_option);
        gl.Uniform1ui(p.shader.visu_sample_uniform, p.visu_sample);
        gl.Uniform1i(p.shader.override_param_uniform, @intFromBool(p.override_param));

        gl.BindVertexArray(p.vao.index);
        defer gl.BindVertexArray(0);
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ibo.index);
        defer gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, 0);
        gl.DrawElements(gl.TRIANGLES, @intCast(ibo.nb_indices), gl.UNSIGNED_INT, 0);
    }
};
