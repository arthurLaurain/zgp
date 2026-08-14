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

const vec = @import("../geometry/vec.zig");
const Vec3f = vec.Vec3f;
const bvh = @import("../geometry/bvh.zig");

const sampling = @import("../models/surface/sampling.zig");
const distance = @import("../models/surface/distance.zig");

const ParameterizationData = struct {
    app_ctx: *AppContext,

    surface_mesh: *SurfaceMesh,
    sm_vertex_color: SurfaceMesh.CellData(.vertex, Vec3f) = undefined,

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
    ) !void {
        if (pd.samples == null) {
            return error.SamplesNotGenerated;
        }

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

            pd.sm_vertex_color = try pd.surface_mesh.addData(.vertex, Vec3f, "closest_sample_color");
        }

        const t = std.Io.Timestamp.now(pd.app_ctx.io, .real);

        // each sample corresponds to a vertex in the underlying SurfaceMesh (samples have been snapped to vertices)
        // these vertices are the source vertices
        var source_vertices: std.ArrayList(SurfaceMesh.Cell) = try .initCapacity(pd.app_ctx.allocator, pd.samples.?.nbPoints());
        defer source_vertices.deinit(pd.app_ctx.allocator);
        // use a hashmap to map each source vertex back to its corresponding sample
        // (could have use a VertexData but there are not so many vertices that correspond to samples, so it would have been mostly empty)
        var source_vertex_sample: std.AutoArrayHashMapUnmanaged(SurfaceMesh.Cell, PointCloud.Point) = .empty;
        defer source_vertex_sample.deinit(pd.app_ctx.allocator);
        var point_it = pd.samples.?.pointIterator();
        while (point_it.next()) |sample| {
            const sp = pd.sample_surface_point.value(sample);
            // TODO: support samples that are edge or face SurfacePoints
            if (sp.type == .vertex) {
                try source_vertices.append(pd.app_ctx.allocator, sp.type.vertex);
                try source_vertex_sample.put(pd.app_ctx.allocator, sp.type.vertex, sample);
            }
        }
        // compute the closest source vertex and distance to it for each vertex of the underlying SurfaceMesh
        const closest_source_distance = try pd.surface_mesh.addData(.vertex, f32, "closest_source_distance");
        defer pd.surface_mesh.removeData(.vertex, f32, closest_source_distance);
        const closest_source_vertex = try pd.surface_mesh.addData(.vertex, ?SurfaceMesh.Cell, "closest_source_vertex");
        defer pd.surface_mesh.removeData(.vertex, ?SurfaceMesh.Cell, closest_source_vertex);
        try distance.multiSourceDijkstraDistancesAndSources(pd.app_ctx, pd.surface_mesh, source_vertices.items, edge_length, closest_source_distance, closest_source_vertex);

        // assign to each vertex of the underlying SurfaceMesh the color of its closest sample
        var sm_v_it: SurfaceMesh.CellIterator = try .init(pd.surface_mesh, .vertex);
        defer sm_v_it.deinit();
        while (sm_v_it.next()) |v| {
            // if the closest source vertex is not defined, it means vertex v is not reachable from any source vertex
            if (closest_source_vertex.value(v)) |sv| {
                const sample = source_vertex_sample.get(sv).?; // get the sample corresponding to the closest source vertex
                pd.sm_vertex_color.valuePtr(v).* = pd.sample_color.value(sample);
            }
        }
        pd.app_ctx.surface_mesh_store.surfaceMeshDataUpdated(pd.surface_mesh, .vertex, Vec3f, pd.sm_vertex_color);

        // build the samples SurfaceMesh as the dual of the partition of the underlying SurfaceMesh induced by the computed closest source vertices
        // this data is used to reconstruct the adjacency between faces after they have been created
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
                ssm_darts_of_vertex.valuePtrByIndex(vertex_index).* = .empty; // no darts yet for this vertex
            }
        }
        // create a face in the samples SurfaceMesh for each face in the underlying SurfaceMesh that has 3 different closest source vertices
        var sm_f_it: SurfaceMesh.CellIterator = try .init(pd.surface_mesh, .face);
        defer sm_f_it.deinit();
        while (sm_f_it.next()) |f| {
            const v0 = closest_source_vertex.value(.{ .vertex = f.dart() });
            const v1 = closest_source_vertex.value(.{ .vertex = pd.surface_mesh.phi1(f.dart()) });
            const v2 = closest_source_vertex.value(.{ .vertex = pd.surface_mesh.phi_1(f.dart()) });
            if (v0 != null and v1 != null and v2 != null) {
                const s0 = source_vertex_sample.get(v0.?).?; // these vertices are source vertices, so they must have a corresponding sample
                const s1 = source_vertex_sample.get(v1.?).?;
                const s2 = source_vertex_sample.get(v2.?).?;
                if (s0 != s1 and s1 != s2 and s2 != s0) {
                    const s0_vertex_index = sample_ssm_vertex_index.value(s0); // get the vertex indices in the samples SurfaceMesh corresponding to the samples
                    const s1_vertex_index = sample_ssm_vertex_index.value(s1);
                    const s2_vertex_index = sample_ssm_vertex_index.value(s2);
                    const face = try pd.samples_surface_mesh.?.addUnboundedFace(3); // create a new triangle face in the samples SurfaceMesh
                    const d0 = face.dart();
                    const d1 = pd.samples_surface_mesh.?.phi1(d0);
                    const d2 = pd.samples_surface_mesh.?.phi1(d1);
                    // index the darts of the new face with the corresponding vertex indices in the samples SurfaceMesh
                    pd.samples_surface_mesh.?.setDartCellIndex(d0, .vertex, s0_vertex_index);
                    pd.samples_surface_mesh.?.setDartCellIndex(d1, .vertex, s1_vertex_index);
                    pd.samples_surface_mesh.?.setDartCellIndex(d2, .vertex, s2_vertex_index);
                    // register the new darts in the darts_of_vertex data of the vertices of the samples SurfaceMesh (used to reconstruct phi2)
                    try ssm_darts_of_vertex.valuePtrByIndex(s0_vertex_index).append(darts_array_lists_arena.allocator(), d0);
                    try ssm_darts_of_vertex.valuePtrByIndex(s1_vertex_index).append(darts_array_lists_arena.allocator(), d1);
                    try ssm_darts_of_vertex.valuePtrByIndex(s2_vertex_index).append(darts_array_lists_arena.allocator(), d2);
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

        pd.app_ctx.surface_mesh_store.surfaceMeshConnectivityUpdated(pd.samples_surface_mesh.?);
        pd.app_ctx.surface_mesh_store.surfaceMeshDataUpdated(pd.samples_surface_mesh.?, .vertex, Vec3f, pd.ssm_vertex_position);

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

        // get the first vertex of the samples SurfaceMesh to parameterize its one-ring
        const v: SurfaceMesh.Cell = .{ .vertex = pd.samples_surface_mesh.?.dart_data.firstIndex() };

        // select the vertices along the edge paths of the boundary of the one-ring of vertex v
        const v_one_ring_boundary = try pd.surface_mesh.getOrAddCellSet(.vertex, "one_ring_boundary");
        v_one_ring_boundary.clear();

        var dart_it = pd.samples_surface_mesh.?.cellDartIterator(v);
        while (dart_it.next()) |d| {
            const path = pd.ssm_edge_path.value(.{ .edge = pd.samples_surface_mesh.?.phi1(d) });
            for (path.items) |dart| {
                try v_one_ring_boundary.add(.{ .vertex = dart });
            }
        }

        pd.app_ctx.surface_mesh_store.surfaceMeshCellSetUpdated(pd.surface_mesh, v_one_ring_boundary);

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

pub fn init(app_ctx: *AppContext) SurfaceMeshParameterization {
    return .{
        .app_ctx = app_ctx,
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
            info.std_datas.edge_length == null;
        if (disabled) {
            c.ImGui_BeginDisabled(true);
        }
        if (c.ImGui_ButtonEx("Connect samples", c.ImVec2{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0.0 })) {
            pd.connectSamples(info.std_datas.edge_length.?) catch |err| {
                std.debug.print("Error during samples connectivity computation: {}\n", .{err});
            };
        }
        if (disabled) {
            imgui_utils.tooltip(
                \\ Requires:
                \\ - generated samples
                \\ Following data should be available:
                \\ - std edge_length
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
