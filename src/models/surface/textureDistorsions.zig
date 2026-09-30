const std = @import("std");
const gl = @import("gl");
const assert = std.debug.assert;
const zgp_log = std.log.scoped(.zgp);

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

fn computeFFonPatch(uvs: [3]Vec2f, positions: [3]Vec3f, order: [3]usize) Mat3f {
    return computeF(vec.sub2f(uvs[order[1]], uvs[order[0]]), vec.sub2f(uvs[order[2]], uvs[order[0]]), positions[order[0]], positions[order[1]], positions[order[2]]);
}

fn computeDistorsion(id_triangle: u32, id_vertices_triangle: [3]u32, vbo_position: [*]Vec3f, celldata_triangleuvs: SurfaceMesh.CellData(.face, TriangleUVs)) [3]Mat3d {
    const positions: [3]Vec3f = .{
        vbo_position[id_vertices_triangle[0]],
        vbo_position[id_vertices_triangle[1]],
        vbo_position[id_vertices_triangle[2]],
    };
    const uv = celldata_triangleuvs.valueByIndex(id_triangle).uvs;
    const F0 = computeFFonPatch(uv[0], positions, .{ 0, 1, 2 });
    const F1 = computeFFonPatch(uv[1], positions, .{ 1, 2, 0 });
    const F2 = computeFFonPatch(uv[2], positions, .{ 2, 0, 1 });

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

// Compute texture Distorsions from SurfaceMeshParameterization Module and fill TBO with new UV
// Foreach mesh faces, we start by retrieve param info from SurfaceMeshParameterization Module and compute distorsion with Jacobi SVD
// For each faces, a deformation gradient F is assigned
// Our goal is to create three new vec2 for each vertices, one per patch
// We accumulate in each vertices for each patch, F orignal_uv * F and divide by number of contributions
// We have to be careful about patch ID to avoid blending between two different patch
pub fn computeTextureDistorsions(allocator: std.mem.Allocator, io: std.Io, sm: *SurfaceMesh, vertices_position_vbo: *VBO, ibo: *IBO, tbo: *TextureBuffer, celldata_triangleuvs: SurfaceMesh.CellData(.face, TriangleUVs)) void {
    const max_distorsion_slots_per_vertex = 8;

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
    tbo.memoryAllocationForMapping(@intCast(nb_vertices * @sizeOf(Vec4f) * max_distorsion_slots_per_vertex));

    //Map TBO
    gl.BindBuffer(gl.TEXTURE_BUFFER, tbo.index);
    const ptr_tbo = gl.MapBuffer(gl.TEXTURE_BUFFER, gl.READ_WRITE);
    const array_tbo: [*][max_distorsion_slots_per_vertex]Vec4f = @ptrCast(@alignCast(ptr_tbo));

    const structAccumulationParamVertex = struct {
        sumAccumulationParam: [max_distorsion_slots_per_vertex]Vec2f,
        nb_contrib: [max_distorsion_slots_per_vertex]u32,
        id_sample: [max_distorsion_slots_per_vertex]u32,
    };
    var arrayAccumulationVertex = allocator.alloc(structAccumulationParamVertex, nb_vertices) catch unreachable;

    @memset(arrayAccumulationVertex, .{
        .sumAccumulationParam = .{.{ 0, 0 }} ** max_distorsion_slots_per_vertex,
        .nb_contrib = .{0} ** max_distorsion_slots_per_vertex,
        .id_sample = .{std.math.maxInt(u32)} ** max_distorsion_slots_per_vertex,
    });
    defer allocator.free(arrayAccumulationVertex);

    const t = std.Io.Timestamp.now(io, .real);

    var id_face: usize = 0;
    // Compute distorsions per patch per vertex and store them in TBO
    while (id_face < nb_triangle) : (id_face += 1) {
        const id_vertices_triangle: [3]u32 = .{
            array_ibo[id_face * 3 + 0],
            array_ibo[id_face * 3 + 1],
            array_ibo[id_face * 3 + 2],
        };

        // Ccompute face distorsion
        const S_d = computeDistorsion(@intCast(id_face), id_vertices_triangle, array_vbo_position, celldata_triangleuvs);

        // Eigen need [3]f64 but we want to work with [3]f32
        var S: [3]Mat2f = undefined;
        for (0..3) |u| {
            S[u][0][0] = @floatCast(S_d[u][0][0]);
            S[u][0][1] = @floatCast(S_d[u][0][1]);
            S[u][1][0] = @floatCast(S_d[u][1][0]);
            S[u][1][1] = @floatCast(S_d[u][1][1]);
        }

        const triangleuvs = celldata_triangleuvs.valueByIndex(@intCast(id_face));
        var problematic_vertices = sm.getOrAddCellSet(.vertex, "problematic_vertices_texture_distorsion") catch unreachable;

        // We don't want to blend UV between two differents patch so we create for each vertices slots to keep track of patch ID
        for (0..3) |vertex| {
            const id_current_vertex = id_vertices_triangle[vertex];
            const param_current_vertex = &arrayAccumulationVertex[id_current_vertex];

            for (0..3) |patch| {
                const id_current_patch = triangleuvs.samples[patch];
                if (id_current_patch == std.math.maxInt(u32)) {
                    continue;
                }

                var slot: u32 = max_distorsion_slots_per_vertex;
                var free_slot: u32 = max_distorsion_slots_per_vertex;
                for (0..max_distorsion_slots_per_vertex) |s| {
                    if (param_current_vertex.id_sample[s] == std.math.maxInt(u32) and free_slot == max_distorsion_slots_per_vertex) { // slot free
                        free_slot = @intCast(s);
                    } else if (param_current_vertex.id_sample[s] == id_current_patch) { // patch already in one slot
                        slot = @intCast(s);
                        break;
                    }
                }
                if (slot == max_distorsion_slots_per_vertex) { // if patch is not already in slot array
                    slot = free_slot;
                    if (free_slot == max_distorsion_slots_per_vertex) {
                        problematic_vertices.add(.{ .vertex = id_current_vertex }) catch unreachable;
                        break;
                    } else {
                        param_current_vertex.id_sample[slot] = id_current_patch;
                    }
                }

                param_current_vertex.nb_contrib[slot] = param_current_vertex.nb_contrib[slot] + 1;
                const param_uncompensated = triangleuvs.uvs[patch][vertex];
                const param_compensated = mat.mulVec2f(S[patch], param_uncompensated);
                // UV accumulation in vertices
                param_current_vertex.sumAccumulationParam[slot] = vec.add2f(param_current_vertex.sumAccumulationParam[slot], param_compensated);
            }
        }
    }

    // We compute new corrected uv and store them in TBO
    for (arrayAccumulationVertex, 0..) |current_vertex_param, i| {
        var param_current_vertex: [max_distorsion_slots_per_vertex]Vec4f = .{.{ 0, 0, 0, 0 }} ** max_distorsion_slots_per_vertex;

        for (0..max_distorsion_slots_per_vertex) |slot| {
            if (current_vertex_param.nb_contrib[slot] == 0) {
                continue;
            }

            const uv = vec.divScalar2f(current_vertex_param.sumAccumulationParam[slot], @floatFromInt(current_vertex_param.nb_contrib[slot]));
            // Fragment shader need to know the patch ID of a newly received UV
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

    const elapsed: f64 = @floatFromInt(std.Io.Timestamp.untilNow(t, io, .real).nanoseconds);
    zgp_log.info("Texture distorsions computed in : {d:.3}ms", .{elapsed / std.time.ns_per_ms});
}
