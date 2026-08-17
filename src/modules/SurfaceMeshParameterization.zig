const SurfaceMeshParameterization = @This();

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const imgui_utils = @import("../ui/imgui.zig");
const zgp_log = std.log.scoped(.zgp);

const c = @import("c");

const AppContext = @import("../main.zig").AppContext;
const Module = @import("Module.zig");
const SurfaceMesh = @import("../models/surface/SurfaceMesh.zig");
const SurfacePoint = @import("../models/surface/SurfacePoint.zig");
const PointCloud = @import("../models/point/PointCloud.zig");

const SurfaceMeshIntrinsicTriangulation = @import("../modules/SurfaceMeshIntrinsicTriangulation.zig");

const vec = @import("../geometry/vec.zig");
const Vec3f = vec.Vec3f;
const Vec2f = vec.Vec2f;
const bvh = @import("../geometry/bvh.zig");

const sampling = @import("../models/surface/sampling.zig");
const distance = @import("../models/surface/distance.zig");

const ParameterizationData = struct {
    app_ctx: *AppContext,
    surface_mesh: *SurfaceMesh,
    vertex_uv: SurfaceMesh.CellData(.vertex, Vec2f) = undefined,

    intrinsic_triangulation_data: *SurfaceMeshIntrinsicTriangulation.ITData,

    samples: ?*PointCloud = null,
    sample_position: PointCloud.CellData(Vec3f) = undefined,
    sample_surface_point: PointCloud.CellData(SurfacePoint) = undefined,
    sample_color: PointCloud.CellData(Vec3f) = undefined,

    samples_surface_mesh: ?*SurfaceMesh = null,
    ssm_vertex_position: SurfaceMesh.CellData(.vertex, Vec3f) = undefined,
    ssm_vertex_sample: SurfaceMesh.CellData(.vertex, PointCloud.Point) = undefined,
    ssm_edge_path: SurfaceMesh.CellData(.edge, std.ArrayList(SurfaceMesh.Dart)) = undefined,

    fn generateSamples(
        pd: *ParameterizationData,
        sm_bvh: *bvh.TrianglesBVH,
        vertex_position: SurfaceMesh.CellData(.vertex, Vec3f),
        face_normal: SurfaceMesh.CellData(.face, Vec3f),
        poisson_radius: f32,
    ) !void {
        if (pd.samples) |samples| {
            samples.clearRetainingCapacity();
        } else {
            var buf: [64]u8 = undefined;
            const pc_name = std.fmt.bufPrint(&buf, "{s}_param_samples", .{pd.app_ctx.surface_mesh_store.surfaceMeshName(pd.surface_mesh).?}) catch "__param_samples";
            pd.samples = try pd.app_ctx.point_cloud_store.createPointCloud(pc_name);
            pd.sample_position = try pd.samples.?.addData(Vec3f, "position");
            pd.sample_surface_point = try pd.samples.?.addData(SurfacePoint, "surface_point");
            pd.sample_color = try pd.samples.?.addData(Vec3f, "color");
            pd.app_ctx.point_cloud_store.setPointCloudStdData(pd.samples.?, .{ .position = pd.sample_position });
        }

        try sampling.poissonDiskSamplePointsOnSurface(
            pd.app_ctx,
            pd.surface_mesh,
            sm_bvh,
            vertex_position,
            face_normal,
            pd.samples.?,
            pd.sample_position,
            pd.sample_surface_point,
            poisson_radius,
        );

        // snap samples to vertices
        var point_it = pd.samples.?.pointIterator();
        while (point_it.next()) |sample| {
            switch (pd.sample_surface_point.value(sample).type) {
                .vertex => {},
                .edge => |e| {
                    const d = e.cell.dart();
                    const v0: SurfaceMesh.Cell = .{ .vertex = d };
                    const v1: SurfaceMesh.Cell = .{ .vertex = pd.surface_mesh.phi1(d) };
                    if (e.t < 0.5) {
                        pd.sample_surface_point.valuePtr(sample).* = .{ .surface_mesh = pd.surface_mesh, .type = .{ .vertex = v0 } };
                        pd.sample_position.valuePtr(sample).* = vertex_position.value(v0);
                    } else {
                        pd.sample_surface_point.valuePtr(sample).* = .{ .surface_mesh = pd.surface_mesh, .type = .{ .vertex = v1 } };
                        pd.sample_position.valuePtr(sample).* = vertex_position.value(v1);
                    }
                },
                .face => |f| {
                    const d = f.cell.dart();
                    const v0: SurfaceMesh.Cell = .{ .vertex = d };
                    const v1: SurfaceMesh.Cell = .{ .vertex = pd.surface_mesh.phi1(d) };
                    const v2: SurfaceMesh.Cell = .{ .vertex = pd.surface_mesh.phi_1(d) };
                    if (f.bcoords[0] >= f.bcoords[1] and f.bcoords[0] >= f.bcoords[2]) {
                        pd.sample_surface_point.valuePtr(sample).* = .{ .surface_mesh = pd.surface_mesh, .type = .{ .vertex = v0 } };
                        pd.sample_position.valuePtr(sample).* = vertex_position.value(v0);
                    } else if (f.bcoords[1] >= f.bcoords[0] and f.bcoords[1] >= f.bcoords[2]) {
                        pd.sample_surface_point.valuePtr(sample).* = .{ .surface_mesh = pd.surface_mesh, .type = .{ .vertex = v1 } };
                        pd.sample_position.valuePtr(sample).* = vertex_position.value(v1);
                    } else {
                        pd.sample_surface_point.valuePtr(sample).* = .{ .surface_mesh = pd.surface_mesh, .type = .{ .vertex = v2 } };
                        pd.sample_position.valuePtr(sample).* = vertex_position.value(v2);
                    }
                },
            }
        }

        // assign random colors to the samples
        point_it.reset();
        var r = pd.app_ctx.rng.random();
        while (point_it.next()) |point| {
            pd.sample_color.valuePtr(point).* = .{ 0.5 + 0.5 * r.float(f32), 0.5 + 0.5 * r.float(f32), 0.5 + 0.5 * r.float(f32) };
        }

        pd.app_ctx.point_cloud_store.pointCloudConnectivityUpdated(pd.samples.?);
        pd.app_ctx.point_cloud_store.pointCloudDataUpdated(pd.samples.?, Vec3f, pd.sample_position);
        pd.app_ctx.point_cloud_store.pointCloudDataUpdated(pd.samples.?, Vec3f, pd.sample_color);
        pd.app_ctx.requestRedraw();
    }

    fn connectSamples(
        pd: *ParameterizationData,
        edge_length: SurfaceMesh.CellData(.edge, f32),
        corner_angle: SurfaceMesh.CellData(.corner, f32),
    ) !void {
        if (pd.samples == null) {
            return error.SamplesNotGenerated;
        }

        // if needed, initialize the intrinsic triangulation and flip edges to make it Delaunay
        if (!pd.intrinsic_triangulation_data.initialized) {
            pd.intrinsic_triangulation_data.init(edge_length, corner_angle) catch |err| {
                std.debug.print("Error during intrinsic triangulation initialization: {}\n", .{err});
            };
            pd.intrinsic_triangulation_data.flipToDelaunay() catch |err| {
                std.debug.print("Error during intrinsic triangulation Delaunay flip: {}\n", .{err});
            };
        }

        // create or clear the samples SurfaceMesh and its associated data
        if (pd.samples_surface_mesh) |ssm| {
            var e_it = try SurfaceMesh.CellIterator.init(ssm, .edge);
            defer e_it.deinit();
            while (e_it.next()) |e| {
                pd.ssm_edge_path.valuePtr(e).deinit(pd.app_ctx.allocator);
            }
            ssm.clearRetainingCapacity();
        } else {
            var buf: [64]u8 = undefined;
            const ssm_name = std.fmt.bufPrint(&buf, "{s}_param_ssm", .{pd.app_ctx.surface_mesh_store.surfaceMeshName(pd.surface_mesh).?}) catch "__param_ssm";
            pd.samples_surface_mesh = try pd.app_ctx.surface_mesh_store.createSurfaceMesh(ssm_name);
            pd.ssm_vertex_position = try pd.samples_surface_mesh.?.addData(.vertex, Vec3f, "position");
            pd.ssm_vertex_sample = try pd.samples_surface_mesh.?.addData(.vertex, PointCloud.Point, "sample");
            pd.ssm_edge_path = try pd.samples_surface_mesh.?.addData(.edge, std.ArrayList(SurfaceMesh.Dart), "edge_path");
            pd.app_ctx.surface_mesh_store.setSurfaceMeshStdData(pd.samples_surface_mesh.?, .{ .vertex_position = pd.ssm_vertex_position });
        }

        const t = std.Io.Timestamp.now(pd.app_ctx.io, .real);

        // each sample corresponds to a vertex in the underlying SurfaceMesh (samples have been snapped to vertices)
        // these vertices are used as the source vertices of a multi-source Dijkstra algorithm
        // that is performed on the intrinsic triangulation

        var it_source_vertices: std.ArrayList(SurfaceMesh.Cell) = try .initCapacity(pd.app_ctx.allocator, pd.samples.?.nbPoints());
        defer it_source_vertices.deinit(pd.app_ctx.allocator);

        // a hashmap to map each source vertex (represented by its index) back to its corresponding sample
        var source_vertex_sample: std.AutoArrayHashMapUnmanaged(u32, PointCloud.Point) = .empty;
        defer source_vertex_sample.deinit(pd.app_ctx.allocator);

        var point_it = pd.samples.?.pointIterator();
        while (point_it.next()) |sample| {
            const sp = pd.sample_surface_point.value(sample);
            // TODO: support samples that are edge or face SurfacePoints
            if (sp.type == .vertex) {
                const it_v = pd.intrinsic_triangulation_data.extrinsic_vertex_intrinsic_vertex.value(sp.type.vertex);
                try it_source_vertices.append(pd.app_ctx.allocator, it_v);
                try source_vertex_sample.put(pd.app_ctx.allocator, pd.surface_mesh.cellIndex(sp.type.vertex), sample);
            }
        }

        // compute the closest source vertex and distance to it for each vertex in the intrinsic triangulation
        const it_closest_source_distance = try pd.intrinsic_triangulation_data.intrinsic_surface_mesh.addData(.vertex, f32, "it_closest_source_distance");
        defer pd.intrinsic_triangulation_data.intrinsic_surface_mesh.removeData(.vertex, f32, it_closest_source_distance);
        const it_closest_source_vertex = try pd.intrinsic_triangulation_data.intrinsic_surface_mesh.addData(.vertex, ?SurfaceMesh.Cell, "it_closest_source_vertex");
        defer pd.intrinsic_triangulation_data.intrinsic_surface_mesh.removeData(.vertex, ?SurfaceMesh.Cell, it_closest_source_vertex);
        try distance.multiSourceDijkstraDistancesAndSources(
            pd.app_ctx,
            pd.intrinsic_triangulation_data.intrinsic_surface_mesh,
            it_source_vertices.items,
            pd.intrinsic_triangulation_data.intrinsic_edge_length,
            it_closest_source_distance,
            it_closest_source_vertex,
        );

        // for inspection purposes,
        // copy back the closest source distance and corresponding sample color in the underlying SurfaceMesh
        const vertex_distance = try pd.surface_mesh.getOrAddData(.vertex, f32, "closest_source_distance");
        const vertex_color = try pd.surface_mesh.getOrAddData(.vertex, Vec3f, "closest_sample_color");
        var it_v_it: SurfaceMesh.CellIterator = try .init(pd.intrinsic_triangulation_data.intrinsic_surface_mesh, .vertex);
        defer it_v_it.deinit();
        while (it_v_it.next()) |it_v| {
            // v is the vertex in the underlying SurfaceMesh corresponding to the intrinsic vertex it_v
            const v = pd.intrinsic_triangulation_data.intrinsic_vertex_extrinsic_sp.value(it_v).type.vertex;
            vertex_distance.valuePtr(v).* = it_closest_source_distance.value(it_v);
            // if the closest source vertex of it_v is not defined, it means it was not reachable from any source vertex
            if (it_closest_source_vertex.value(it_v)) |it_sv| {
                // sv is the vertex in the underlying SurfaceMesh corresponding to the intrinsic source vertex it_sv
                const sv = pd.intrinsic_triangulation_data.intrinsic_vertex_extrinsic_sp.value(it_sv).type.vertex;
                const sample = source_vertex_sample.get(pd.surface_mesh.cellIndex(sv)).?; // get the sample corresponding to the closest source vertex
                vertex_color.valuePtr(v).* = pd.sample_color.value(sample);
            } else {
                std.debug.print("Vertex {d} is not reachable from any source vertex\n", .{pd.surface_mesh.cellIndex(v)});
            }
        }
        pd.app_ctx.surface_mesh_store.surfaceMeshDataUpdated(pd.surface_mesh, .vertex, f32, vertex_distance);
        pd.app_ctx.surface_mesh_store.surfaceMeshDataUpdated(pd.surface_mesh, .vertex, Vec3f, vertex_color);

        // build the samples SurfaceMesh as the dual of the partition of the underlying SurfaceMesh induced by the computed closest source vertices
        defer {
            // declare connectivity and position update after the samples SurfaceMesh has been built
            pd.app_ctx.surface_mesh_store.surfaceMeshConnectivityUpdated(pd.samples_surface_mesh.?);
            pd.app_ctx.surface_mesh_store.surfaceMeshDataUpdated(pd.samples_surface_mesh.?, .vertex, Vec3f, pd.ssm_vertex_position);
        }
        // the following data is used to reconstruct the adjacency between faces after they have been created
        const ssm_darts_of_vertex = try pd.samples_surface_mesh.?.addData(.vertex, std.ArrayList(SurfaceMesh.Dart), "darts_of_vertex");
        defer pd.samples_surface_mesh.?.removeData(.vertex, std.ArrayList(SurfaceMesh.Dart), ssm_darts_of_vertex);
        var darts_array_lists_arena = std.heap.ArenaAllocator.init(pd.app_ctx.allocator);
        defer darts_array_lists_arena.deinit();
        // this data is used to map each sample to the index of its corresponding vertex in the samples SurfaceMesh
        const sample_ssm_vertex_index = try pd.samples.?.addData(u32, "sample_ssm_vertex_index");
        defer pd.samples.?.removeData(u32, sample_ssm_vertex_index);
        // create a vertex in the samples SurfaceMesh for each sample
        point_it.reset();
        while (point_it.next()) |sample| {
            const sp = pd.sample_surface_point.value(sample);
            if (sp.type == .vertex) {
                const vertex_index = try pd.samples_surface_mesh.?.getDataIndex(.vertex); // get a new vertex index
                pd.ssm_vertex_position.valuePtrByIndex(vertex_index).* = pd.sample_position.value(sample); // copy the position of the sample to the new vertex
                pd.ssm_vertex_sample.valuePtrByIndex(vertex_index).* = sample; // map the new vertex to the sample
                sample_ssm_vertex_index.valuePtr(sample).* = vertex_index; // map the sample to the new vertex index
                ssm_darts_of_vertex.valuePtrByIndex(vertex_index).* = try .initCapacity(darts_array_lists_arena.allocator(), 8);
            }
        }
        // create a face in the samples SurfaceMesh for each face in the intrinsic triangulation that has 3 different closest source vertices
        var it_f_it: SurfaceMesh.CellIterator = try .init(pd.intrinsic_triangulation_data.intrinsic_surface_mesh, .face);
        defer it_f_it.deinit();
        while (it_f_it.next()) |f| {
            const it_sv0 = it_closest_source_vertex.value(.{ .vertex = f.dart() });
            const it_sv1 = it_closest_source_vertex.value(.{ .vertex = pd.intrinsic_triangulation_data.intrinsic_surface_mesh.phi1(f.dart()) });
            const it_sv2 = it_closest_source_vertex.value(.{ .vertex = pd.intrinsic_triangulation_data.intrinsic_surface_mesh.phi_1(f.dart()) });
            if (it_sv0 != null and it_sv1 != null and it_sv2 != null) {
                const sv0 = pd.intrinsic_triangulation_data.intrinsic_vertex_extrinsic_sp.value(it_sv0.?).type.vertex; // get the corresponding vertex in the underlying SurfaceMesh
                const sv1 = pd.intrinsic_triangulation_data.intrinsic_vertex_extrinsic_sp.value(it_sv1.?).type.vertex;
                const sv2 = pd.intrinsic_triangulation_data.intrinsic_vertex_extrinsic_sp.value(it_sv2.?).type.vertex;
                const s0 = source_vertex_sample.get(pd.surface_mesh.cellIndex(sv0)).?; // these vertices are source vertices, so they must have a corresponding sample
                const s1 = source_vertex_sample.get(pd.surface_mesh.cellIndex(sv1)).?;
                const s2 = source_vertex_sample.get(pd.surface_mesh.cellIndex(sv2)).?;
                if (s0 != s1 and s1 != s2 and s2 != s0) {
                    const s0_ssm_vertex_index = sample_ssm_vertex_index.value(s0); // get the vertex indices in the samples SurfaceMesh corresponding to the samples
                    const s1_ssm_vertex_index = sample_ssm_vertex_index.value(s1);
                    const s2_ssm_vertex_index = sample_ssm_vertex_index.value(s2);
                    const face = try pd.samples_surface_mesh.?.addUnboundedFace(3); // create a new triangle face in the samples SurfaceMesh
                    const d0 = face.dart();
                    const d1 = pd.samples_surface_mesh.?.phi1(d0);
                    const d2 = pd.samples_surface_mesh.?.phi1(d1);
                    // index the darts of the new face with the corresponding vertex indices in the samples SurfaceMesh
                    pd.samples_surface_mesh.?.setDartCellIndex(d0, .vertex, s0_ssm_vertex_index);
                    pd.samples_surface_mesh.?.setDartCellIndex(d1, .vertex, s1_ssm_vertex_index);
                    pd.samples_surface_mesh.?.setDartCellIndex(d2, .vertex, s2_ssm_vertex_index);
                    // register the new darts in the darts_of_vertex data of the vertices of the samples SurfaceMesh (used to reconstruct phi2)
                    try ssm_darts_of_vertex.valuePtrByIndex(s0_ssm_vertex_index).append(darts_array_lists_arena.allocator(), d0);
                    try ssm_darts_of_vertex.valuePtrByIndex(s1_ssm_vertex_index).append(darts_array_lists_arena.allocator(), d1);
                    try ssm_darts_of_vertex.valuePtrByIndex(s2_ssm_vertex_index).append(darts_array_lists_arena.allocator(), d2);
                }
            }
        }
        // reconstruct the adjacency between faces in the samples SurfaceMesh
        var nb_boundary_edges: u32 = 0;
        var ssm_dart_it = pd.samples_surface_mesh.?.dartIterator();
        while (ssm_dart_it.next()) |d| {
            if (pd.samples_surface_mesh.?.phi2(d) == d) {
                const vertex_index = pd.samples_surface_mesh.?.dartCellIndex(d, .vertex);
                const next_vertex_index = pd.samples_surface_mesh.?.dartCellIndex(pd.samples_surface_mesh.?.phi1(d), .vertex);
                const next_vertex_darts = ssm_darts_of_vertex.valueByIndex(next_vertex_index);
                const opposite_dart = for (next_vertex_darts.items) |d2| {
                    if (pd.samples_surface_mesh.?.dartCellIndex(pd.samples_surface_mesh.?.phi1(d2), .vertex) == vertex_index) {
                        break d2;
                    }
                } else null;
                if (opposite_dart) |d2| {
                    if (pd.samples_surface_mesh.?.phi2(d2) != d2) {
                        zgp_log.err("Dart {} is already phi2-linked", .{d2});
                        pd.samples_surface_mesh.?.clearRetainingCapacity();
                        return error.InvalidSamplesSurfaceMesh;
                    }
                    pd.samples_surface_mesh.?.phi2Sew(d, d2);
                } else {
                    nb_boundary_edges += 1;
                }
            }
        }
        if (nb_boundary_edges > 0) { // should not happen
            zgp_log.info("found {d} boundary edges", .{nb_boundary_edges});
            const nb_boundary_faces = try pd.samples_surface_mesh.?.close();
            zgp_log.info("closed {d} boundary faces", .{nb_boundary_faces});
        }
        // vertices were already indexed above, but we need to index the edges and faces of the samples SurfaceMesh
        try pd.samples_surface_mesh.?.indexCells(.edge);
        try pd.samples_surface_mesh.?.indexCells(.face);

        if (builtin.mode == .Debug) {
            const ok = try pd.samples_surface_mesh.?.checkIntegrity();
            if (!ok) {
                zgp_log.err("Samples SurfaceMesh integrity check failed", .{});
                return error.InvalidSamplesSurfaceMesh;
            }
        }

        // for each edge of the samples SurfaceMesh, compute the corresponding path in the underlying SurfaceMesh
        const shortest_paths_set = try pd.surface_mesh.getOrAddCellSet(.edge, "shortest_paths");
        shortest_paths_set.clear();
        var ssm_e_it = try SurfaceMesh.CellIterator.init(pd.samples_surface_mesh.?, .edge);
        defer ssm_e_it.deinit();
        while (ssm_e_it.next()) |e| {
            const start_v: SurfaceMesh.Cell = pd.sample_surface_point.value(pd.ssm_vertex_sample.value(.{ .vertex = e.dart() })).type.vertex;
            const end_v: SurfaceMesh.Cell = pd.sample_surface_point.value(pd.ssm_vertex_sample.value(.{ .vertex = pd.samples_surface_mesh.?.phi1(e.dart()) })).type.vertex;
            const path = try distance.shortestEdgePathBetweenVertices(
                pd.app_ctx,
                pd.surface_mesh,
                start_v,
                end_v,
                edge_length,
            );
            for (path.items) |d| {
                try shortest_paths_set.add(.{ .edge = d });
            }
            pd.ssm_edge_path.valuePtr(e).* = path;
        }
        pd.app_ctx.surface_mesh_store.surfaceMeshCellSetUpdated(pd.surface_mesh, shortest_paths_set);

        const elapsed: f64 = @floatFromInt(std.Io.Timestamp.untilNow(t, pd.app_ctx.io, .real).nanoseconds);
        zgp_log.info("Samples SurfaceMesh computed in : {d:.3}ms", .{elapsed / std.time.ns_per_ms});

        pd.app_ctx.requestRedraw();
    }

    fn parameterizeSamplePatches(
        pd: *ParameterizationData,
    ) !void {
        if (pd.samples_surface_mesh == null) {
            return error.SamplesNotConnected;
        }

        const it_vertex_uv = try pd.intrinsic_triangulation_data.intrinsic_surface_mesh.addData(.vertex, Vec2f, "it_vertex_uv");
        defer pd.intrinsic_triangulation_data.intrinsic_surface_mesh.removeData(.vertex, Vec2f, it_vertex_uv);

        // UV coordinates computed in the intrinsic triangulation will be copied back to the underlying SurfaceMesh
        pd.vertex_uv = try pd.surface_mesh.getOrAddData(.vertex, Vec2f, "uv_coordinates");

        // start by computing local one-ring uv coordinates only for the first vertex of the samples SurfaceMesh
        // TODO: there are shortcuts to take in these mappings between the samples SurfaceMesh, the samples, the underlying SurfaceMesh and
        // the intrinsic triangulation, but for now we just go through all of them to be safe
        const ssm_v: SurfaceMesh.Cell = .{ .vertex = pd.samples_surface_mesh.?.dart_data.firstIndex() };
        const sample = pd.ssm_vertex_sample.value(ssm_v);
        const sm_origin_v = pd.sample_surface_point.value(sample).type.vertex;
        const it_origin_v = pd.intrinsic_triangulation_data.extrinsic_vertex_intrinsic_vertex.value(sm_origin_v);
        const origin_v_index = pd.surface_mesh.cellIndex(sm_origin_v);
        assert(origin_v_index == pd.intrinsic_triangulation_data.intrinsic_surface_mesh.cellIndex(it_origin_v));

        // select the vertices along the edge paths of the boundary of the one-ring of the origin vertex
        // delimits the patch of the surface mesh that will be parameterized around the origin vertex
        const v_one_ring_boundary = try pd.surface_mesh.getOrAddCellSet(.vertex, "one_ring_boundary");
        v_one_ring_boundary.clear();
        {
            var dart_it = pd.samples_surface_mesh.?.cellDartIterator(ssm_v);
            while (dart_it.next()) |d| {
                const path = pd.ssm_edge_path.value(.{ .edge = pd.samples_surface_mesh.?.phi1(d) });
                for (path.items) |dart| {
                    try v_one_ring_boundary.add(.{ .vertex = dart });
                }
            }
        }
        pd.app_ctx.surface_mesh_store.surfaceMeshCellSetUpdated(pd.surface_mesh, v_one_ring_boundary);

        // this data is used to store the incoming dart for each vertex in the shortest path tree
        // a null value indicates a vertex that has not been reached yet
        var incoming_dart = try pd.intrinsic_triangulation_data.intrinsic_surface_mesh.addData(.vertex, ?SurfaceMesh.Dart, "__incoming_dart");
        defer pd.intrinsic_triangulation_data.intrinsic_surface_mesh.removeData(.vertex, ?SurfaceMesh.Dart, incoming_dart);
        incoming_dart.data.fill(null);

        // Priority queue type for darts of the SurfaceMesh to expand from, ordered by their distance from the starting vertex
        const DartInfo = struct {
            const DartInfo = @This();
            dart: SurfaceMesh.Dart,
            distance: f32,
            angle: f32, // represent the angle from the origin vertex tangent space
            pub fn cmp(_: void, a: DartInfo, b: DartInfo) std.math.Order {
                const distance_order = std.math.order(a.distance, b.distance);
                if (distance_order != .eq) return distance_order;
                // tie-breaker: use Dart indices to have a deterministic order
                return std.math.order(a.dart, b.dart);
            }
        };
        const DartQueue = std.PriorityQueue(DartInfo, void, DartInfo.cmp);

        var queue: DartQueue = .empty;
        defer queue.deinit(pd.app_ctx.allocator);
        // initialize the queue with the darts outgoing from the origin vertex
        {
            var dart_it = pd.intrinsic_triangulation_data.intrinsic_surface_mesh.cellDartIterator(it_origin_v);
            while (dart_it.next()) |d| {
                try queue.push(
                    pd.app_ctx.allocator,
                    .{
                        .dart = d,
                        .distance = pd.intrinsic_triangulation_data.intrinsic_edge_length.value(.{ .edge = d }),
                        .angle = 0.0,
                    },
                );
            }
            // this vertex is the origin of the local one-ring patch, so its uv coordinates are set to (0, 0)
            it_vertex_uv.valuePtr(it_origin_v).* = .{ 0.0, 0.0 };
        }
        while (queue.pop()) |d_info| {
            const d = d_info.dart;
            const v: SurfaceMesh.Cell = .{ .vertex = d_info.dart };
            const pointed_v: SurfaceMesh.Cell = .{ .vertex = pd.intrinsic_triangulation_data.intrinsic_surface_mesh.phi1(d) };
            const pointed_v_index = pd.intrinsic_triangulation_data.intrinsic_surface_mesh.cellIndex(pointed_v);
            if (incoming_dart.value(pointed_v) != null or pointed_v_index == origin_v_index) {
                // this vertex has already been reached, or is the origin vertex, skip it
                continue;
            }
            // the queue is ordered by distance, so the first time we reach a vertex is the shortest path to it
            incoming_dart.valuePtr(pointed_v).* = d_info.dart;
            // the UV coordinates of pointed_v is equal to the UV coordinates of v + the vector from v to pointed_v
            const l = pd.intrinsic_triangulation_data.intrinsic_edge_length.value(.{ .edge = d });
            const a = pd.intrinsic_triangulation_data.intrinsic_halfedge_extrinsic_sp_angle.value(.{ .halfedge = d });
            const evec: Vec2f = .{
                l * std.math.cos(a),
                l * std.math.sin(a),
            };
            it_vertex_uv.valuePtr(pointed_v).* = vec.add2f(it_vertex_uv.value(v), evec);
            if (v_one_ring_boundary.contains(pointed_v)) {
                continue;
            }
            // add the outgoing darts from this vertex to the queue
            var dart_it = pd.intrinsic_triangulation_data.intrinsic_surface_mesh.cellDartIterator(pointed_v);
            while (dart_it.next()) |out_d| {
                const nv: SurfaceMesh.Cell = .{ .vertex = pd.intrinsic_triangulation_data.intrinsic_surface_mesh.phi1(out_d) };
                if (incoming_dart.value(nv) == null) {
                    try queue.push(
                        pd.app_ctx.allocator,
                        .{
                            .dart = out_d,
                            .distance = d_info.distance + pd.intrinsic_triangulation_data.intrinsic_edge_length.value(.{ .edge = out_d }),
                            .angle = 0.0,
                        },
                    );
                }
            }
        }

        pd.vertex_uv.data.copyFrom(it_vertex_uv.data);
        pd.app_ctx.surface_mesh_store.surfaceMeshDataUpdated(pd.surface_mesh, .vertex, Vec2f, pd.vertex_uv);
        pd.app_ctx.requestRedraw();
    }

    // this function is called when the underlying SurfaceMesh is destroyed
    fn surfaceMeshDestroyed(pd: *ParameterizationData) !void {
        if (pd.samples_surface_mesh) |ssm| {
            pd.app_ctx.surface_mesh_store.destroySurfaceMesh(ssm); // triggers the samplesSurfaceMeshDestroyed function
        }
        if (pd.samples) |samples| {
            pd.app_ctx.point_cloud_store.destroyPointCloud(samples); // triggers the samplesDestroyed function
        }
    }

    // this function is called when then samples PointCloud is destroyed
    fn samplesDestroyed(pd: *ParameterizationData) !void {
        pd.samples = null;
        pd.sample_position = undefined;
        pd.sample_surface_point = undefined;
        pd.sample_color = undefined;
        // if the samples SurfaceMesh exists, destroy it
        if (pd.samples_surface_mesh) |ssm| {
            pd.app_ctx.surface_mesh_store.destroySurfaceMesh(ssm); // triggers the samplesSurfaceMeshDestroyed function
        }
    }

    // this function is called when the samples SurfaceMesh is destroyed
    fn samplesSurfaceMeshDestroyed(pd: *ParameterizationData) !void {
        var e_it = try SurfaceMesh.CellIterator.init(pd.samples_surface_mesh.?, .edge);
        defer e_it.deinit();
        while (e_it.next()) |e| {
            pd.ssm_edge_path.valuePtr(e).deinit(pd.app_ctx.allocator);
        }
        pd.samples_surface_mesh = null;
        pd.ssm_vertex_position = undefined;
        pd.ssm_vertex_sample = undefined;
        pd.ssm_edge_path = undefined;
    }
};

