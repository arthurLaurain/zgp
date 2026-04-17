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
const Vec2d = vec.Vec2d;
const Vec3d = vec.Vec3d;
const Vec4f = vec.Vec4f;
const Vec4d = vec.Vec4d;

const mat = @import("../../../geometry/mat.zig");
const Mat2d = mat.Mat2d;
const Mat3d = mat.Mat3d;
const Mat3f = mat.Mat3f;
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
compense_distorsions_uniform: c_int = undefined,

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
    pt.compense_distorsions_uniform = gl.GetUniformLocation(pt.program.index, "u_compense_distorsions");
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
    compense_distorsions: bool = false,

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

    pub fn computeAsRigidAsPossibleEnergy(F: Mat2d, R: Mat2d, S: Mat2d) f64 {
        return mat.squaredFroberniusNorm2d(F) + mat.squaredFroberniusNorm2d(R) - 2 * mat.trace2d(S);
    }

    pub fn computeLogSPD(M: Mat3d) Mat2d {
        var out: Mat2d = mat.identity2d;
        const M_2d: Mat2d = .{ .{ M[0][0], M[0][1] }, .{ M[1][0], M[1][1] } };
        eigen.computeLogOnEigenValues2d(&M_2d, &out);
        // mat.printMat2d(M);
        // mat.printMat2d(out);
        return mat.identity2d;
    }

    pub fn computeF(x0: Vec3f, x1: Vec3f, x2: Vec3f, n0: Vec3f) Mat3d {
        const x0d: Vec3d = .{ @floatCast(x0[0]), @floatCast(x0[1]), @floatCast(x0[2]) };
        const x1d: Vec3d = .{ @floatCast(x1[0]), @floatCast(x1[1]), @floatCast(x1[2]) };
        const x2d: Vec3d = .{ @floatCast(x2[0]), @floatCast(x2[1]), @floatCast(x2[2]) };
        const n0d: Vec3d = .{ @floatCast(n0[0]), @floatCast(n0[1]), @floatCast(n0[2]) };

        const uv01: Vec2f = getTexCoordFromVertexPlane(x1, x0, n0);
        const uv02: Vec2f = getTexCoordFromVertexPlane(x2, x0, n0);
        const uv01_extended: Vec3d = .{ uv01[0], uv01[1], 0 };
        const uv02_extended: Vec3d = .{ uv02[0], uv02[1], 0 };
        const x01: Vec3d = vec.sub3d(x1d, x0d);
        const x02: Vec3d = vec.sub3d(x2d, x0d);

        const X: Mat3d = .{ x01, x02, n0d };
        const U: Mat3d = .{ uv01_extended, uv02_extended, Vec3d{ 0, 0, 1 } };
        const U_1 = eigen.computeInverse3d(U).?;
        return mat.mul3d(X, U_1);
    }

    pub fn projectDistorsionOntoTriangle(F: Mat3d, x0: Vec3d, x1: Vec3d, x2: Vec3d) Mat2d {
        const t1 = vec.normalized3d(vec.sub3d(x1, x0));
        const n = vec.normalized3d(vec.cross3d(t1, vec.sub3d(x2, x0)));
        const t2 = vec.cross3d(n, t1);
        const T: Mat3d = .{ t1, t2, n };
        const TT: Mat3d = mat.transpose3d(T);
        const F_local = mat.mul3d(TT, mat.mul3d(F, T));
        return .{ .{ F_local[0][0], F_local[0][1] }, .{ F_local[1][0], F_local[1][1] } };
    }

    pub fn computeDistorsion(_: *Parameters, id_triangle: [3]u32, vbo_position: [*]Vec3f, vbo_normal: [*]Vec3f, eigenvectors: *[3]Mat2d, eigenvalues: *[3]Mat2d) Vec3d {

        // Compute triangle deformation
        const x0: Vec3f = vbo_position[id_triangle[0]];
        const x1: Vec3f = vbo_position[id_triangle[1]];
        const x2: Vec3f = vbo_position[id_triangle[2]];

        const x0d: Vec3d = .{ @floatCast(x0[0]), @floatCast(x0[1]), @floatCast(x0[2]) };
        const x1d: Vec3d = .{ @floatCast(x1[0]), @floatCast(x1[1]), @floatCast(x1[2]) };
        const x2d: Vec3d = .{ @floatCast(x2[0]), @floatCast(x2[1]), @floatCast(x2[2]) };

        const n0: Vec3f = vbo_normal[id_triangle[0]];
        const n1: Vec3f = vbo_normal[id_triangle[1]];
        const n2: Vec3f = vbo_normal[id_triangle[2]];

        const F0 = computeF(x0, x1, x2, n0);
        const F1 = computeF(x1, x2, x0, n1);
        const F2 = computeF(x2, x0, x1, n2);

        // Project each deformation gradient onto triangle basis
        const F0_2D = projectDistorsionOntoTriangle(F0, x0d, x1d, x2d);
        const F1_2D = projectDistorsionOntoTriangle(F1, x1d, x2d, x0d);
        const F2_2D = projectDistorsionOntoTriangle(F2, x2d, x0d, x1d);

        // Compute polar decomposition for each deformation gradient
        var decompo_U: Mat2d = undefined;
        var decompo_S: Mat2d = undefined;
        var decompo_V: Mat2d = undefined;

        // F0
        eigen.computeJacobiSVD2D(&F0_2D, &decompo_U, &decompo_S, &decompo_V);
        var V_transpose: Mat2d = mat.transpose2d(decompo_V);
        const R0 = mat.mul2d(decompo_U, V_transpose);
        const S0 = mat.mul2d(decompo_V, mat.mul2d(decompo_S, V_transpose));

        // F1
        eigen.computeJacobiSVD2D(&F1_2D, &decompo_U, &decompo_S, &decompo_V);
        V_transpose = mat.transpose2d(decompo_V);
        const R1 = mat.mul2d(decompo_U, V_transpose);
        const S1 = mat.mul2d(decompo_V, mat.mul2d(decompo_S, V_transpose));

        // F2
        eigen.computeJacobiSVD2D(&F2_2D, &decompo_U, &decompo_S, &decompo_V);
        V_transpose = mat.transpose2d(decompo_V);
        const R2 = mat.mul2d(decompo_U, V_transpose);
        const S2 = mat.mul2d(decompo_V, mat.mul2d(decompo_S, V_transpose));

        // Compute eigenvectors and eigenvalues for each deformation gradient
        eigen.computeEigenValuesAndEigenVectors2d(&S0, &eigenvectors.*[0], &eigenvalues.*[0]);
        eigen.computeEigenValuesAndEigenVectors2d(&S1, &eigenvectors.*[1], &eigenvalues.*[1]);
        eigen.computeEigenValuesAndEigenVectors2d(&S2, &eigenvectors.*[2], &eigenvalues.*[2]);

        return .{ computeAsRigidAsPossibleEnergy(F0_2D, R0, S0), computeAsRigidAsPossibleEnergy(F1_2D, R1, S1), computeAsRigidAsPossibleEnergy(F2_2D, R2, S2) };

        // eigen.computeJacobiSVD3D(&F0, &decompo_U, &decompo_S, &decompo_V);
        // var V_transpose: Mat3d = mat.transpose3d(decompo_V);
        // const S0_3D = mat.mul3d(decompo_V, mat.mul3d(decompo_S, V_transpose));
        // const R0 = mat.mul3d(decompo_U, V_transpose);
        // S0.* = computeLogSPD(S0_3D);

        // eigen.computeJacobiSVD3D(&F1, &decompo_U, &decompo_S, &decompo_V);
        // V_transpose = mat.transpose3d(decompo_V);
        // const S1_3D = mat.mul3d(decompo_V, mat.mul3d(decompo_S, V_transpose));
        // const R1 = mat.mul3d(decompo_U, V_transpose);
        // S1.* = computeLogSPD(S1_3D);

        // eigen.computeJacobiSVD3D(&F2, &decompo_U, &decompo_S, &decompo_V);
        // V_transpose = mat.transpose3d(decompo_V);
        // const S2_3D = mat.mul3d(decompo_V, mat.mul3d(decompo_S, V_transpose));
        // const R2 = mat.mul3d(decompo_U, V_transpose);
        // S2.* = computeLogSPD(S2_3D);

        // var eigenvectors: Mat3d = undefined;
        // var eigenvalues: Mat3d = undefined;
        // eigen.computeEigenValuesAndEigenVectors3d(&S0_3D, &eigenvectors, &eigenvalues);

        // std.log.debug("Oui\n", .{});
        // mat.printMat3d(F0);
        // mat.printMat3d(R0);
        // mat.printMat3d(S0_3D);
        // mat.printMat3d(eigenvectors);
        // mat.printMat3d(eigenvalues);

        // return .{ computeAsRigidAsPossibleEnergy(F0, R0, S0_3D), computeAsRigidAsPossibleEnergy(F1, R1, S1_3D), computeAsRigidAsPossibleEnergy(F2, R2, S2_3D) };

        // std.log.debug("Aire: {d} Angle: {d} Energie {d}", .{ S[0][0] * S[1][1], S[0][0] / S[1][1], energy_arap });

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

        // ssbo.memoryAllocationForMapping(@intCast((@sizeOf(f64) * 12) * nb_triangle));

        const SSBO_structure = struct { eigenvectors: [3]Mat2d, eigenvalues: [3]Vec2d, arap_energy: Vec4d };

        // Memory allocation for 3 eigenvectors matrices + 3 eigenvalues diagonales matrices + ARAP energy
        ssbo.memoryAllocationForMapping(@intCast(nb_triangle * (@sizeOf(SSBO_structure))));

        gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, ssbo.index);
        const ptr_ssbo = gl.MapBuffer(gl.SHADER_STORAGE_BUFFER, gl.READ_WRITE);
        const array_ssbo: [*]SSBO_structure = @ptrCast(@alignCast(ptr_ssbo));

        var i: usize = 0;
        while (i < nb_triangle) : (i += 1) {
            const tri_idx = i;

            const id_triangle: [3]u32 = .{
                array_ibo[tri_idx * 3 + 0],
                array_ibo[tri_idx * 3 + 1],
                array_ibo[tri_idx * 3 + 2],
            };

            var eigenvectors: [3]Mat2d = undefined;
            var eigenvalues_mat: [3]Mat2d = undefined;
            const arap_energy: Vec3d = p.computeDistorsion(id_triangle, array_vbo_position, array_vbo_normal, &eigenvectors, &eigenvalues_mat);

            var eigenvalues: [3]Vec2d = undefined;
            eigenvalues[0] = .{ eigenvalues_mat[0][0][0], eigenvalues_mat[0][1][1] };
            eigenvalues[1] = .{ eigenvalues_mat[1][0][0], eigenvalues_mat[1][1][1] };
            eigenvalues[2] = .{ eigenvalues_mat[2][0][0], eigenvalues_mat[2][1][1] };

            const ssbo_content: SSBO_structure = .{
                .eigenvectors = eigenvectors,
                .eigenvalues = eigenvalues,
                .arap_energy = Vec4d{ arap_energy[0], arap_energy[1], arap_energy[2], 1 },
            };

            array_ssbo[tri_idx] = ssbo_content;
            // // We don't need to send S_i[1][0] to the GPU because S_i is a 2x2 symmetric matrix
            // array_ssbo[i] = S0[0][0];
            // array_ssbo[i + 1] = S0[0][1];
            // array_ssbo[i + 2] = S0[1][1];
            // array_ssbo[i + 3] = arap_energy[0];
            // array_ssbo[i + 4] = S1[0][0];
            // array_ssbo[i + 5] = S1[0][1];
            // array_ssbo[i + 6] = S1[1][1];
            // array_ssbo[i + 7] = arap_energy[1];
            // array_ssbo[i + 8] = S2[0][0];
            // array_ssbo[i + 9] = S2[0][1];
            // array_ssbo[i + 10] = S2[1][1];
            // array_ssbo[i + 11] = arap_energy[2];
        }

        gl.BindBuffer(gl.ARRAY_BUFFER, p.vertices_position_vbo.index);
        _ = gl.UnmapBuffer(gl.ARRAY_BUFFER);

        gl.BindBuffer(gl.ARRAY_BUFFER, p.vertices_normal_vbo.index);
        _ = gl.UnmapBuffer(gl.ARRAY_BUFFER);

        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ibo.index);
        _ = gl.UnmapBuffer(gl.ELEMENT_ARRAY_BUFFER);

        gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, ssbo.index);
        _ = gl.UnmapBuffer(gl.SHADER_STORAGE_BUFFER);
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
        gl.Uniform1i(p.shader.compense_distorsions_uniform, @intFromBool(p.compense_distorsions));
        gl.BindVertexArray(p.vao.index);
        defer gl.BindVertexArray(0);
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ibo.index);
        defer gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, 0);
        gl.DrawElements(gl.TRIANGLES, @intCast(ibo.nb_indices), gl.UNSIGNED_INT, 0);
    }
};
