const SurfaceMeshProceduralTexturing = @This();

const std = @import("std");
const gl = @import("gl");
const assert = std.debug.assert;

const imgui_utils = @import("../ui/imgui.zig");
// const zgp_log = std.log.scoped(.zgp);

const c = @import("c");

const AppContext = @import("../main.zig").AppContext;
const Module = @import("Module.zig");
const SurfaceMesh = @import("../models/surface/SurfaceMesh.zig");
const SurfaceMeshStdData = @import("../models/SurfaceMeshStore.zig").SurfaceMeshStdData;
const DataGen = @import("../utils/data.zig").DataGen;

const ProceduralTexturing = @import("../rendering/shaders/procedural_texturing/ProceduralTexturing.zig");
const Texture2D = @import("../rendering/Texture2D");
const Shader = @import("../rendering/Shader.zig");

const vec = @import("../geometry/vec.zig");
const Vec2f = vec.Vec2f;
const Vec3f = vec.Vec3f;
const Vec3d = vec.Vec3d;
const mat = @import("../geometry/mat.zig");
const Mat2f = mat.Mat2f;
const Mat3f = mat.Mat3f;
const Mat4f = mat.Mat4f;
const VBO = @import("../rendering/VBO.zig");
const SSBO = @import("../rendering/SSBO.zig");

const TnBData = struct {
    surface_mesh: *SurfaceMesh,
    vertex_position: ?SurfaceMesh.CellData(.vertex, Vec3f) = null,
    vertex_ref_edge: ?SurfaceMesh.CellData(.vertex, SurfaceMesh.Cell) = null,
    vertex_ref_edge_vec: ?SurfaceMesh.CellData(.vertex, Vec3f) = null,
    procedural_texturing_parameters: ProceduralTexturing.Parameters = undefined,
    scaling_fieldData: ?SurfaceMesh.CellData(.vertex, f32) = null,
    rotation_fieldData: ?SurfaceMesh.CellData(.vertex, f32) = null,
    rotation_3D_fieldData: ?SurfaceMesh.CellData(.vertex, Vec3f) = null,
    texture_initialized: bool = false,
    position_vbo: ?VBO = null,
    normal_vbo: ?VBO = null,
    cellset_selection_visualized: ?*SurfaceMesh.CellSet = null,
    draw_texture: bool = true,
    initialized: bool = false,
    exemplar_texture_path: [128]u8 = undefined,

    pub fn init(tbd: *TnBData, vertex_position: SurfaceMesh.CellData(.vertex, Vec3f)) !void {
        tbd.procedural_texturing_parameters = .init();
        tbd.vertex_position = vertex_position;

        const s = "rock";
        @memcpy(tbd.exemplar_texture_path[0..s.len], s);

        if (!tbd.initialized) {
            tbd.vertex_ref_edge = try tbd.surface_mesh.getOrAddData(.vertex, SurfaceMesh.Cell, "vertex_ref_edge");
            tbd.vertex_ref_edge_vec = try tbd.surface_mesh.getOrAddData(.vertex, Vec3f, "vertex_ref_edge_vec");
        }
        try tbd.computeVertexRefEdges();
        try tbd.computeVertexRefEdgesVec();
        tbd.initialized = true;
    }

    pub fn deinit(tbd: *TnBData) void {
        if (tbd.initialized) {
            tbd.surface_mesh.removeData(.vertex, SurfaceMesh.Cell, tbd.vertex_ref_edge.?);
            tbd.surface_mesh.removeData(.vertex, Vec3f, tbd.vertex_ref_edge_vec.?);
            tbd.initialized = false;

            tbd.procedural_texturing_parameters.deinit();
        }
    }

    fn computeVertexRefEdges(tbd: *TnBData) !void {
        var v_it: SurfaceMesh.CellIterator = try .init(tbd.surface_mesh, .vertex);
        defer v_it.deinit();
        while (v_it.next()) |v| {
            tbd.vertex_ref_edge.?.valuePtr(v).* = .{ .edge = v.dart() };
        }
    }

    fn computeVertexRefEdgesVec(tbd: *TnBData) !void {
        var v_it: SurfaceMesh.CellIterator = try .init(tbd.surface_mesh, .vertex);
        defer v_it.deinit();
        while (v_it.next()) |v| {
            tbd.vertex_ref_edge_vec.?.valuePtr(v).* = vec.normalized3f(vec.sub3f(
                tbd.vertex_position.?.value(.{ .vertex = tbd.surface_mesh.phi1(tbd.vertex_ref_edge.?.value(v).dart()) }),
                tbd.vertex_position.?.value(v),
            ));
        }
    }
};