app_ctx: *AppContext,
module: Module = .{
    .name = "Surface Mesh Parameterization",
    .supported_models = .{ .surface_mesh = true },
    .vtable = &.{
        .surfaceMeshCreated = surfaceMeshCreated,
        .surfaceMeshDestroyed = surfaceMeshDestroyed,
        .pointCloudDestroyed = pointCloudDestroyed,
        .rightPanel = rightPanel,
    },
},
surface_meshes_data: std.AutoHashMapUnmanaged(*SurfaceMesh, ParameterizationData) = .empty,
// explicit dependency on IntrinsicTriangulation module
surface_mesh_intrinsic_triangulation: *SurfaceMeshIntrinsicTriangulation,

pub fn init(app_ctx: *AppContext, surface_mesh_intrinsic_triangulation: *SurfaceMeshIntrinsicTriangulation) SurfaceMeshParameterization {
    return .{
        .app_ctx = app_ctx,
        .surface_mesh_intrinsic_triangulation = surface_mesh_intrinsic_triangulation,
    };
}

pub fn deinit(smp: *SurfaceMeshParameterization) void {
    var it = smp.surface_meshes_data.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.samples_surface_mesh) |ssm| {
            var e_it = SurfaceMesh.CellIterator.init(ssm, .edge) catch |err| {
                std.debug.print("Failed to initialize edge iterator for samples SurfaceMesh: {}\n", .{err});
                continue;
            };
            defer e_it.deinit();
            while (e_it.next()) |e| {
                entry.value_ptr.ssm_edge_path.valuePtr(e).deinit(smp.app_ctx.allocator);
            }
        }
    }
    smp.surface_meshes_data.deinit(smp.app_ctx.allocator);
}

