const std = @import("std");
const gl = @import("gl");
const zgp_log = std.log.scoped(.zgp);

const SurfaceMesh = @import("SurfaceMesh.zig");
const TriangleUVs = @import("../../modules/SurfaceMeshParameterization.zig").ParameterizationData.TriangleUVs;
const vec = @import("../../geometry/vec.zig");
const Vec2f = vec.Vec2f;
const Vec3f = vec.Vec3f;
const mat = @import("../../geometry/mat.zig");
const Mat2f = mat.Mat2f;
const Mat3f = mat.Mat3f;
const Mat3d = mat.Mat3d;
const eigen = @import("../../geometry/eigen.zig");
const geometry_utils = @import("../../geometry/utils.zig");
const IBO = @import("../../rendering/IBO.zig");

fn computeF(uv01: Vec2f, uv02: Vec2f, x0: Vec3f, x1: Vec3f, x2: Vec3f) Mat3f {
    // On exprime les deux arêtes du triangle dans les deux espaces :
    //   U : arêtes dans le plan UV, avec une troisième direction artificielle (z = 1) ;
    //   X : arêtes 3D, complétées par la normale du triangle.
    // Avec des vecteurs colonnes, F = X * inverse(U) transforme un déplacement UV
    // en déplacement dans le repère tangent 3D de cette face.
    const uv01_extended: Vec3f = .{ uv01[0], uv01[1], 0 };
    const uv02_extended: Vec3f = .{ uv02[0], uv02[1], 0 };

    const x01: Vec3f = vec.sub(x1, x0);
    const x02: Vec3f = vec.sub(x2, x0);

    const n: Vec3f = vec.normalized(vec.cross(x01, x02));
    const X: Mat3d = .{ vec.vec3fToVec3d(x01), vec.vec3fToVec3d(x02), vec.vec3fToVec3d(n) };
    const U: Mat3d = .{ vec.vec3fToVec3d(uv01_extended), vec.vec3fToVec3d(uv02_extended), .{ 0.0, 0.0, 1.0 } };
    const U_1: Mat3d = eigen.computeInverse3d(U).?;

    const XUU_1: Mat3d = mat.mul(X, U_1);

    return mat.mat3dToMat3f(XUU_1);
}

fn computeFFonPatch(uvs: [3]Vec2f, positions: [3]Vec3f, order: [3]usize) Mat3f {
    // L'ordre des coins dépend du patch : le premier coin sert d'origine UV,
    // les deux autres définissent les arêtes utilisées par computeF.
    return computeF(vec.sub(uvs[order[1]], uvs[order[0]]), vec.sub(uvs[order[2]], uvs[order[0]]), positions[order[0]], positions[order[1]], positions[order[2]]);
}

fn computeDistorsion(id_triangle: u32, id_vertices_triangle: [3]u32, vbo_position: [*]Vec3f, celldata_triangleuvs: SurfaceMesh.CellData(.face, TriangleUVs)) [3]Mat3d {
    const positions: [3]Vec3f = .{
        vbo_position[id_vertices_triangle[0]],
        vbo_position[id_vertices_triangle[1]],
        vbo_position[id_vertices_triangle[2]],
    };
    const uv = celldata_triangleuvs.value(.{ .index = id_triangle }).uvs;
    // Une face appartient à trois patches. On mesure donc F séparément pour chaque
    // paramétrisation UV ; l'ordre des coins est tourné pour que chaque patch ait
    // son propre sommet d'origine.
    const F0 = computeFFonPatch(uv[0], positions, .{ 0, 1, 2 });
    const F1 = computeFFonPatch(uv[1], positions, .{ 1, 2, 0 });
    const F2 = computeFFonPatch(uv[2], positions, .{ 2, 0, 1 });

    // Décomposition polaire issue de la SVD : F = U * Sigma * V^T.
    // V * Sigma * V^T conserve l'étirement dans le domaine UV en retirant
    // la rotation portée par U. Le code utilise ensuite directement ce tenseur
    // comme transformation cible des arêtes ; il ne calcule pas son inverse.
    const F0d = mat.mat3fToMat3d(F0);
    var res = eigen.computeJacobiSVD3D(F0d);
    var U: Mat3d = res[0];
    var S: Mat3d = res[1];
    var V: Mat3d = res[2];
    const Vt0 = mat.transpose(V);
    const S0 = mat.mul(V, mat.mul(S, Vt0));

    const F1d = mat.mat3fToMat3d(F1);
    res = eigen.computeJacobiSVD3D(F1d);
    U = res[0];
    S = res[1];
    V = res[2];
    const Vt1 = mat.transpose(V);
    const S1 = mat.mul(V, mat.mul(S, Vt1));

    const F2d = mat.mat3fToMat3d(F2);
    res = eigen.computeJacobiSVD3D(F2d);
    U = res[0];
    S = res[1];
    V = res[2];
    const Vt2 = mat.transpose(V);
    const S2 = mat.mul(V, mat.mul(S, Vt2));

    var result: [3]Mat3d = undefined;
    result[0] = S0;
    result[1] = S1;
    result[2] = S2;

    return result;
}