app_ctx: *AppContext,
module: Module = .{
    .name = "Surface Mesh Procedural Texturing",
    .supported_models = .{ .surface_mesh = true },
    .vtable = &.{
        .surfaceMeshCreated = surfaceMeshCreated,
        .surfaceMeshDestroyed = surfaceMeshDestroyed,
        .surfaceMeshStdDataChanged = surfaceMeshStdDataChanged,
        .surfaceMeshDataUpdated = surfaceMeshDataUpdated,
        .surfaceMeshCellSetUpdated = surfaceMeshCellSetUpdated,
        .rightPanel = rightPanel,
        .draw = draw,
    },
},
surface_meshes_data: std.AutoHashMapUnmanaged(*SurfaceMesh, TnBData) = .empty,

pub fn init(app_ctx: *AppContext) SurfaceMeshProceduralTexturing {
    return .{
        .app_ctx = app_ctx,
    };
}

pub fn deinit(smpt: *SurfaceMeshProceduralTexturing) void {
    var data_it = smpt.surface_meshes_data.iterator();
    while (data_it.next()) |entry| {
        var d = entry.value_ptr.*;
        d.deinit();
    }

    smpt.surface_meshes_data.deinit(smpt.app_ctx.allocator);
}

/// Part of the Module interface.
/// Update the SurfaceMeshRendererParameters when a standard data of the SurfaceMesh changes.
pub fn surfaceMeshStdDataChanged(
    m: *Module,
    surface_mesh: *SurfaceMesh,
    std_data: SurfaceMeshStdData,
) void {
    const smpt: *SurfaceMeshProceduralTexturing = @alignCast(@fieldParentPtr("module", m));
    const p = smpt.surface_meshes_data.getPtr(surface_mesh) orelse return;
    switch (std_data) {
        .vertex_position => |maybe_vertex_position| {
            if (maybe_vertex_position) |vertex_position| {

                // if TnB data is not initialized, we save the vertex position VBO in the module to properly assign it at the parameters init
                const position_vbo: VBO = smpt.app_ctx.surface_mesh_store.dataVBO(.vertex, Vec3f, vertex_position);
                if (p.initialized) {
                    p.procedural_texturing_parameters.setVertexAttribArray(.position, position_vbo, 0, 0);
                } else p.position_vbo = position_vbo;
            } else {
                p.procedural_texturing_parameters.unsetVertexAttribArray(.position);
            }
        },
        .vertex_normal => |maybe_vertex_normal| {
            if (maybe_vertex_normal) |vertex_normal| {
                // if TnB data is not initialized, we save the normal position VBO in the module to properly assign it at the parameters init
                const normal_vbo: VBO = smpt.app_ctx.surface_mesh_store.dataVBO(.vertex, Vec3f, vertex_normal);
                if (p.initialized) {
                    p.procedural_texturing_parameters.vertices_normal_vbo = normal_vbo;
                } else p.normal_vbo = normal_vbo;
            }
        },
        else => return, // Ignore other standard data changes
    }
}

/// Part of the Module interface.
/// Create and store a TnBData for the created SurfaceMesh.
pub fn surfaceMeshCreated(m: *Module, surface_mesh: *SurfaceMesh) void {
    const smpt: *SurfaceMeshProceduralTexturing = @alignCast(@fieldParentPtr("module", m));
    smpt.surface_meshes_data.put(smpt.app_ctx.allocator, surface_mesh, .{
        .surface_mesh = surface_mesh,
    }) catch |err| {
        std.debug.print("Failed to store TnBData for new SurfaceMesh: {}\n", .{err});
        return;
    };
}