/// Part of the Module interface.
/// Create and store a ParameterizationData for the created SurfaceMesh.
pub fn surfaceMeshCreated(m: *Module, surface_mesh: *SurfaceMesh) void {
    const smp: *SurfaceMeshParameterization = @alignCast(@fieldParentPtr("module", m));
    smp.surface_meshes_data.put(smp.app_ctx.allocator, surface_mesh, .{
        .app_ctx = smp.app_ctx,
        .surface_mesh = surface_mesh,
        .intrinsic_triangulation_data = smp.surface_mesh_intrinsic_triangulation.surfaceMeshIntrinsicTriangulationData(surface_mesh),
    }) catch |err| {
        std.debug.print("Failed to store ParameterizationData for new SurfaceMesh: {}\n", .{err});
        return;
    };
}

/// Part of the Module interface.
/// If the destroyed SurfaceMesh is used as samples SurfaceMesh for a SurfaceMesh, inform the associated ParameterizationData.
/// If the destroyed SurfaceMesh is the underlying SurfaceMesh of a ParameterizationData, inform the associated ParameterizationData.
pub fn surfaceMeshDestroyed(m: *Module, surface_mesh: *SurfaceMesh) void {
    const smp: *SurfaceMeshParameterization = @alignCast(@fieldParentPtr("module", m));
    // first case: the destroyed SurfaceMesh is used as samples SurfaceMesh for a SurfaceMesh
    var it = smp.surface_meshes_data.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.samples_surface_mesh == surface_mesh) {
            entry.value_ptr.samplesSurfaceMeshDestroyed() catch |err| {
                std.debug.print("Failed to handle destroyed samples SurfaceMesh for SurfaceMesh: {}\n", .{err});
            };
            // we can return here because a samples SurfaceMesh cannot be itself the underlying SurfaceMesh of a ParameterizationData
            // (or can it?)
            return;
        }
    }
    // second case: the destroyed SurfaceMesh is the underlying SurfaceMesh of a ParameterizationData
    const pd = smp.surface_meshes_data.getPtr(surface_mesh).?;
    pd.surfaceMeshDestroyed() catch |err| {
        std.debug.print("Failed to handle destroyed underlying SurfaceMesh for ParameterizationData: {}\n", .{err});
    };
    // remove the ParameterizationData from the hashmap
    _ = smp.surface_meshes_data.remove(surface_mesh);
}