// Retourne, pour chaque patch de la face, le bloc 2x2 de son tenseur d'étirement.
pub fn computeFaceDistorsions(
    f: SurfaceMesh.Face,
    ibo: [*]u32,
    vbo_position: []Vec3f,
    triangle_uv: SurfaceMesh.FaceData(TriangleUVs),
) [3]Mat2f {
    const id_face = f.index;
    // L'IBO est construit avec exactement trois indices consécutifs par face.
    const id_vertices_triangle: [3]u32 = .{
        ibo[id_face * 3 + 0],
        ibo[id_face * 3 + 1],
        ibo[id_face * 3 + 2],
    };

    const S_d = computeDistorsion(@intCast(id_face), id_vertices_triangle, vbo_position.ptr, triangle_uv);

    // Le calcul Eigen/SVD se fait en f64 ; le solveur UV et les buffers de rendu
    // utilisent des f32. On ne garde que les deux premières dimensions UV.
    var S: [3]Mat2f = undefined;
    for (0..3) |u| {
        S[u][0][0] = @floatCast(S_d[u][0][0]);
        S[u][0][1] = @floatCast(S_d[u][0][1]);
        S[u][1][0] = @floatCast(S_d[u][1][0]);
        S[u][1][1] = @floatCast(S_d[u][1][1]);
    }
    return S;
}

fn uvVariableKey(sample_id: u32, vertex_id: u32) u64 {
    // Un même sommet du maillage peut avoir une UV différente dans chaque patch.
    // La variable globale est donc indexée par le couple (patch, sommet), pas par le sommet seul.
    return (@as(u64, sample_id) << 32) | vertex_id;
}

fn findRoot(parent: []u32, index: u32) u32 {
    // Recherche la racine qui identifie la composante connexe de cette variable.
    var root = index;
    while (parent[root] != root) root = parent[root];

    // Compression de chemin : les recherches suivantes dans cette composante seront plus rapides.
    var current = index;
    while (parent[current] != current) {
        const next = parent[current];
        parent[current] = root;
        current = next;
    }
    return root;
}

fn unionRoots(parent: []u32, a: u32, b: u32) void {
    // Fusionne les composantes de deux variables UV reliées par une arête de triangle.
    const root_a = findRoot(parent, a);
    const root_b = findRoot(parent, b);
    if (root_a != root_b) parent[root_b] = root_a;
}