pub fn surfaceMeshDataUpdated(m: *Module, sm: *SurfaceMesh, celltype: SurfaceMesh.CellType, data: *const DataGen) void {
    const smpt: *SurfaceMeshProceduralTexturing = @alignCast(@fieldParentPtr("module", m));
    const tnb_data = smpt.surface_meshes_data.getPtr(sm) orelse return;
    if (!tnb_data.initialized or celltype != .vertex) return;
    if (tnb_data.rotation_fieldData) |rotation_field| {
        if (rotation_field.gen() == data) {

            // Update 3D rotation field
            smpt.compute3DRotationFieldFromScalarField(sm);
            smpt.app_ctx.requestRedraw();
            return;
        }
    }
}

pub fn compute3DRotationFieldFromScalarField(smpt: SurfaceMeshProceduralTexturing, sm: *SurfaceMesh) void {
    var cell_it = SurfaceMesh.CellIterator.init(sm, .vertex) catch unreachable;
    const tnb_data = smpt.surface_meshes_data.getPtr(sm).?;
    const info = smpt.app_ctx.surface_mesh_store.surfaceMeshInfo(sm);
    while (cell_it.next()) |cell| {
        const edgeRef = tnb_data.vertex_ref_edge_vec.?.value(cell);

        const T = vec.normalized3f(tnb_data.vertex_ref_edge_vec.?.value(cell));
        const t = vec.dot3f(edgeRef, T);
        const B = vec.normalized3f(vec.cross3f(T, info.std_datas.vertex_normal.?.value(cell)));
        const b = vec.dot3f(edgeRef, B);

        const theta = tnb_data.rotation_fieldData.?.value(cell);

        const R: Mat2f = .{ .{ @cos(theta), -@sin(theta) }, .{ @sin(theta), @cos(theta) } };

        var v: Vec2f = .{ t, b };
        v = mat.mulVec2f(R, v);

        const t_rot = v[0];
        const b_rot = v[1];
        const value: Vec3f = vec.add3f(vec.mulScalar3f(T, t_rot), vec.mulScalar3f(B, b_rot));
        tnb_data.rotation_3D_fieldData.?.valuePtr(cell).* = vec.normalized3f(value);
        smpt.app_ctx.surface_mesh_store.surfaceMeshDataUpdated(sm, .vertex, Vec3f, tnb_data.rotation_3D_fieldData.?);
    }
}

pub fn clearCellSetVisualized(smpt: SurfaceMeshProceduralTexturing, sm: *SurfaceMesh) void {
    const tnb_data = smpt.surface_meshes_data.getPtr(sm) orelse return;
    const ssbo_neigh: *SSBO = &tnb_data.procedural_texturing_parameters.ssbo_neigh_selected_vertices;
    ssbo_neigh.memoryAllocationForMapping(@sizeOf(f32));
    gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, ssbo_neigh.index);
    defer gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0);

    const ptr_ssbo = gl.MapBuffer(gl.SHADER_STORAGE_BUFFER, gl.READ_WRITE);
    const array_ssbo: [*]f32 = @ptrCast(@alignCast(ptr_ssbo));

    array_ssbo[0] = 0;
    _ = gl.UnmapBuffer(gl.SHADER_STORAGE_BUFFER);
}

