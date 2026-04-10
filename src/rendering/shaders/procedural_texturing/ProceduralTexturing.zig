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
const SSBO = @import("../../SSBO.zig");

const vec = @import("../../../geometry/vec.zig");
const Vec3f = vec.Vec3f;
const Vec2f = vec.Vec2f;
const Vec3d = vec.Vec3d;
const Vec4f = vec.Vec4f;

const mat = @import("../../../geometry/mat.zig");
const Mat3d = mat.Mat3d;
const Mat4d = mat.Mat4d;

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
visu_area_distorsion_uniform: c_int = undefined,
visu_angle_distorsion_uniform: c_int = undefined,
visu_arap_energy_uniform: c_int = undefined,

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
    pt.visu_area_distorsion_uniform = gl.GetUniformLocation(pt.program.index, "u_visu_area_distorsion");
    pt.visu_angle_distorsion_uniform = gl.GetUniformLocation(pt.program.index, "u_visu_angle_distorsion");
    pt.visu_arap_energy_uniform = gl.GetUniformLocation(pt.program.index, "u_visu_arap_energy");
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
    first: bool = true,
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
    ssbo_neigh_selected_vertices: SSBO = undefined,
    vertices_normal_vbo: VBO = undefined,
    vertices_position_vbo: VBO = undefined,
    edge_ref_vbo: VBO = undefined,
    scale_tex_coords: f32 = 1,
    scale_distorsion: f32 = 1,
    visu_area_distorsion: bool = false,
    visu_angle_distorsion: bool = false,
    visu_arap_energy: bool = false,

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
        p.ssbo_neigh_selected_vertices.deinit();
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

    pub fn getTexCoordFromVertexPlane(P: Vec3f, A: Vec3f, N: Vec3f) Vec2f {
        const projPoint: Vec3f = vec.sub3f(P, vec.mulScalar3f(N, vec.dot3f(vec.sub3f(P, A), N)));

        const up: Vec3f = .{ 0, 1, 0 };
        var T: Vec3f = vec.cross3f(N, up);
        if (vec.norm3f(T) < 1e-6) {
            const altUp: Vec3f = .{ 1, 0, 0 };
            T = vec.cross3f(N, altUp);
        }
        T = vec.normalized3f(T);
        const BT: Vec3f = vec.cross3f(N, T);

        const AP: Vec3f = vec.sub3f(projPoint, A);
        const uv: Vec2f = .{ vec.dot3f(AP, T), vec.dot3f(AP, BT) };
        return uv;
    }

    pub fn computeAsRigidAsPossibleEnergy(F: Mat3d, R: Mat3d, S: Mat3d) f64 {
        return mat.squaredFroberniusNorm3d(F) + mat.squaredFroberniusNorm3d(R) - 2 * mat.trace3d(S);
    }

    // return (σ_1, σ_2, ψ_as-rigid-as-possible)
    pub fn computeDistorsion(_: *Parameters, id_triangle: [3]u32, vbo_position: [*]Vec3f, vbo_normal: [*]Vec3f) Vec3d {
        const x0: Vec3f = vbo_position[id_triangle[0]];
        const x1: Vec3f = vbo_position[id_triangle[1]];
        const x2: Vec3f = vbo_position[id_triangle[2]];

        const x0d: Vec3d = .{ @floatCast(x0[0]), @floatCast(x0[1]), @floatCast(x0[2]) };
        const x1d: Vec3d = .{ @floatCast(x1[0]), @floatCast(x1[1]), @floatCast(x1[2]) };
        const x2d: Vec3d = .{ @floatCast(x2[0]), @floatCast(x2[1]), @floatCast(x2[2]) };

        const x01: Vec3d = vec.sub3d(x1d, x0d);
        const x02: Vec3d = vec.sub3d(x2d, x0d);

        const n0: Vec3f = vbo_normal[id_triangle[0]];
        // const n1: Vec3f = vbo_normal[id_triangle[1] * 3];
        // const n2: Vec3f = vbo_normal[id_triangle[2] * 3];

        const n0d: Vec3d = .{ @floatCast(n0[0]), @floatCast(n0[1]), @floatCast(n0[2]) };

        // computing distorsion for tiling based on p0
        const uv01: Vec2f = getTexCoordFromVertexPlane(x1, x0, n0);
        const uv02: Vec2f = getTexCoordFromVertexPlane(x2, x0, n0);

        const uv01_extended: Vec3d = .{ uv01[0], uv01[1], 0 };
        const uv02_extended: Vec3d = .{ uv02[0], uv02[1], 0 };

        const X: Mat3d = .{ x01, x02, n0d };
        const U: Mat3d = .{ uv01_extended, uv02_extended, Vec3d{ 0, 0, 1 } };
        const U_1 = eigen.computeInverse3d(U).?;
        const F: Mat3d = mat.mul3d(X, U_1);

        var decompo_U: Mat3d = undefined;
        var decompo_S: Mat3d = undefined;
        var decompo_V: Mat3d = undefined;

        eigen.computeJacobiSVD(&F, &decompo_U, &decompo_S, &decompo_V);

        const V_transpose: Mat3d = mat.transpose3d(decompo_V);
        const S: Mat3d = mat.mul3d(decompo_V, mat.mul3d(decompo_S, V_transpose));
        const R: Mat3d = mat.mul3d(decompo_U, V_transpose);
        const energy_arap: f64 = computeAsRigidAsPossibleEnergy(F, R, S);

        // std.log.debug("Aire: {d} Angle: {d} Energie {d}", .{ S[0][0] * S[1][1], S[0][0] / S[1][1], energy_arap });

        return .{ S[0][0], S[1][1], energy_arap };
    }

    pub fn fillDistorsionSSBO(p: *Parameters, ssbo: *SSBO, ibo: *const IBO) void {
        gl.BindBuffer(gl.ARRAY_BUFFER, p.vertices_position_vbo.index);
        const ptr_vbo_position = gl.MapBuffer(gl.ARRAY_BUFFER, gl.READ_ONLY);
        const array_vbo_position: [*]Vec3f = @ptrCast(@alignCast(ptr_vbo_position));

        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ibo.index);
        const ptr_ibo = gl.MapBuffer(gl.ELEMENT_ARRAY_BUFFER, gl.READ_ONLY);
        const array_ibo: [*]u32 = @ptrCast(@alignCast(ptr_ibo));

        gl.BindBuffer(gl.ARRAY_BUFFER, p.vertices_normal_vbo.index);
        const ptr_vbo_normal = gl.MapBuffer(gl.ARRAY_BUFFER, gl.READ_ONLY);
        const array_vbo_normal: [*]Vec3f = @ptrCast(@alignCast(ptr_vbo_normal));

        const nb_triangle: usize = ibo.nb_indices / 3;

        ssbo.memoryAllocationForMapping(@intCast(@sizeOf(f64) * 4 * nb_triangle));

        gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, ssbo.index);
        const ptr_ssbo = gl.MapBuffer(gl.SHADER_STORAGE_BUFFER, gl.READ_WRITE);
        const array_ssbo: [*]f64 = @ptrCast(@alignCast(ptr_ssbo));

        var i: usize = 0;
        while (i < nb_triangle * 4) : (i += 4) {
            const tri_idx = i / 4;

            const id_triangle: [3]u32 = .{
                array_ibo[tri_idx * 3 + 0],
                array_ibo[tri_idx * 3 + 1],
                array_ibo[tri_idx * 3 + 2],
            };

            const r: Vec3d = p.computeDistorsion(id_triangle, array_vbo_position, array_vbo_normal);

            array_ssbo[i] = r[0];
            array_ssbo[i + 1] = r[1];
            array_ssbo[i + 2] = r[2];
            array_ssbo[i + 3] = 1;
        }

        _ = gl.UnmapBuffer(gl.ARRAY_BUFFER);
        gl.BindBuffer(gl.ARRAY_BUFFER, p.vertices_position_vbo.index);
        _ = gl.UnmapBuffer(gl.ARRAY_BUFFER);
        gl.BindBuffer(gl.ARRAY_BUFFER, 0);
        _ = gl.UnmapBuffer(gl.ELEMENT_ARRAY_BUFFER);
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, 0);
        _ = gl.UnmapBuffer(gl.SHADER_STORAGE_BUFFER);
        gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0);
    }

    pub fn draw(p: *Parameters, ibo: IBO) void {
        if (p.first) {
            p.fillDistorsionSSBO(&p.ssbo_distorsion_primitives, &ibo);
            p.first = false;
        }

        gl.UseProgram(p.shader.program.index);
        defer gl.UseProgram(0);
        gl.ActiveTexture(gl.TEXTURE0);
        gl.BindTexture(gl.TEXTURE_2D, p.exemplar_texture.index);
        p.ssbo_info_vertices.bindBufferToShader(0, ibo.index);
        p.ssbo_info_triangles.bindBufferToShader(1, p.vertices_position_vbo.index);
        p.ssbo_edge_ref.bindBufferToShader(2, p.edge_ref_vbo.index);
        p.ssbo_normal_vertices.bindBufferToShader(3, p.vertices_normal_vbo.index);
        gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 4, p.ssbo_distorsion_primitives.index);
        gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 5, p.ssbo_neigh_selected_vertices.index);
        gl.Uniform1i(p.shader.exemplar_texture_uniform, 0);
        defer gl.BindTexture(gl.TEXTURE_2D, 0);
        gl.Uniform4fv(p.shader.ambiant_color_uniform, 1, @ptrCast(&p.ambiant_color));
        gl.Uniform3fv(p.shader.light_position_uniform, 1, @ptrCast(&p.light_position));
        gl.UniformMatrix4fv(p.shader.model_view_matrix_uniform, 1, gl.FALSE, @ptrCast(&p.model_view_matrix));
        gl.UniformMatrix4fv(p.shader.projection_matrix_uniform, 1, gl.FALSE, @ptrCast(&p.projection_matrix));
        gl.Uniform1f(p.shader.scale_tex_coords_uniform, p.scale_tex_coords);
        gl.Uniform1f(p.shader.u_scale_distorsion_uniform, p.scale_distorsion);
        gl.Uniform1i(p.shader.visu_angle_distorsion_uniform, @intFromBool(p.visu_angle_distorsion));
        gl.Uniform1i(p.shader.visu_area_distorsion_uniform, @intFromBool(p.visu_area_distorsion));
        gl.Uniform1i(p.shader.visu_arap_energy_uniform, @intFromBool(p.visu_arap_energy));
        gl.BindVertexArray(p.vao.index);
        defer gl.BindVertexArray(0);
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ibo.index);
        defer gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, 0);
        gl.DrawElements(gl.TRIANGLES, @intCast(ibo.nb_indices), gl.UNSIGNED_INT, 0);
    }
};