/// Part of the Module interface.
/// If the destroyed PointCloud is used as samples for a SurfaceMesh, inform the associated ParameterizationData.
pub fn pointCloudDestroyed(m: *Module, point_cloud: *PointCloud) void {
    const smp: *SurfaceMeshParameterization = @alignCast(@fieldParentPtr("module", m));
    var it = smp.surface_meshes_data.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.samples == point_cloud) {
            entry.value_ptr.samplesDestroyed() catch |err| {
                std.debug.print("Failed to handle destroyed samples PointCloud for SurfaceMesh: {}\n", .{err});
            };
            break;
        }
    }
}

/// Part of the Module interface.
/// Show a UI panel to control the sampling of the selected SurfaceMesh.
pub fn rightPanel(m: *Module) void {
    const smp: *SurfaceMeshParameterization = @alignCast(@fieldParentPtr("module", m));
    const sm_store = &smp.app_ctx.surface_mesh_store;

    assert(smp.app_ctx.selected_model.modelType() == .surface_mesh);
    const sm = smp.app_ctx.selected_model.surface_mesh;

    const UiData = struct {
        var poisson_radius: f32 = 0.03;
    };

    const style = c.ImGui_GetStyle();

    c.ImGui_PushItemWidth(c.ImGui_GetWindowWidth() - style.*.ItemSpacing.x * 2);
    defer c.ImGui_PopItemWidth();

    const info = sm_store.surfaceMeshInfo(sm);
    const pd = smp.surface_meshes_data.getPtr(sm).?;

    {
        c.ImGui_SeparatorText("Samples generation");
        c.ImGui_Text("Minimum distance");
        c.ImGui_PushID("Minimum distance");
        _ = c.ImGui_InputFloat("", @ptrCast(&UiData.poisson_radius));
        c.ImGui_PopID();
        const disabled =
            !info.bvh.initialized or
            info.std_datas.vertex_position == null or
            info.std_datas.face_normal == null;
        if (disabled) {
            c.ImGui_BeginDisabled(true);
        }
        if (c.ImGui_ButtonEx("Generate samples", c.ImVec2{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0.0 })) {
            pd.generateSamples(
                &info.bvh,
                info.std_datas.vertex_position.?,
                info.std_datas.face_normal.?,
                UiData.poisson_radius,
            ) catch |err| {
                std.debug.print("Error during sampling: {}\n", .{err});
            };
        }
        if (disabled) {
            imgui_utils.tooltip(
                \\ Requires:
                \\ - a BVH
                \\ Following data should be available:
                \\ - std vertex_position
                \\ - std face_normal
            );
            c.ImGui_EndDisabled();
        }
    }
    {
        c.ImGui_SeparatorText("Samples connectivity");
        const disabled =
            pd.samples == null or
            info.std_datas.edge_length == null or
            info.std_datas.corner_angle == null;
        if (disabled) {
            c.ImGui_BeginDisabled(true);
        }
        if (c.ImGui_ButtonEx("Connect samples", c.ImVec2{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0.0 })) {
            pd.connectSamples(
                info.std_datas.edge_length.?,
                info.std_datas.corner_angle.?,
            ) catch |err| {
                std.debug.print("Error during samples connectivity computation: {}\n", .{err});
            };
        }
        if (disabled) {
            imgui_utils.tooltip(
                \\ Requires:
                \\ - generated samples
                \\ Following data should be available:
                \\ - std edge_length
                \\ - std corner_angle
            );
            c.ImGui_EndDisabled();
        }
    }
    {
        c.ImGui_SeparatorText("Sample patches parameterization");
        const disabled =
            pd.samples == null or
            pd.samples_surface_mesh == null;
        if (disabled) {
            c.ImGui_BeginDisabled(true);
        }
        if (c.ImGui_ButtonEx("Parameterize sample patches", c.ImVec2{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0.0 })) {
            pd.parameterizeSamplePatches() catch |err| {
                std.debug.print("Error during sample patches parameterization: {}\n", .{err});
            };
        }
        if (disabled) {
            imgui_utils.tooltip(
                \\ Requires:
                \\ - generated & connected samples
            );
            c.ImGui_EndDisabled();
        }
    }
}
