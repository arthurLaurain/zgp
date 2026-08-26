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
min_max_energy_uniform: c_int = undefined,
light_position_uniform: c_int = undefined,
id_exemplar_texture: c_int = undefined,
exemplar_texture_uniform: c_int = undefined,
exemplar_texture_priority_uniform: c_int = undefined,
exemplar_texture_normal_uniform: c_int = undefined,
exemplar_texture_roughness_uniform: c_int = undefined,
scale_tex_coords_uniform: c_int = undefined,
visu_arap_energy_uniform: c_int = undefined,
compense_distorsions_uniform: c_int = undefined,
distorsions_computed_uniform: c_int = undefined,
tiles_transform_per_vertex_uniform: c_int = undefined,
micro_priority_uniform: c_int = undefined,
blending_mode_uniform: c_int = undefined,
tbo_info_triangles_uniform: c_int = undefined,
tbo_info_vertices_uniform: c_int = undefined,
tbo_vertices_normal: c_int = undefined,

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
    // try pt.linkAttributes();
}

pub fn linkAttributes(pt: *ProceduralTexturing) !void {
    pt.view_matrix_uniform = gl.GetUniformLocation(pt.program.index, "u_view_matrix");
    pt.projection_matrix_uniform = gl.GetUniformLocation(pt.program.index, "u_projection_matrix");
    pt.ambiant_color_uniform = gl.GetUniformLocation(pt.program.index, "u_ambiant_color");
    pt.min_max_energy_uniform = gl.GetUniformLocation(pt.program.index, "u_minmax_energy");
    pt.light_position_uniform = gl.GetUniformLocation(pt.program.index, "u_light_position");
    pt.exemplar_texture_uniform = gl.GetUniformLocation(pt.program.index, "u_exemplar_texture");
    pt.exemplar_texture_priority_uniform = gl.GetUniformLocation(pt.program.index, "u_exemplar_texture_priority");
    pt.exemplar_texture_normal_uniform = gl.GetUniformLocation(pt.program.index, "u_exemplar_texture_normal");
    pt.exemplar_texture_roughness_uniform = gl.GetUniformLocation(pt.program.index, "u_exemplar_texture_roughness");
    pt.scale_tex_coords_uniform = gl.GetUniformLocation(pt.program.index, "u_scale_tex_coords");
    pt.visu_arap_energy_uniform = gl.GetUniformLocation(pt.program.index, "u_visu_arap_energy");
    pt.compense_distorsions_uniform = gl.GetUniformLocation(pt.program.index, "u_compense_distorsions");
    pt.distorsions_computed_uniform = gl.GetUniformLocation(pt.program.index, "u_distorsions_computed");
    pt.tiles_transform_per_vertex_uniform = gl.GetUniformLocation(pt.program.index, "u_tiles_transform_per_vertex");
    pt.micro_priority_uniform = gl.GetUniformLocation(pt.program.index, "u_micro_priority");
    pt.blending_mode_uniform = gl.GetUniformLocation(pt.program.index, "u_blending_mode");
    pt.tbo_info_triangles_uniform = gl.GetUniformLocation(pt.program.index, "u_info_triangles");
    pt.tbo_info_vertices_uniform = gl.GetUniformLocation(pt.program.index, "u_info_vertices");
    pt.tbo_vertices_normal = gl.GetUniformLocation(pt.program.index, "u_vertices_normal");
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
    // tbo_scaling_tile: TextureBuffer,
    // tbo_rotation_tile: TextureBuffer,
    vertices_normal_vbo: ?VBO = undefined,
    vertices_position_vbo: ?VBO = undefined,
    vertices_scaling_vbo: ?VBO = undefined,
    vertices_rotation_vbo: ?VBO = undefined,
    edge_ref_vbo: VBO = undefined,
    scale_tex_coords: f32 = 1,
    visu_arap_energy: bool = false,
    compense_distorsions: bool = false,
    minmax_energy: Vec2f = .{ 0, 0 },
    distorsions_computed: bool = false,
    tiles_transform_per_vertex: bool = false,
    mixmax_micro_priority: f32 = 0.001,
    blending_mode: BlendingMode = BlendingMode.LINEAR,

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
            // .tbo_scaling_tile = .init(),
            // .tbo_rotation_tile = .init(),
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
        p.textureData.exemplar_texture.deinit();
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

    pub fn getTexCoordFromVertexPlane(P: Vec3f, A: Vec3f, N: Vec3f) Vec2f {
        const projPoint: Vec3f = vec.sub3f(P, vec.mulScalar3f(N, vec.dot3f(vec.sub3f(P, A), N)));

        var d: Vec3f = .{ 0, 1, 0 };
        if (@abs(N[1]) >= 0.99)
            d = .{ 1, 0, 0 };
        var T: Vec3f = vec.cross3f(N, d);
        T = vec.normalized3f(T);
        const BT: Vec3f = vec.cross3f(N, T);

        const AP: Vec3f = vec.sub3f(projPoint, A);
        const uv: Vec2f = .{ vec.dot3f(AP, T), vec.dot3f(AP, BT) };
        return uv;
    }

    fn computeAsRigidAsPossibleEnergy3D(F: Mat3f, R: Mat3f, S: Mat3f) f32 {
        return mat.squaredFroberniusNorm3d(F) + mat.squaredFroberniusNorm3d(R) - 2 * mat.trace3d(S);
    }

    pub fn computeF(x0: Vec3f, x1: Vec3f, x2: Vec3f, n0: Vec3f) Mat3f {
        const uv01: Vec2f = getTexCoordFromVertexPlane(x1, x0, n0);
        const uv02: Vec2f = getTexCoordFromVertexPlane(x2, x0, n0);

        const uv01_extended: Vec3f = .{ uv01[0], uv01[1], 0 };
        const uv02_extended: Vec3f = .{ uv02[0], uv02[1], 0 };

        const x01: Vec3f = vec.sub3f(x1, x0);
        const x02: Vec3f = vec.sub3f(x2, x0);

        const n: Vec3f = vec.normalized3f(vec.cross3f(x01, x02));
        const X: Mat3d = .{ vec.vec3fToVec3d(x01), vec.vec3fToVec3d(x02), vec.vec3fToVec3d(n) };
        const U: Mat3d = .{ vec.vec3fToVec3d(uv01_extended), vec.vec3fToVec3d(uv02_extended), .{ 0.0, 0.0, 1.0 } };
        const U_1: Mat3d = eigen.computeInverse3d(U).?;

        const XUU_1: Mat3d = mat.mul3d(X, U_1);

        return mat.mat3fFromMat3d(XUU_1);
    }

    pub fn computeDistorsion(_: *Parameters, id_triangle: [3]u32, vbo_position: [*]Vec3f, vbo_normal: [*]Vec3f, scaleMatrix: *[3]Mat3d) Vec3f {
        const x0: Vec3f = vbo_position[id_triangle[0]];
        const x1: Vec3f = vbo_position[id_triangle[1]];
        const x2: Vec3f = vbo_position[id_triangle[2]];

        const n0: Vec3f = vbo_normal[id_triangle[0]];
        const n1: Vec3f = vbo_normal[id_triangle[1]];
        const n2: Vec3f = vbo_normal[id_triangle[2]];

        const F0 = computeF(x0, x1, x2, n0);
        const F1 = computeF(x1, x2, x0, n1);
        const F2 = computeF(x2, x0, x1, n2);

        const F0d = mat.mat3dFromMat3f(F0);
        var res = eigen.computeJacobiSVD3D(F0d);
        var U: Mat3d = res[0];
        var S: Mat3d = res[1];
        var V: Mat3d = res[2];
        const Vt0 = mat.transpose3d(V);
        const R0 = mat.mul3d(U, Vt0);
        const S0 = mat.mul3d(V, mat.mul3d(S, Vt0));

        // F1
        const F1d = mat.mat3dFromMat3f(F1);
        res = eigen.computeJacobiSVD3D(F1d);
        U = res[0];
        S = res[1];
        V = res[2];
        const Vt1 = mat.transpose3d(V);
        const R1 = mat.mul3d(U, Vt1);
        const S1 = mat.mul3d(V, mat.mul3d(S, Vt1));

        // F2
        const F2d = mat.mat3dFromMat3f(F2);
        res = eigen.computeJacobiSVD3D(F2d);
        U = res[0];
        S = res[1];
        V = res[2];
        const Vt2 = mat.transpose3d(V);
        const R2 = mat.mul3d(U, Vt2);
        const S2 = mat.mul3d(V, mat.mul3d(S, Vt2));

        scaleMatrix[0] = S0;
        scaleMatrix[1] = S1;
        scaleMatrix[2] = S2;

        return .{ computeAsRigidAsPossibleEnergy3D(F0, mat.mat3fFromMat3d(R0), mat.mat3fFromMat3d(S0)), computeAsRigidAsPossibleEnergy3D(F1, mat.mat3fFromMat3d(R1), mat.mat3fFromMat3d(S1)), computeAsRigidAsPossibleEnergy3D(F2, mat.mat3fFromMat3d(R2), mat.mat3fFromMat3d(S2)) };
    }

    pub fn fillDistorsionTBO(p: *Parameters, tbo: *TextureBuffer, ibo: *const IBO) bool {
        gl.BindBuffer(gl.ARRAY_BUFFER, p.vertices_position_vbo.?.index);
        const ptr_vbo_position = gl.MapBuffer(gl.ARRAY_BUFFER, gl.READ_ONLY);
        if (ptr_vbo_position) |_| {} else {
            return false;
        }
        const array_vbo_position: [*]Vec3f = @ptrCast(@alignCast(ptr_vbo_position.?));

        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ibo.index);
        const ptr_ibo = gl.MapBuffer(gl.ELEMENT_ARRAY_BUFFER, gl.READ_ONLY);
        const array_ibo: [*]u32 = @ptrCast(@alignCast(ptr_ibo));

        gl.BindBuffer(gl.ARRAY_BUFFER, p.vertices_normal_vbo.?.index);
        const ptr_vbo_normal = gl.MapBuffer(gl.ARRAY_BUFFER, gl.READ_ONLY);
        if (ptr_vbo_normal) |_| {} else {
            std.log.debug("You should first compute normals", .{});
            return false;
        }
        const array_vbo_normal: [*]Vec3f = @ptrCast(@alignCast(ptr_vbo_normal.?));

        const nb_triangle: usize = ibo.nb_indices / 3;

        const TBO_structure = struct { S: [3]Mat2f, arap_energy: Vec4f };

        tbo.memoryAllocationForMapping(@intCast(nb_triangle * (@sizeOf(TBO_structure))));

        gl.BindBuffer(gl.TEXTURE_BUFFER, tbo.index);
        const ptr_tbo = gl.MapBuffer(gl.TEXTURE_BUFFER, gl.READ_WRITE);
        const array_tbo: [*]TBO_structure = @ptrCast(@alignCast(ptr_tbo));

        var i: usize = 0;
        var min_energy = std.math.floatMax(f32);
        var max_energy = std.math.floatMin(f32);

        while (i < nb_triangle) : (i += 1) {
            const tri_idx = i;

            const id_triangle: [3]u32 = .{
                array_ibo[tri_idx * 3 + 0],
                array_ibo[tri_idx * 3 + 1],
                array_ibo[tri_idx * 3 + 2],
            };

            var S_d: [3]Mat3d = undefined;
            const arap_energy: Vec3f = p.computeDistorsion(id_triangle, array_vbo_position, array_vbo_normal, &S_d);

            for (0..3) |value| {
                if (arap_energy[value] > max_energy) max_energy = arap_energy[value] else if (arap_energy[value] < min_energy) min_energy = arap_energy[value];
            }

            var S: [3]Mat2f = undefined;

            for (0..3) |u| {
                S[u][0][0] = @floatCast(S_d[u][0][0]);
                S[u][0][1] = @floatCast(S_d[u][0][1]);
                S[u][1][0] = @floatCast(S_d[u][1][0]);
                S[u][1][1] = @floatCast(S_d[u][1][1]);
            }

            const tbo_content: TBO_structure = .{
                .S = S,
                .arap_energy = Vec4f{ arap_energy[0], arap_energy[1], arap_energy[2], 1 },
            };

            array_tbo[tri_idx] = tbo_content;
        }

        p.minmax_energy = .{ min_energy, max_energy };

        gl.BindBuffer(gl.ARRAY_BUFFER, p.vertices_position_vbo.?.index);
        _ = gl.UnmapBuffer(gl.ARRAY_BUFFER);

        gl.BindBuffer(gl.ARRAY_BUFFER, p.vertices_normal_vbo.?.index);
        _ = gl.UnmapBuffer(gl.ARRAY_BUFFER);

        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ibo.index);
        _ = gl.UnmapBuffer(gl.ELEMENT_ARRAY_BUFFER);

        gl.BindBuffer(gl.TEXTURE_BUFFER, tbo.index);
        _ = gl.UnmapBuffer(gl.TEXTURE_BUFFER);
        return true;
    }

    pub fn draw(p: *Parameters, ibo: IBO) void {
        // if (!p.distorsions_computed and p.compense_distorsions) {
        //     p.distorsions_computed = p.fillDistorsionTBO(&p.tbo_distorsion_primitives, &ibo);
        // }

        gl.UseProgram(p.shader.program.index);
        defer gl.UseProgram(0);

        gl.ActiveTexture(gl.TEXTURE0);
        gl.BindTexture(gl.TEXTURE_2D, p.textureData.exemplar_texture.index);
        gl.Uniform1i(p.shader.exemplar_texture_uniform, 0);

        if (p.textureData.exemplar_texture_normal) |t| {
            gl.ActiveTexture(gl.TEXTURE1);
            gl.BindTexture(gl.TEXTURE_2D, t.index);
            gl.Uniform1i(p.shader.exemplar_texture_normal_uniform, 1);
        }

        if (p.textureData.exemplar_texture_priority) |t| {
            gl.ActiveTexture(gl.TEXTURE2);
            gl.BindTexture(gl.TEXTURE_2D, t.index);
            gl.Uniform1i(p.shader.exemplar_texture_priority_uniform, 1);
        }

        if (p.textureData.exemplar_texture_roughness) |t| {
            gl.ActiveTexture(gl.TEXTURE3);
            gl.BindTexture(gl.TEXTURE_2D, t.index);
            gl.Uniform1i(p.shader.exemplar_texture_roughness_uniform, 1);
        }

        defer gl.BindTexture(gl.TEXTURE_2D, 0);
        p.tbo_info_vertices.bindBufferToShader(0, ibo.index, gl.R32UI);
        gl.Uniform1i(p.shader.tbo_info_triangles_uniform, 0);
        p.tbo_info_triangles.bindBufferToShader(1, p.vertices_position_vbo.?.index, gl.RGBA32F);
        gl.Uniform1i(p.shader.tbo_info_vertices_uniform, 1);
        // p.tbo_edge_ref.bindBufferToShader(2, p.edge_ref_vbo.index, gl.RGBA32F);
        p.tbo_normal_vertices.bindBufferToShader(3, p.vertices_normal_vbo.?.index, gl.RGBA32F);
        gl.Uniform1i(p.shader.tbo_vertices_normal, 1);
        // gl.BindBufferBase(gl.TEXTURE_BUFFER, 4, p.tbo_distorsion_primitives.index);
        // gl.BindBufferBase(gl.TEXTURE_BUFFER, 5, p.tbo_neigh_selected_vertices.index);
        // if (p.vertices_scaling_vbo) |vbo| {
        //     p.tbo_scaling_tile.bindBufferToShader(6, vbo.index, gl.RGBA32F);
        // } else {
        //     p.tbo_scaling_tile.bindBufferToShader(6, 0, gl.RGBA32F);
        // }

        // if (p.vertices_rotation_vbo) |vbo| {
        //     p.tbo_rotation_tile.bindBufferToShader(7, vbo.index, gl.RGBA32F);
        // } else {
        //     p.tbo_rotation_tile.bindBufferToShader(7, 0, gl.RGBA32F);
        // }

        gl.Uniform4fv(p.shader.ambiant_color_uniform, 1, @ptrCast(&p.ambiant_color));
        gl.Uniform2fv(p.shader.min_max_energy_uniform, 1, @ptrCast(&p.minmax_energy));
        gl.Uniform3fv(p.shader.light_position_uniform, 1, @ptrCast(&p.light_position));
        gl.UniformMatrix4fv(p.shader.view_matrix_uniform, 1, gl.FALSE, @ptrCast(&p.view_matrix));
        gl.UniformMatrix4fv(p.shader.projection_matrix_uniform, 1, gl.FALSE, @ptrCast(&p.projection_matrix));
        gl.Uniform1f(p.shader.scale_tex_coords_uniform, p.scale_tex_coords);
        gl.Uniform1i(p.shader.visu_arap_energy_uniform, @intFromBool(p.visu_arap_energy));
        gl.Uniform1i(p.shader.compense_distorsions_uniform, @intFromBool(p.compense_distorsions));
        gl.Uniform1i(p.shader.distorsions_computed_uniform, @intFromBool(p.distorsions_computed));
        gl.Uniform1i(p.shader.tiles_transform_per_vertex_uniform, @intFromBool(p.tiles_transform_per_vertex));
        gl.Uniform1f(p.shader.micro_priority_uniform, p.mixmax_micro_priority);
        gl.Uniform1i(p.shader.blending_mode_uniform, @intFromEnum(p.blending_mode));

        gl.BindVertexArray(p.vao.index);
        defer gl.BindVertexArray(0);
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ibo.index);
        defer gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, 0);
        gl.DrawElements(gl.TRIANGLES, @intCast(ibo.nb_indices), gl.UNSIGNED_INT, 0);
    }
};