pub fn refreshCellsetVisualized(smpt: SurfaceMeshProceduralTexturing, sm: *SurfaceMesh) void {
    const info = smpt.app_ctx.surface_mesh_store.surfaceMeshInfo(sm);
    const tnb_data = smpt.surface_meshes_data.getPtr(sm) orelse return;
    const vertex_position: SurfaceMesh.CellData(.vertex, Vec3f) = info.std_datas.vertex_position.?;
    var list_neigh_position: std.ArrayList(f32) = .empty;
    defer list_neigh_position.deinit(smpt.app_ctx.allocator);
    for (tnb_data.cellset_selection_visualized.?.cells.items) |value| {
        var current: u32 = value.dart();
        const position_selected_vertex: Vec3f = vertex_position.value(.{ .vertex = current });

        list_neigh_position.append(smpt.app_ctx.allocator, position_selected_vertex[0]) catch unreachable;
        list_neigh_position.append(smpt.app_ctx.allocator, position_selected_vertex[1]) catch unreachable;
        list_neigh_position.append(smpt.app_ctx.allocator, position_selected_vertex[2]) catch unreachable;
        var count: usize = 1;
        while (true) {
            const pos_neigh = vertex_position.value(.{ .vertex = sm.phi_1(current) });
            list_neigh_position.append(smpt.app_ctx.allocator, pos_neigh[0]) catch unreachable;
            list_neigh_position.append(smpt.app_ctx.allocator, pos_neigh[1]) catch unreachable;
            list_neigh_position.append(smpt.app_ctx.allocator, pos_neigh[2]) catch unreachable;
            current = sm.phi2(sm.phi_1(current));
            count = count + 1;
            if (current == value.dart()) break;
        }
        list_neigh_position.insert(smpt.app_ctx.allocator, list_neigh_position.items.len - (count * 3), @floatFromInt(count)) catch unreachable;
    }

    const ssbo_neigh: *SSBO = &tnb_data.procedural_texturing_parameters.ssbo_neigh_selected_vertices;
    ssbo_neigh.memoryAllocationForMapping(@intCast(@sizeOf(f32) * (list_neigh_position.items.len + 1)));

    gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, ssbo_neigh.index);
    defer gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0);

    const ptr_ssbo = gl.MapBuffer(gl.SHADER_STORAGE_BUFFER, gl.READ_WRITE);
    const array_ssbo: [*]f32 = @ptrCast(@alignCast(ptr_ssbo));

    array_ssbo[0] = @floatFromInt(tnb_data.cellset_selection_visualized.?.cells.items.len);
    for (list_neigh_position.items, 0..) |value, i| {
        array_ssbo[i + 1] = value;
    }

    // std.log.debug("Print liste de taille {d}\n", .{list_neigh_position.items.len + 1});
    // for (0..list_neigh_position.items.len + 1) |value| {
    //     if ((value + 1) % 3 == 0 and value > 1) std.log.debug("==========================\n", .{});
    //     std.log.debug("{d}\n", .{array_ssbo[value]});
    // }

    _ = gl.UnmapBuffer(gl.SHADER_STORAGE_BUFFER);
}

/// Part of the Module interface
/// Called everytime a cell is selected by the user
/// TODO fix 1-ring visualization
pub fn surfaceMeshCellSetUpdated(m: *Module, sm: *SurfaceMesh, cell_set: *const SurfaceMesh.CellSet) void {
    const smpt: *SurfaceMeshProceduralTexturing = @alignCast(@fieldParentPtr("module", m));
    const tnb_data = smpt.surface_meshes_data.getPtr(sm) orelse return;
    if (!tnb_data.initialized) return;

    if (cell_set.cell_type != .vertex) {
        return;
    }

    if (tnb_data.cellset_selection_visualized) |cellset_selected| {
        if (cell_set != cellset_selected) return;
        smpt.refreshCellsetVisualized(sm);
    }
}

/// Part of the Module interface.
/// Remove the TnBData associated to the destroyed SurfaceMesh.
pub fn surfaceMeshDestroyed(m: *Module, surface_mesh: *SurfaceMesh) void {
    const smpt: *SurfaceMeshProceduralTexturing = @alignCast(@fieldParentPtr("module", m));
    const tnb_data = smpt.surface_meshes_data.getPtr(surface_mesh) orelse return;
    tnb_data.deinit();
    _ = smpt.surface_meshes_data.remove(surface_mesh);
}

fn setSurfaceMeshVectorData(smpt: *SurfaceMeshProceduralTexturing, surface_mesh: *SurfaceMesh, vertex_vector: ?SurfaceMesh.CellData(.vertex, Vec3f)) void {
    const p = smpt.surface_meshes_data.getPtr(surface_mesh) orelse return;
    if (vertex_vector) |v| {
        p.vertex_ref_edge_vec = vertex_vector;
        const vector_vbo = smpt.app_ctx.surface_mesh_store.dataVBO(.vertex, Vec3f, v);
        p.procedural_texturing_parameters.setVertexAttribArray(.edge_ref, vector_vbo, 0, 0);
        p.procedural_texturing_parameters.edge_ref_vbo = vector_vbo;
        smpt.app_ctx.requestRedraw();
    }
}

