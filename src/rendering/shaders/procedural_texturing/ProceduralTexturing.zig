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
const Mat2f = mat.Mat2f;
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

    fn computeAsRigidAsPossibleEnergy3D(F: Mat3f, R: Mat3f, S: Mat3f) f32 {
        return mat.squaredFroberniusNorm3d(F) + mat.squaredFroberniusNorm3d(R) - 2 * mat.trace3d(S);
    }

    fn computeAsRigidAsPossibleEnergy(F: Mat2f, R: Mat2f, S: Mat2f) f32 {
        return mat.squaredFroberniusNorm2d(F) + mat.squaredFroberniusNorm2d(R) - 2 * mat.trace2d(S);
    }

    pub fn computeF(x0: Vec3f, x1: Vec3f, x2: Vec3f, n0: Vec3f) Mat3f {
        const uv01: Vec2f = getTexCoordFromVertexPlane(x1, x0, n0);
        const uv02: Vec2f = getTexCoordFromVertexPlane(x2, x0, n0);

        const uv01_extended: Vec3f = .{ uv01[0], uv01[1], 0 };
        const uv02_extended: Vec3f = .{ uv02[0], uv02[1], 0 };

        const x01: Vec3f = vec.sub3f(x1, x0);
        const x02: Vec3f = vec.sub3f(x2, x0);

        const X: Mat3d = .{ vec.vec3fToVec3d(x01), vec.vec3fToVec3d(x02), vec.vec3fToVec3d(n0) };
        const U: Mat3d = .{ vec.vec3fToVec3d(uv01_extended), vec.vec3fToVec3d(uv02_extended), .{ 0.0, 0.0, 1.0 } };
        const U_1: Mat3d = eigen.computeInverse3d(U).?;

        const XUU_1: Mat3d = mat.mul3d(X, .{
            U_1[0],
            U_1[1],
            U_1[2],
        });

        return mat.mat3fFromMat3d(XUU_1);
    }

    pub fn distorsionsFromTriangleBasis(F: Mat3f, x0: Vec3f, x1: Vec3f, x2: Vec3f) Mat2f {
        const t1 = vec.normalized3f(vec.sub3f(x1, x0));
        const n = vec.normalized3f(vec.cross3f(t1, vec.sub3f(x2, x0)));
        const t2 = vec.cross3f(n, t1);
        const T: Mat3f = .{ t1, t2, n };
        const TT: Mat3f = mat.transpose3f(T);
        const F_local = mat.mul3f(TT, mat.mul3f(F, T));
        return .{ .{ F_local[0][0], F_local[0][1] }, .{ F_local[1][0], F_local[1][1] } };
    }

    pub fn computeDistorsion(_: *Parameters, id_triangle: [3]u32, vbo_position: [*]Vec3f, vbo_normal: [*]Vec3f, eigenvectors: *[3]Mat2d, eigenvalues: *[3]Mat2d) Vec3f {
        const x0: Vec3f = vbo_position[id_triangle[0]];
        const x1: Vec3f = vbo_position[id_triangle[1]];
        const x2: Vec3f = vbo_position[id_triangle[2]];

        const n0: Vec3f = vbo_normal[id_triangle[0]];
        const n1: Vec3f = vbo_normal[id_triangle[1]];
        const n2: Vec3f = vbo_normal[id_triangle[2]];

        const F0 = computeF(x0, x1, x2, n0);
        const F1 = computeF(x1, x2, x0, n1);
        const F2 = computeF(x2, x0, x1, n2);

        const F0_2D = distorsionsFromTriangleBasis(F0, x0, x1, x2);
        const F1_2D = distorsionsFromTriangleBasis(F1, x0, x1, x2);
        const F2_2D = distorsionsFromTriangleBasis(F2, x0, x1, x2);

        var F0_d: Mat3d = mat.mat3dFromMat3f(F0);

        var U3d: Mat3d = undefined;
        var S3d: Mat3d = undefined;
        var V3d: Mat3d = undefined;

        eigen.computeJacobiSVD3D(&F0_d, &U3d, &S3d, &V3d);

        const Vt3d = mat.transpose3d(V3d);
        const R0_3D_d = mat.mul3d(U3d, Vt3d);
        const S0_3D_d = mat.mul3d(V3d, mat.mul3d(S3d, Vt3d));

        const R0_3D = mat.mat3dToMat3f(R0_3D_d);
        const S0_3D = mat.mat3dToMat3f(S0_3D_d);

        var U2: Mat2d = undefined;
        var S2: Mat2d = undefined;
        var V2: Mat2d = undefined;

        const F0d_2D = mat.mat2dFromMat2f(F0_2D);
        eigen.computeJacobiSVD2D(&F0d_2D, &U2, &S2, &V2);
        _ = mat.mul2d(U2, mat.transpose2d(V2));

        // F1
        const F1d_2D = mat.mat2dFromMat2f(F1_2D);
        eigen.computeJacobiSVD2D(&F1d_2D, &U2, &S2, &V2);
        const Vt = mat.transpose2d(V2);
        const R1 = mat.mul2d(U2, Vt);
        const S1 = mat.mul2d(V2, mat.mul2d(S2, Vt));

        // F2
        const F2d_2D = mat.mat2dFromMat2f(F2_2D);
        eigen.computeJacobiSVD2D(&F2d_2D, &U2, &S2, &V2);
        const Vt2 = mat.transpose2d(V2);
        const R2 = mat.mul2d(U2, Vt2);
        const S2m = mat.mul2d(V2, mat.mul2d(S2, Vt2));

        //Temporary to debug 2D arap computation
        eigenvalues.*[0] = mat.identity2d;
        eigenvectors.*[0] = mat.identity2d;
        eigen.computeEigenValuesAndEigenVectors2d(&S1, &eigenvectors.*[1], &eigenvalues.*[1]);
        eigen.computeEigenValuesAndEigenVectors2d(&S2m, &eigenvectors.*[2], &eigenvalues.*[2]);

        return .{ computeAsRigidAsPossibleEnergy3D(F0, R0_3D, S0_3D), computeAsRigidAsPossibleEnergy(F1_2D, mat.mat2fFromMat2d(R1), mat.mat2fFromMat2d(S1)), computeAsRigidAsPossibleEnergy(F2_2D, mat.mat2fFromMat2d(R2), mat.mat2fFromMat2d(S2m)) };
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

        const SSBO_structure = struct { eigenvectors: [3]Mat2f, eigenvalues: [3]Vec2f, padding: [2]f32, arap_energy: Vec4f };

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

            var eigenvectorsd: [3]Mat2d = undefined;
            var eigenvalues_mat: [3]Mat2d = undefined;
            const arap_energy: Vec3f = p.computeDistorsion(id_triangle, array_vbo_position, array_vbo_normal, &eigenvectorsd, &eigenvalues_mat);

            var eigenvectors: [3]Mat2f = undefined;
            eigenvectors[0] = mat.mat2fFromMat2d(eigenvectorsd[0]);
            eigenvectors[1] = mat.mat2fFromMat2d(eigenvectorsd[1]);
            eigenvectors[2] = mat.mat2fFromMat2d(eigenvectorsd[2]);

            var eigenvalues: [3]Vec2f = undefined;
            eigenvalues[0] = .{ @floatCast(eigenvalues_mat[0][0][0]), @floatCast(eigenvalues_mat[0][1][1]) };
            eigenvalues[1] = .{ @floatCast(eigenvalues_mat[1][0][0]), @floatCast(eigenvalues_mat[1][1][1]) };
            eigenvalues[2] = .{ @floatCast(eigenvalues_mat[2][0][0]), @floatCast(eigenvalues_mat[2][1][1]) };

            const ssbo_content: SSBO_structure = .{
                .eigenvectors = eigenvectors,
                .eigenvalues = eigenvalues,
                .padding = .{ 0, 0 },
                .arap_energy = Vec4f{ arap_energy[0], arap_energy[1], arap_energy[2], 1 },
            };

            array_ssbo[tri_idx] = ssbo_content;
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
