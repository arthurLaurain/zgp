const std = @import("std");
const gl = @import("gl");
const assert = std.debug.assert;

const SurfaceMesh = @import("SurfaceMesh.zig");
const TriangleUVs = @import("../../modules/SurfaceMeshParameterization.zig").ParameterizationData.TriangleUVs;
const vec = @import("../../geometry/vec.zig");
const Vec2f = vec.Vec2f;
const Vec3f = vec.Vec3f;
const Vec4f = vec.Vec4f;
const mat = @import("../../geometry/mat.zig");
const Mat2f = mat.Mat2f;
const Mat3f = mat.Mat3f;
const Mat3d = mat.Mat3d;
const eigen = @import("../../geometry/eigen.zig");
const VBO = @import("../../rendering/VBO.zig");
const TextureBuffer = @import("../../rendering/TextureBuffer.zig");
const IBO = @import("../../rendering/IBO.zig");

fn computeF(uv01: Vec2f, uv02: Vec2f, x0: Vec3f, x1: Vec3f, x2: Vec3f) Mat3f {
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

fn computeDistorsion(id_triangle: u32, id_vertices_triangle: [3]u32, vbo_position: [*]Vec3f, celldata_triangleuvs: SurfaceMesh.CellData(.face, TriangleUVs)) [3]Mat3d {
    const x0: Vec3f = vbo_position[id_vertices_triangle[0]];
    const x1: Vec3f = vbo_position[id_vertices_triangle[1]];
    const x2: Vec3f = vbo_position[id_vertices_triangle[2]];

    const uv = celldata_triangleuvs.valueByIndex(id_triangle).uvs;
    const F0 = computeF(vec.sub2f(uv[0][1], uv[0][0]), vec.sub2f(uv[0][2], uv[0][0]), x0, x1, x2);
    const F1 = computeF(vec.sub2f(uv[1][1], uv[1][0]), vec.sub2f(uv[1][2], uv[1][0]), x1, x2, x0);
    const F2 = computeF(vec.sub2f(uv[2][1], uv[2][0]), vec.sub2f(uv[2][2], uv[2][0]), x2, x0, x1);

    // F0
    const F0d = mat.mat3dFromMat3f(F0);
    var res = eigen.computeJacobiSVD3D(F0d);
    var U: Mat3d = res[0];
    var S: Mat3d = res[1];
    var V: Mat3d = res[2];
    const Vt0 = mat.transpose3d(V);
    const S0 = mat.mul3d(V, mat.mul3d(S, Vt0));

    // F1
    const F1d = mat.mat3dFromMat3f(F1);
    res = eigen.computeJacobiSVD3D(F1d);
    U = res[0];
    S = res[1];
    V = res[2];
    const Vt1 = mat.transpose3d(V);
    const S1 = mat.mul3d(V, mat.mul3d(S, Vt1));

    // F2
    const F2d = mat.mat3dFromMat3f(F2);
    res = eigen.computeJacobiSVD3D(F2d);
    U = res[0];
    S = res[1];
    V = res[2];
    const Vt2 = mat.transpose3d(V);
    const S2 = mat.mul3d(V, mat.mul3d(S, Vt2));

    var result: [3]Mat3d = undefined;
    result[0] = S0;
    result[1] = S1;
    result[2] = S2;

    // Debug
    return result;
}

pub fn fillDistorsionTBO(allocator: std.mem.Allocator, sm: *SurfaceMesh, vertices_position_vbo: *VBO, ibo: *IBO, tbo: *TextureBuffer, celldata_triangleuvs: SurfaceMesh.CellData(.face, TriangleUVs)) void {

    // Map vertices position VBO
    gl.BindBuffer(gl.ARRAY_BUFFER, vertices_position_vbo.index);
    const ptr_vbo_position = gl.MapBuffer(gl.ARRAY_BUFFER, gl.READ_ONLY);
    const array_vbo_position: [*]Vec3f = @ptrCast(@alignCast(ptr_vbo_position.?));

    // Map IBO
    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ibo.index);
    const ptr_ibo = gl.MapBuffer(gl.ELEMENT_ARRAY_BUFFER, gl.READ_ONLY);
    const array_ibo: [*]u32 = @ptrCast(@alignCast(ptr_ibo));

    // Memory allocation for TBO
    const nb_triangle: usize = ibo.nb_indices / 3;
    const nb_vertices: usize = @intCast(@divExact(vertices_position_vbo.size, @sizeOf(Vec3f)));
    tbo.memoryAllocationForMapping(@intCast(nb_vertices * @sizeOf(Vec4f) * 3));

    //Map TBO
    gl.BindBuffer(gl.TEXTURE_BUFFER, tbo.index);
    const ptr_tbo = gl.MapBuffer(gl.TEXTURE_BUFFER, gl.READ_WRITE);
    const array_tbo: [*][3]Vec4f = @ptrCast(@alignCast(ptr_tbo));

    var id_face: usize = 0;

    const structAccumulationParamVertex = struct { sumAccumulationParam: [3]Vec2f, nb_contrib: [3]u32, id_sample: [3]u32 };
    var arrayAccumulationVertex = allocator.alloc(structAccumulationParamVertex, nb_vertices) catch unreachable;

    //TODO Display distorsion computing duration

    @memset(arrayAccumulationVertex, .{ .sumAccumulationParam = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } }, .nb_contrib = .{ 0, 0, 0 }, .id_sample = .{ std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32) } });
    defer allocator.free(arrayAccumulationVertex);
    // Compute distorsions per patch per vertex and store them in TBO
    while (id_face < nb_triangle) : (id_face += 1) {
        const id_vertices_triangle: [3]u32 = .{
            array_ibo[id_face * 3 + 0],
            array_ibo[id_face * 3 + 1],
            array_ibo[id_face * 3 + 2],
        };

        const S_d = computeDistorsion(@intCast(id_face), id_vertices_triangle, array_vbo_position, celldata_triangleuvs);

        // var S_d = computeDistorsion(@intCast(id_face), id_vertices_triangle, array_vbo_position, celldata_triangleuvs);
        // for (0..3) |i| {
        //     S_d[i] = eigen.computeInverse3d(S_d[i]).?;
        // }
        var S: [3]Mat2f = undefined;
        for (0..3) |u| {
            S[u][0][0] = @floatCast(S_d[u][0][0]);
            S[u][0][1] = @floatCast(S_d[u][0][1]);
            S[u][1][0] = @floatCast(S_d[u][1][0]);
            S[u][1][1] = @floatCast(S_d[u][1][1]);
        }

        const triangleuvs = celldata_triangleuvs.valueByIndex(@intCast(id_face));
        var problematic_vertices = sm.getOrAddCellSet(.vertex, "problematic_vertices") catch unreachable;

        for (0..3) |vertex| {
            const id_current_vertex = id_vertices_triangle[vertex];
            const param_current_vertex = &arrayAccumulationVertex[id_current_vertex];

            for (0..3) |patch| {
                var slot: u32 = 3;
                const id_current_patch = triangleuvs.samples[patch];
                var free_slot: u32 = 3;
                for (0..3) |s| {
                    if (param_current_vertex.id_sample[s] == std.math.maxInt(u32) and free_slot == 3) {
                        free_slot = @intCast(s);
                    } else if (param_current_vertex.id_sample[s] == id_current_patch) {
                        slot = @intCast(s);
                        break;
                    }
                }
                if (slot == 3) {
                    slot = free_slot;
                    if (free_slot == 3) {
                        problematic_vertices.add(.{ .vertex = id_current_vertex }) catch unreachable;
                        break;
                    } else {
                        param_current_vertex.id_sample[slot] = id_current_patch;
                    }
                }

                param_current_vertex.nb_contrib[slot] = param_current_vertex.nb_contrib[slot] + 1;
                const param_non_compensed = triangleuvs.uvs[patch][vertex];
                const param_compensed = mat.mulVec2f(S[patch], param_non_compensed);
                param_current_vertex.sumAccumulationParam[slot] = vec.add2f(param_current_vertex.sumAccumulationParam[slot], param_compensed);
            }
        }
    }
    for (arrayAccumulationVertex, 0..) |current_vertex_param, i| {
        var param_current_vertex: [3]Vec4f = .{ .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 } };

        for (0..3) |slot| {
            if (current_vertex_param.nb_contrib[slot] == 0) {
                continue;
            }

            const uv = vec.divScalar2f(current_vertex_param.sumAccumulationParam[slot], @floatFromInt(current_vertex_param.nb_contrib[slot]));
            param_current_vertex[slot] = .{ uv[0], uv[1], @floatFromInt(current_vertex_param.id_sample[slot]), 0 };
        }

        array_tbo[i] = param_current_vertex;
    }

    gl.TexBuffer(gl.TEXTURE_BUFFER, gl.RGBA32F, tbo.index);

    // Unmap all buffers
    gl.BindBuffer(gl.ARRAY_BUFFER, vertices_position_vbo.index);
    _ = gl.UnmapBuffer(gl.ARRAY_BUFFER);

    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ibo.index);
    _ = gl.UnmapBuffer(gl.ELEMENT_ARRAY_BUFFER);

    gl.BindBuffer(gl.TEXTURE_BUFFER, tbo.index);
    _ = gl.UnmapBuffer(gl.TEXTURE_BUFFER);
}