fn loadShaderSource(io: std.Io, path: []const u8, buf: []u8) ![:0]u8 {
    const file = try std.Io.Dir.readFile(std.Io.Dir.cwd(), io, path, buf);

    buf[file.len] = 0;

    return buf[0..file.len :0];
}

/// Part of the Module interface.
/// Describe the right-click menu interface.
pub fn rightPanel(m: *Module) void {
    const smpt: *SurfaceMeshProceduralTexturing = @alignCast(@fieldParentPtr("module", m));
    const sm_store = &smpt.app_ctx.surface_mesh_store;

    assert(smpt.app_ctx.selected_model.modelType() == .surface_mesh);
    const sm = smpt.app_ctx.selected_model.surface_mesh;

    const style = c.ImGui_GetStyle();

    c.ImGui_PushItemWidth(c.ImGui_GetWindowWidth() - style.*.ItemSpacing.x * 2);
    defer c.ImGui_PopItemWidth();

    const info = sm_store.surfaceMeshInfo(sm);
    const tnb_data = smpt.surface_meshes_data.getPtr(sm).?;

    const disabled = info.std_datas.vertex_position == null;
    if (disabled) {
        c.ImGui_BeginDisabled(true);
    }
    if (c.ImGui_ButtonEx(if (tnb_data.initialized) "Reinitialize data" else "Initialize data", c.ImVec2{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0.0 })) {
        tnb_data.init(info.std_datas.vertex_position.?) catch |err| {
            std.debug.print("Failed to initialize Procedural Texturing data for SurfaceMesh: {}\n", .{err});
        };

        // We assign VBOs stored in module before parameters init
        tnb_data.procedural_texturing_parameters.vertices_position_vbo = tnb_data.position_vbo;
        tnb_data.procedural_texturing_parameters.setVertexAttribArray(.position, tnb_data.position_vbo.?, 0, 0);
        smpt.setSurfaceMeshVectorData(sm, .{ .surface_mesh = sm, .data = tnb_data.vertex_ref_edge_vec.?.data });
        tnb_data.procedural_texturing_parameters.vertices_normal_vbo = tnb_data.normal_vbo.?;
    }
    if (disabled) {
        c.ImGui_EndDisabled();
    }
    if (tnb_data.initialized) {
        if (c.ImGui_Checkbox("Draw texture", &tnb_data.draw_texture))
            smpt.app_ctx.requestRedraw();

        if (c.ImGui_ButtonEx("Reload shader", c.ImVec2{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0.0 })) {
            var buf_vs_source: [16384]u8 = undefined;
            var buf_fs_source: [16384]u8 = undefined;
            const vs_source = loadShaderSource(smpt.app_ctx.io, "src/rendering/shaders/procedural_texturing/vs.glsl", &buf_vs_source) catch unreachable;
            const fs_source = loadShaderSource(smpt.app_ctx.io, "src/rendering/shaders/procedural_texturing/fs.glsl", &buf_fs_source) catch unreachable;

            tnb_data.procedural_texturing_parameters.shader.reload(vs_source, fs_source) catch unreachable;

            smpt.app_ctx.requestRedraw();
        }

        c.ImGui_Text("Scale length texture coordinates");
        c.ImGui_PushID("Scale length texture coordinates");
        if (c.ImGui_SliderFloat("", &tnb_data.procedural_texturing_parameters.scale_tex_coords, 0, 50))
            smpt.app_ctx.requestRedraw();
        c.ImGui_PopID();

        c.ImGui_Text("Visualize As-Rigid-As-Possible energy");
        c.ImGui_PushID("Visualize As-Rigid-As-Possible energy");
        if (c.ImGui_Checkbox("", &tnb_data.procedural_texturing_parameters.visu_arap_energy)) {
            smpt.app_ctx.requestRedraw();
        }
        c.ImGui_PopID();

        c.ImGui_Text("Compensating distorsions");
        c.ImGui_PushID("Compensatind distorsions");
        if (c.ImGui_Checkbox("", &tnb_data.procedural_texturing_parameters.compense_distorsions)) {
            smpt.app_ctx.requestRedraw();
        }
        c.ImGui_PopID();

        c.ImGui_Text("Exemplar texture path");
        c.ImGui_PushID("Exemplar texture path");
        _ = c.ImGui_InputText("", &tnb_data.exemplar_texture_path, @sizeOf([128]u8), 0);
        c.ImGui_PopID();
        if (c.ImGui_Button("Init texture")) {
            tnb_data.texture_initialized = true;

            var path_buffer: [128]u8 = undefined;
            const path_str = std.mem.sliceTo(&tnb_data.exemplar_texture_path, 0);

            var path = std.fmt.bufPrintSentinel(&path_buffer, "src/utils/textures/{s}.png", .{path_str}, 0) catch unreachable;
            tnb_data.procedural_texturing_parameters.exemplar_texture.loadFromFile(path, smpt.app_ctx.allocator); // loadFromFile method already print error
            path = std.fmt.bufPrintSentinel(&path_buffer, "src/utils/textures/{s}_p.exr", .{path_str}, 0) catch unreachable;
            tnb_data.procedural_texturing_parameters.exemplar_texture_priority.loadFromFile(path, smpt.app_ctx.allocator);
            path = std.fmt.bufPrintSentinel(&path_buffer, "src/utils/textures/{s}_n.png", .{path_str}, 0) catch unreachable;
            tnb_data.procedural_texturing_parameters.exemplar_texture_normal.loadFromFile(path, smpt.app_ctx.allocator);
            path = std.fmt.bufPrintSentinel(&path_buffer, "src/utils/textures/{s}_r.png", .{path_str}, 0) catch unreachable;
            tnb_data.procedural_texturing_parameters.exemplar_texture_roughness.loadFromFile(path, smpt.app_ctx.allocator);

            smpt.app_ctx.requestRedraw();
        }
        if (tnb_data.texture_initialized) {
            c.ImGui_Text("Exemplar texture: ");
            const ratio = @as(f32, @floatFromInt(tnb_data.procedural_texturing_parameters.exemplar_texture.width)) / @as(f32, @floatFromInt(tnb_data.procedural_texturing_parameters.exemplar_texture.height));
            c.ImGui_Image(.{ ._TexID = tnb_data.procedural_texturing_parameters.exemplar_texture.index }, c.ImVec2{ .x = @as(f32, @floatFromInt(200)) * ratio, .y = @as(f32, @floatFromInt(200)) });
            c.ImGui_Text("Exemplar priority texture: ");
            c.ImGui_Image(.{ ._TexID = tnb_data.procedural_texturing_parameters.exemplar_texture_priority.index }, c.ImVec2{ .x = @as(f32, @floatFromInt(200)) * ratio, .y = @as(f32, @floatFromInt(200)) });
            c.ImGui_Text("Exemplar normal texture: ");
            c.ImGui_Image(.{ ._TexID = tnb_data.procedural_texturing_parameters.exemplar_texture_normal.index }, c.ImVec2{ .x = @as(f32, @floatFromInt(200)) * ratio, .y = @as(f32, @floatFromInt(200)) });
            c.ImGui_Text("Exemplar roughness texture: ");
            c.ImGui_Image(.{ ._TexID = tnb_data.procedural_texturing_parameters.exemplar_texture_roughness.index }, c.ImVec2{ .x = @as(f32, @floatFromInt(200)) * ratio, .y = @as(f32, @floatFromInt(200)) });

            c.ImGui_Text("Mixmax micro priority");
            if (c.ImGui_SliderFloat("Mixmax micro priority", &tnb_data.procedural_texturing_parameters.mixmax_micro_priority, 0, 0.5)) {
                smpt.app_ctx.requestRedraw();
            }
            c.ImGui_Text("Visualize cellset");
            c.ImGui_PushID("Visualize cellset");
            switch (imgui_utils.surfaceMeshCellSetComboBox(sm, .vertex, tnb_data.cellset_selection_visualized)) {
                .unchanged => {},
                .cleared => {
                    tnb_data.cellset_selection_visualized = null;
                    smpt.clearCellSetVisualized(sm);
                    smpt.app_ctx.requestRedraw();
                },
                .changed => |cellset| {
                    tnb_data.cellset_selection_visualized = cellset;
                    smpt.refreshCellsetVisualized(sm);
                    smpt.app_ctx.requestRedraw();
                },
            }
            c.ImGui_PopID();
            c.ImGui_SeparatorText("Field");

            if (c.ImGui_Checkbox("Compute tiles transformations per vertex", &tnb_data.procedural_texturing_parameters.tiles_transform_per_vertex)) {
                smpt.app_ctx.requestRedraw();
            }
            c.ImGui_Text("Scalar field:");
            c.ImGui_SameLine();
            c.ImGui_PushID("scaling field");
            switch (imgui_utils.surfaceMeshCellDataComboBox(sm, .vertex, f32, tnb_data.scaling_fieldData)) {
                .unchanged => {},
                .cleared => {
                    tnb_data.scaling_fieldData = null;
                    tnb_data.procedural_texturing_parameters.vertices_scaling_vbo = null;
                    tnb_data.procedural_texturing_parameters.unsetVertexAttribArray(.scaling_field);
                    smpt.app_ctx.requestRedraw();
                },
                .changed => |field| {
                    tnb_data.scaling_fieldData = field;
                    if (tnb_data.scaling_fieldData) |scaling_field| {
                        const field_vbo = smpt.app_ctx.surface_mesh_store.dataVBO(.vertex, f32, scaling_field);
                        tnb_data.procedural_texturing_parameters.setVertexAttribArray(.scaling_field, field_vbo, 0, 0);
                        tnb_data.procedural_texturing_parameters.vertices_scaling_vbo = field_vbo;
                        smpt.app_ctx.requestRedraw();
                    }
                },
            }
            c.ImGui_PopID();

            c.ImGui_Text("Rotation field:");
            c.ImGui_SameLine();
            c.ImGui_PushID("rotation field");
            switch (imgui_utils.surfaceMeshCellDataComboBox(sm, .vertex, f32, tnb_data.rotation_fieldData)) {
                .unchanged => {},
                .cleared => {
                    tnb_data.rotation_fieldData = null;
                    tnb_data.rotation_3D_fieldData = null;
                    tnb_data.procedural_texturing_parameters.vertices_rotation_vbo = null;
                    tnb_data.procedural_texturing_parameters.unsetVertexAttribArray(.rotation_field);
                    smpt.app_ctx.requestRedraw();
                },
                .changed => |field| {
                    tnb_data.rotation_fieldData = field;
                    if (tnb_data.rotation_fieldData) |rotation_field| {
                        const field_vbo = smpt.app_ctx.surface_mesh_store.dataVBO(.vertex, f32, rotation_field);
                        tnb_data.rotation_3D_fieldData = tnb_data.surface_mesh.getOrAddData(.vertex, Vec3f, "3D_rotation_field") catch unreachable;
                        smpt.compute3DRotationFieldFromScalarField(sm);
                        tnb_data.procedural_texturing_parameters.setVertexAttribArray(.rotation_field, field_vbo, 0, 0);
                        tnb_data.procedural_texturing_parameters.vertices_rotation_vbo = field_vbo;
                        smpt.app_ctx.requestRedraw();
                    }
                },
            }
            c.ImGui_PopID();
        }
    }
}

pub fn draw(m: *Module, view_matrix: Mat4f, projection_matrix: Mat4f) void {
    const smpt: *SurfaceMeshProceduralTexturing = @alignCast(@fieldParentPtr("module", m));
    var sm_it = smpt.app_ctx.surface_mesh_store.surface_meshes.iterator();
    while (sm_it.next()) |entry| {
        const sm = entry.value_ptr.*;
        const info = smpt.app_ctx.surface_mesh_store.surfaceMeshInfo(sm);

        const p = smpt.surface_meshes_data.getPtr(sm).?;
        if (p.draw_texture and p.initialized and p.texture_initialized) {
            p.procedural_texturing_parameters.view_matrix = @bitCast(view_matrix);
            p.procedural_texturing_parameters.projection_matrix = @bitCast(projection_matrix);
            p.procedural_texturing_parameters.draw(info.triangles_ibo);
        }
    }
}