// Construit un champ UV par patch en projetant les déformations locales des faces
// sur des UV partagées aux sommets. La continuité est ainsi imposée entre faces
// qui partagent le même sommet dans le même patch.
//
// Étapes principales :
// 1. calculer une transformation locale par face et patch ;
// 2. créer une inconnue UV unique pour chaque couple (patch, sommet) ;
// 3. assembler les contraintes de déplacement des arêtes dans un système creux ;
// 4. résoudre séparément U et V, puis recopier les solutions dans les données de face.
pub fn computeCorrectedTextureUVs(
    allocator: std.mem.Allocator,
    io: std.Io,
    sm: *SurfaceMesh,
    vertices_position_vbo: SurfaceMesh.VertexData(Vec3f),
    ibo: *IBO,
    celldata_triangleuvs: SurfaceMesh.FaceData(TriangleUVs),
) SurfaceMesh.FaceData([3][3]Vec2f) {
    const array_vbo_position = vertices_position_vbo.data.storage.items;

    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ibo.index);
    const ptr_ibo = gl.MapBuffer(gl.ELEMENT_ARRAY_BUFFER, gl.READ_ONLY);
    const array_ibo: [*]u32 = @ptrCast(@alignCast(ptr_ibo));

    const corrected_uv_data = sm.getOrAddData(.face, [3][3]Vec2f, "corrected_texture_uvs") catch |err| {
        std.debug.panic("Failed to create corrected texture UV celldata: {}\n", .{err});
    };
    var corrected_uv_celldata = corrected_uv_data.@"0";

    const face_distorsions = allocator.alloc([3]Mat2f, celldata_triangleuvs.data.storage.items.len) catch unreachable;
    defer allocator.free(face_distorsions);
    const face_areas = allocator.alloc(f32, celldata_triangleuvs.data.storage.items.len) catch unreachable;
    defer allocator.free(face_areas);

    const t = std.Io.Timestamp.now(io, .real);
    const ComputeFaceDistorsionTask = struct {
        ibo: [*]u32,
        vbo_position: []Vec3f,
        triangle_uv: SurfaceMesh.FaceData(TriangleUVs),
        face_distorsions: [][3]Mat2f,
        face_areas: []f32,

        pub fn run(task: *@This(), face: SurfaceMesh.Face) void {
            task.face_distorsions[face.index] = computeFaceDistorsions(
                face,
                task.ibo,
                task.vbo_position,
                task.triangle_uv,
            );
            const positions: [3]Vec3f = .{
                task.vbo_position[task.ibo[face.index * 3]],
                task.vbo_position[task.ibo[face.index * 3 + 1]],
                task.vbo_position[task.ibo[face.index * 3 + 2]],
            };
            task.face_areas[face.index] = geometry_utils.triangleArea(positions[0], positions[1], positions[2]);
        }
    };

    var face_task_runner = SurfaceMesh.ParallelFaceTaskRunner.init(sm) catch unreachable;
    defer face_task_runner.deinit();
    face_task_runner.run(io, ComputeFaceDistorsionTask{
        .ibo = array_ibo,
        .vbo_position = array_vbo_position,
        .triangle_uv = celldata_triangleuvs,
        .face_distorsions = face_distorsions,
        .face_areas = face_areas,
    }) catch unreachable;

    var variable_indices: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer variable_indices.deinit(allocator);
    var original_uvs: std.ArrayList(Vec2f) = .empty;
    defer original_uvs.deinit(allocator);
    var face_it = sm.faceIterator();
    while (face_it.next()) |face| {
        const face_uvs = celldata_triangleuvs.value(face);
        for (0..3) |patch| {
            const sample_id = face_uvs.samples[patch];

            for (0..3) |corner| {
                const vertex_id = array_ibo[face.index * 3 + corner];
                const key = uvVariableKey(sample_id, vertex_id);
                const result = variable_indices.getOrPut(allocator, key) catch unreachable;
                if (!result.found_existing) {
                    result.value_ptr.* = @intCast(original_uvs.items.len);
                    original_uvs.append(allocator, face_uvs.uvs[patch][corner]) catch unreachable;
                }
            }
        }
    }

    const variable_count = original_uvs.items.len;
    const parents = allocator.alloc(u32, variable_count) catch unreachable;
    defer allocator.free(parents);
    for (parents, 0..) |*parent, index| parent.* = @intCast(index);

    face_it = sm.faceIterator();
    while (face_it.next()) |face| {
        if (face_areas[face.index] <= 0) continue;
        const face_uvs = celldata_triangleuvs.value(face);
        for (0..3) |patch| {
            const sample_id = face_uvs.samples[patch];
            if (sample_id == std.math.maxInt(u32)) continue;

            const variable_0 = variable_indices.get(uvVariableKey(sample_id, array_ibo[face.index * 3])).?;
            const variable_1 = variable_indices.get(uvVariableKey(sample_id, array_ibo[face.index * 3 + 1])).?;
            const variable_2 = variable_indices.get(uvVariableKey(sample_id, array_ibo[face.index * 3 + 2])).?;
            unionRoots(parents, variable_0, variable_1);
            unionRoots(parents, variable_0, variable_2);
        }
    }

    const root_has_anchor = allocator.alloc(bool, variable_count) catch unreachable;
    defer allocator.free(root_has_anchor);
    @memset(root_has_anchor, false);
    const variable_is_anchor = allocator.alloc(bool, variable_count) catch unreachable;
    defer allocator.free(variable_is_anchor);
    @memset(variable_is_anchor, false);
    for (0..variable_count) |index| {
        const root = findRoot(parents, @intCast(index));
        if (!root_has_anchor[root]) {
            root_has_anchor[root] = true;
            variable_is_anchor[index] = true;
        }
    }

    const free_indices = allocator.alloc(i32, variable_count) catch unreachable;
    defer allocator.free(free_indices);
    var free_variable_count: usize = 0;
    for (variable_is_anchor, 0..) |is_anchor, index| {
        if (is_anchor) {
            free_indices[index] = -1;
        } else {
            free_indices[index] = @intCast(free_variable_count);
            free_variable_count += 1;
        }
    }

    var rhs_x: []eigen.Scalar = &.{};
    var rhs_y: []eigen.Scalar = &.{};
    var solution_x: []eigen.Scalar = &.{};
    var solution_y: []eigen.Scalar = &.{};
    defer allocator.free(rhs_x);
    defer allocator.free(rhs_y);
    defer allocator.free(solution_x);
    defer allocator.free(solution_y);

    if (free_variable_count > 0) {
        rhs_x = allocator.alloc(eigen.Scalar, free_variable_count) catch unreachable;
        rhs_y = allocator.alloc(eigen.Scalar, free_variable_count) catch unreachable;
        solution_x = allocator.alloc(eigen.Scalar, free_variable_count) catch unreachable;
        solution_y = allocator.alloc(eigen.Scalar, free_variable_count) catch unreachable;
        @memset(rhs_x, 0);
        @memset(rhs_y, 0);

        var triplets: std.ArrayList(eigen.SparseMatrix.Triplet) = .empty;
        defer triplets.deinit(allocator);

        const triplet_capacity = std.math.mul(usize, sm.nbCells(.face), 36) catch unreachable;
        triplets.ensureTotalCapacity(allocator, triplet_capacity) catch unreachable;
        face_it = sm.faceIterator();
        while (face_it.next()) |face| {
            const face_uvs = celldata_triangleuvs.value(face);
            const area = face_areas[face.index];
            if (area <= 0) continue;

            for (0..3) |patch| {
                const sample_id = face_uvs.samples[patch];
                if (sample_id == std.math.maxInt(u32)) continue;

                const distortion = face_distorsions[face.index][patch];
                const variables = [3]u32{
                    variable_indices.get(uvVariableKey(sample_id, array_ibo[face.index * 3])).?,
                    variable_indices.get(uvVariableKey(sample_id, array_ibo[face.index * 3 + 1])).?,
                    variable_indices.get(uvVariableKey(sample_id, array_ibo[face.index * 3 + 2])).?,
                };
                const weight: eigen.Scalar = @floatCast(area);
                for (0..3) |edge| {
                    const next = (edge + 1) % 3;
                    const variable_i = variables[edge];
                    const variable_j = variables[next];
                    const free_i = free_indices[variable_i];
                    const free_j = free_indices[variable_j];
                    const delta = mat.mulVec(
                        distortion,
                        vec.sub(face_uvs.uvs[patch][next], face_uvs.uvs[patch][edge]),
                    );

                    if (free_i >= 0) {
                        const row_i: i32 = free_i;

                        triplets.append(allocator, .{ .row = row_i, .col = row_i, .value = weight }) catch unreachable;
                        rhs_x[@intCast(row_i)] -= weight * @as(eigen.Scalar, delta[0]);
                        rhs_y[@intCast(row_i)] -= weight * @as(eigen.Scalar, delta[1]);
                        if (free_j < 0) {
                            // Si j est une ancre, son UV connue passe dans le second membre :
                            // -w*X_j se déplace à droite et devient +w*X_j.
                            const anchor_uv = original_uvs.items[variable_j];
                            rhs_x[@intCast(row_i)] += weight * @as(eigen.Scalar, anchor_uv[0]);
                            rhs_y[@intCast(row_i)] += weight * @as(eigen.Scalar, anchor_uv[1]);
                        }
                    }

                    if (free_j >= 0) {
                        const row_j: i32 = free_j;

                        triplets.append(allocator, .{ .row = row_j, .col = row_j, .value = weight }) catch unreachable;
                        rhs_x[@intCast(row_j)] += weight * @as(eigen.Scalar, delta[0]);
                        rhs_y[@intCast(row_j)] += weight * @as(eigen.Scalar, delta[1]);
                        if (free_i < 0) {
                            // Même traitement de la valeur connue lorsqu'i est l'ancre.
                            const anchor_uv = original_uvs.items[variable_i];
                            rhs_x[@intCast(row_j)] += weight * @as(eigen.Scalar, anchor_uv[0]);
                            rhs_y[@intCast(row_j)] += weight * @as(eigen.Scalar, anchor_uv[1]);
                        }
                    }

                    if (free_i >= 0 and free_j >= 0) {
                        const row_i: i32 = free_i;
                        const row_j: i32 = free_j;
                        triplets.append(allocator, .{ .row = row_i, .col = row_j, .value = -weight }) catch unreachable;
                        triplets.append(allocator, .{ .row = row_j, .col = row_i, .value = -weight }) catch unreachable;
                    }
                }
            }
        }

        var matrix: eigen.SparseMatrix = .initFromTriplets(
            @intCast(free_variable_count),
            @intCast(free_variable_count),
            triplets.items,
        );
        defer matrix.deinit();
        var factorized_matrix: eigen.FactorizedSparseMatrix = .init(matrix, @intCast(free_variable_count));
        defer factorized_matrix.deinit();
        factorized_matrix.solve(rhs_x, solution_x);
        factorized_matrix.solve(rhs_y, solution_y);
    }

    face_it = sm.faceIterator();
    while (face_it.next()) |face| {
        const face_uvs = celldata_triangleuvs.value(face);
        var corrected_uvs = face_uvs.uvs;
        for (0..3) |patch| {
            const sample_id = face_uvs.samples[patch];
            if (sample_id == std.math.maxInt(u32)) continue;
            for (0..3) |corner| {
                const vertex_id = array_ibo[face.index * 3 + corner];
                const variable_index = variable_indices.get(uvVariableKey(sample_id, vertex_id)).?;
                const free_index = free_indices[variable_index];
                if (free_index >= 0) {
                    corrected_uvs[patch][corner] = .{
                        @floatCast(solution_x[@intCast(free_index)]),
                        @floatCast(solution_y[@intCast(free_index)]),
                    };
                } else {
                    corrected_uvs[patch][corner] = original_uvs.items[variable_index];
                }
            }
        }
        corrected_uv_celldata.valuePtr(face).* = corrected_uvs;
    }

    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ibo.index);
    _ = gl.UnmapBuffer(gl.ELEMENT_ARRAY_BUFFER);

    const elapsed: f64 = @floatFromInt(std.Io.Timestamp.untilNow(t, io, .real).nanoseconds);
    zgp_log.info("Continuous texture UVs computed in : {d:.3}ms", .{elapsed / std.time.ns_per_ms});

    return corrected_uv_celldata;
}
