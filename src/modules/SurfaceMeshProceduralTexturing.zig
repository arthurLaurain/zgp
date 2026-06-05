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

const vec = @import("../geometry/vec.zig");
const Vec3f = vec.Vec3f;
const Vec3d = vec.Vec3d;
const mat = @import("../geometry/mat.zig");
const Mat4f = mat.Mat4f;
const VBO = @import("../rendering/VBO.zig");
const SSBO = @import("../rendering/SSBO.zig");

const TnBData = struct {
    surface_mesh: *SurfaceMesh,
    vertex_position: ?SurfaceMesh.CellData(.vertex, Vec3f) = null,
    vertex_normal: ?SurfaceMesh.CellData(.vertex, Vec3f) = null,
    vertex_ref_edge: ?SurfaceMesh.CellData(.vertex, SurfaceMesh.Cell) = null,
    vertex_ref_edge_vec: ?SurfaceMesh.CellData(.vertex, Vec3f) = null,
    procedural_texturing_parameters: ProceduralTexturing.Parameters = undefined,
    exemplar_texture_path: [128]u8 = std.mem.zeroes([128]u8),
    texture_initialized: bool = false,
    position_vbo: VBO = undefined,
    normal_vbo: VBO = undefined,
    num_scalar_field: u8 = 1,
    list_scalar_field_data: [8]?SurfaceMesh.CellData(.vertex, f32) = .{null} ** 8,
    scalar_field_data: ?SurfaceMesh.CellData(.vertex, f32) = null,
    cellset_selection_visualized: ?*SurfaceMesh.CellSet = null,
    draw_texture: bool = true,
    initialized: bool = false,

    pub fn init(tbd: *TnBData, vertex_position: SurfaceMesh.CellData(.vertex, Vec3f)) !void {
        tbd.procedural_texturing_parameters = .init();
        tbd.vertex_position = vertex_position;
        const s = "perlin";
        std.mem.copyBackwards(u8, tbd.exemplar_texture_path[0..s.len], s); // default value to speed up debug
        if (!tbd.initialized) {
            tbd.vertex_ref_edge = try tbd.surface_mesh.addData(.vertex, SurfaceMesh.Cell, "vertex_ref_edge");
            tbd.vertex_ref_edge_vec = try tbd.surface_mesh.addData(.vertex, Vec3f, "vertex_ref_edge_vec");
        }
        tbd.scalar_field_data = tbd.surface_mesh.addData(.vertex, f32, "scalar_field") catch unreachable;
        tbd.initialized = true;
        try tbd.computeVertexRefEdges();
        try tbd.computeVertexRefEdgesVec();
    }

    pub fn deinit(tbd: *TnBData) void {
        if (tbd.initialized) {
            tbd.surface_mesh.removeData(.vertex, SurfaceMesh.Cell, tbd.vertex_ref_edge.?);
            tbd.surface_mesh.removeData(.vertex, Vec3f, tbd.vertex_ref_edge_vec.?);
            tbd.surface_mesh.removeData(.vertex, f32, tbd.scalar_field_data.?);
            tbd.initialized = false;
            tbd.procedural_texturing_parameters.deinit();
        }
    }

    fn computeVertexRefEdges(tbd: *TnBData) !void {
        assert(tbd.initialized);
        var v_it: SurfaceMesh.CellIterator = try .init(tbd.surface_mesh, .vertex);
        defer v_it.deinit();
        while (v_it.next()) |v| {
            tbd.vertex_ref_edge.?.valuePtr(v).* = .{ .edge = v.dart() };
        }
    }

    fn computeVertexRefEdgesVec(tbd: *TnBData) !void {
        assert(tbd.initialized);
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

    for (0..tnb_data.num_scalar_field) |i| {
        if (data == &tnb_data.list_scalar_field_data[i].?.data.data_gen) {
            smpt.mergeFieldCellData();
            smpt.setSurfaceMeshScalarFieldData(sm, tnb_data.scalar_field_data);
            smpt.app_ctx.requestRedraw();
        }
    }

    if (tnb_data.initialized) {
        tnb_data.procedural_texturing_parameters.setVertexAttribArray(.scalar_field, tnb_data.procedural_texturing_parameters.scalar_field_vbo, 0, 0);
        smpt.app_ctx.requestRedraw();
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

fn setSurfaceMeshScalarFieldData(smpt: *SurfaceMeshProceduralTexturing, surface_mesh: *SurfaceMesh, vertex_scalar: ?SurfaceMesh.CellData(.vertex, f32)) void {
    const p = smpt.surface_meshes_data.getPtr(surface_mesh) orelse return;
    if (vertex_scalar) |v| {
        var field_vbo = smpt.app_ctx.surface_mesh_store.dataVBO(.vertex, f32, v);
        field_vbo.fillFrom(f32, v.data);
        p.procedural_texturing_parameters.setVertexAttribArray(.scalar_field, field_vbo, 0, 0);
        p.procedural_texturing_parameters.scalar_field_vbo = field_vbo;
    }
}

fn setSurfaceMeshVectorData(smpt: *SurfaceMeshProceduralTexturing, surface_mesh: *SurfaceMesh, vertex_vector: ?SurfaceMesh.CellData(.vertex, Vec3f)) void {
    const p = smpt.surface_meshes_data.getPtr(surface_mesh) orelse return;
    p.vertex_ref_edge_vec = vertex_vector;
    if (vertex_vector) |v| {
        const vector_vbo = smpt.app_ctx.surface_mesh_store.dataVBO(.vertex, Vec3f, v);
        p.procedural_texturing_parameters.setVertexAttribArray(.vector, vector_vbo, 0, 0);
        p.procedural_texturing_parameters.edge_ref_vbo = vector_vbo;
    } else unreachable;

    smpt.app_ctx.requestRedraw();
}

fn loadShaderSource(io: std.Io, path: []const u8) ![]u8 {
    var buf: [40960]u8 = undefined;
    const file = try std.Io.Dir.readFile(std.Io.Dir.cwd(), io, path, &buf);
    return file;
}

fn mergeFieldCellData(smpt: *SurfaceMeshProceduralTexturing) void {
    const tnb_data = smpt.surface_meshes_data.getPtr(smpt.app_ctx.selected_model.surface_mesh).?;

    for (0..tnb_data.surface_mesh.nbCells(.vertex)) |i| {
        tnb_data.scalar_field_data.?.valuePtrByIndex(@intCast(i)).* = 0;
        for (0..tnb_data.num_scalar_field) |j| { // Necessary to enable multi field visualization
            tnb_data.scalar_field_data.?.valuePtrByIndex(@intCast(i)).* = tnb_data.scalar_field_data.?.valueByIndex(@intCast(i)) + tnb_data.list_scalar_field_data[j].?.valueByIndex(@intCast(i));
        }
    }
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
        tnb_data.procedural_texturing_parameters.setVertexAttribArray(.position, tnb_data.position_vbo, 0, 0);
        smpt.setSurfaceMeshVectorData(sm, .{ .surface_mesh = sm, .data = tnb_data.vertex_ref_edge_vec.?.data });
        tnb_data.procedural_texturing_parameters.vertices_normal_vbo = tnb_data.normal_vbo;
    }
    if (disabled) {
        c.ImGui_EndDisabled();
    }
    if (tnb_data.initialized) {
        if (c.ImGui_Checkbox("Draw texture", &tnb_data.draw_texture))
            smpt.app_ctx.requestRedraw();

        if (c.ImGui_ButtonEx("Reload shader", c.ImVec2{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0.0 })) {
            const vs_source = loadShaderSource(smpt.app_ctx.io, "src/rendering/shaders/procedural_texturing/vs.glsl") catch unreachable;
            defer smpt.app_ctx.allocator.free(vs_source);

            std.log.debug("{any}", .{vs_source});

            const fs_source = loadShaderSource(smpt.app_ctx.io, "src/rendering/shaders/procedural_texturing/fs.glsl") catch unreachable;
            defer smpt.app_ctx.allocator.free(fs_source);

            tnb_data.procedural_texturing_parameters.shader.program.setShader(.vertex, vs_source) catch unreachable;
            tnb_data.procedural_texturing_parameters.shader.program.setShader(.fragment, fs_source) catch unreachable;
            tnb_data.procedural_texturing_parameters.shader.program.linkProgram() catch unreachable;

            gl.UseProgram(tnb_data.procedural_texturing_parameters.shader.program.index);

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
        _ = c.ImGui_InputText("", &tnb_data.exemplar_texture_path[0], @sizeOf([128]u8), 0);
        c.ImGui_PopID();
        if (c.ImGui_Button("Init texture")) {
            tnb_data.texture_initialized = true;

            const nul_index = std.mem.indexOfScalar(u8, tnb_data.exemplar_texture_path[0..], 0).?;
            var path_buffer: [128]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buffer, "src/utils/textures/{s}.png", .{tnb_data.exemplar_texture_path[0..nul_index]}) catch unreachable;

            tnb_data.procedural_texturing_parameters.exemplar_texture.loadFromFile(path) catch {}; // loadFromFile method already print error
            smpt.app_ctx.requestRedraw();
        }
        if (tnb_data.texture_initialized) {
            c.ImGui_Text("Exemplar texture: ");
            const ratio: f32 = @as(f32, @floatFromInt(tnb_data.procedural_texturing_parameters.exemplar_texture.width)) / @as(f32, @floatFromInt(tnb_data.procedural_texturing_parameters.exemplar_texture.height));
            c.ImGui_Image(.{ ._TexID = tnb_data.procedural_texturing_parameters.exemplar_texture.index }, c.ImVec2{ .x = @as(f32, @floatFromInt(200)) * ratio, .y = @as(f32, @floatFromInt(200)) });

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
            c.ImGui_SeparatorText("Scalar Field");
            var buf: [32]u8 = undefined;
            for (0..tnb_data.num_scalar_field) |i| {
                const id = std.fmt.bufPrint(&buf, "Scalar field {d}", .{i}) catch "";
                c.ImGui_PushID(id.ptr);
                switch (imgui_utils.surfaceMeshCellDataComboBox(sm, .vertex, f32, tnb_data.list_scalar_field_data[i])) {
                    .unchanged => {},
                    .cleared => tnb_data.list_scalar_field_data[i] = null,
                    .changed => |field| {
                        tnb_data.list_scalar_field_data[i] = field;
                        smpt.mergeFieldCellData();
                        smpt.setSurfaceMeshScalarFieldData(sm, tnb_data.scalar_field_data);
                        smpt.app_ctx.requestRedraw();
                    },
                }
                c.ImGui_PopID();
            }
            if (tnb_data.num_scalar_field < 8 and c.ImGui_Button("Add scalar field")) {
                tnb_data.num_scalar_field = tnb_data.num_scalar_field + 1;
            }
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
            p.procedural_texturing_parameters.model_view_matrix = @bitCast(view_matrix);
            p.procedural_texturing_parameters.projection_matrix = @bitCast(projection_matrix);
            p.procedural_texturing_parameters.draw(info.triangles_ibo);
        }
    }
}
