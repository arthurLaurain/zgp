const SurfaceMeshProceduralTexturing = @This();

const std = @import("std");
const gl = @import("gl");
const assert = std.debug.assert;

// const imgui_utils = @import("../ui/imgui.zig");
// const zgp_log = std.log.scoped(.zgp);

const c = @import("../main.zig").c;

const AppContext = @import("../main.zig").AppContext;
const Module = @import("Module.zig");
const SurfaceMesh = @import("../models/surface/SurfaceMesh.zig");
const SurfaceMeshStdData = @import("../models/SurfaceMeshStore.zig").SurfaceMeshStdData;

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
    procedural_texturing_parameters: ProceduralTexturing.Parameters,
    exemplar_texture_path: [128]u8 = std.mem.zeroes([128]u8),
    texture_initialized: bool = false,

    draw_texture: bool = true,
    initialized: bool = false,

    pub fn init(sm: *SurfaceMesh) TnBData {
        var pt = ProceduralTexturing.Parameters.init();

        const ssbo_info_triangles = SSBO.init();
        const ssbo_info_vertices = SSBO.init();
        const ssbo_edge_ref = SSBO.init();
        const ssbo_normal_vertices = SSBO.init();
        const ssbo_distorsion_primitives = SSBO.init();
        const ssbo_neigh_selected_vertices = SSBO.init();
        pt.ssbo_info_triangles = ssbo_info_triangles;
        pt.ssbo_info_vertices = ssbo_info_vertices;
        pt.ssbo_edge_ref = ssbo_edge_ref;
        pt.ssbo_normal_vertices = ssbo_normal_vertices;
        pt.ssbo_distorsion_primitives = ssbo_distorsion_primitives;
        pt.ssbo_neigh_selected_vertices = ssbo_neigh_selected_vertices;

        return .{
            .surface_mesh = sm,
            .procedural_texturing_parameters = pt,
        };
    }

    pub fn deinit(tbd: *TnBData) void {
        if (tbd.initialized) {
            tbd.surface_mesh.removeData(.vertex, tbd.vertex_ref_edge.?.gen());
            tbd.surface_mesh.removeData(.vertex, tbd.vertex_ref_edge_vec.?.gen());
            tbd.initialized = false;
            tbd.procedural_texturing_parameters.deinit();
        }
    }

    pub fn initialize(tbd: *TnBData, vertex_position: SurfaceMesh.CellData(.vertex, Vec3f)) !void {
        tbd.vertex_position = vertex_position;
        std.mem.copyBackwards(u8, tbd.exemplar_texture_path[0.."brick".len], "brick"); // default value to speed up debug
        if (!tbd.initialized) {
            tbd.vertex_ref_edge = try tbd.surface_mesh.addData(.vertex, SurfaceMesh.Cell, "vertex_ref_edge");
            tbd.vertex_ref_edge_vec = try tbd.surface_mesh.addData(.vertex, Vec3f, "vertex_ref_edge_vec");
        }

        tbd.initialized = true;

        try tbd.computeVertexRefEdges();
        try tbd.computeVertexRefEdgesVec();
    }

    fn computeVertexRefEdges(tbd: *TnBData) !void {
        assert(tbd.initialized);
        var v_it = try SurfaceMesh.CellIterator(.vertex).init(tbd.surface_mesh);
        defer v_it.deinit();
        while (v_it.next()) |v| {
            tbd.vertex_ref_edge.?.valuePtr(v).* = .{ .edge = v.dart() };
        }
    }

    fn computeVertexRefEdgesVec(tbd: *TnBData) !void {
        assert(tbd.initialized);
        var v_it = try SurfaceMesh.CellIterator(.vertex).init(tbd.surface_mesh);
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
        .surfaceMeshCellSetUpdated = surfaceMeshCellSetUpdated,
        .sdlEvent = sdlEvent,
        .rightPanel = rightPanel,
        .draw = draw,
    },
},
surface_meshes_data: std.AutoHashMap(*SurfaceMesh, TnBData),

pub fn init(app_ctx: *AppContext) SurfaceMeshProceduralTexturing {
    return .{
        .app_ctx = app_ctx,
        .surface_meshes_data = .init(app_ctx.allocator),
    };
}

pub fn deinit(smpt: *SurfaceMeshProceduralTexturing) void {
    var data_it = smpt.surface_meshes_data.iterator();
    while (data_it.next()) |entry| {
        var d = entry.value_ptr.*;
        d.deinit();
    }
    smpt.surface_meshes_data.deinit();
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
                const position_vbo: VBO = smpt.app_ctx.surface_mesh_store.dataVBO(.vertex, Vec3f, vertex_position);
                p.procedural_texturing_parameters.setVertexAttribArray(.position, position_vbo, 0, 0);
                p.procedural_texturing_parameters.vertices_position_vbo = position_vbo;
            } else {
                p.procedural_texturing_parameters.unsetVertexAttribArray(.position);
            }
        },
        .vertex_normal => |maybe_vertex_normal| {
            if (maybe_vertex_normal) |vertex_normal| {
                const normal_vbo: VBO = smpt.app_ctx.surface_mesh_store.dataVBO(.vertex, Vec3f, vertex_normal);
                p.procedural_texturing_parameters.vertices_normal_vbo = normal_vbo;
            }
        },
        else => return, // Ignore other standard data changes
    }
}

/// Part of the Module interface.
/// Create and store a TnBData for the created SurfaceMesh.
pub fn surfaceMeshCreated(m: *Module, surface_mesh: *SurfaceMesh) void {
    const smpt: *SurfaceMeshProceduralTexturing = @alignCast(@fieldParentPtr("module", m));
    smpt.surface_meshes_data.put(surface_mesh, .init(surface_mesh)) catch |err| {
        std.debug.print("Failed to store TnBData for new SurfaceMesh: {}\n", .{err});
        return;
    };
}

/// Part of the Module interface
/// Called everytime a cell is selected by the user
pub fn surfaceMeshCellSetUpdated(m: *Module, sm: *SurfaceMesh, _: SurfaceMesh.CellType) void {
    const smpt: *SurfaceMeshProceduralTexturing = @alignCast(@fieldParentPtr("module", m));
    const tnb_data = smpt.surface_meshes_data.getPtr(sm) orelse return;
    if (!tnb_data.initialized) return;

    const info = smpt.app_ctx.surface_mesh_store.surfaceMeshInfo(sm);
    const vertex_position: SurfaceMesh.CellData(.vertex, Vec3f) = info.std_datas.vertex_position.?;
    var list_neigh_position: std.ArrayList(f64) = .empty;
    defer list_neigh_position.deinit(smpt.app_ctx.allocator);
    for (info.vertex_set.cells.items) |value| {
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
    ssbo_neigh.memoryAllocationForMapping(@intCast(@sizeOf(f64) * (list_neigh_position.items.len + 1)));

    gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, ssbo_neigh.index);
    defer gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0);

    const ptr_ssbo = gl.MapBuffer(gl.SHADER_STORAGE_BUFFER, gl.READ_WRITE);
    const array_ssbo: [*]f64 = @ptrCast(@alignCast(ptr_ssbo));

    array_ssbo[0] = @floatFromInt(info.vertex_set.cells.items.len);
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
    p.vertex_ref_edge_vec = vertex_vector;
    if (vertex_vector) |v| {
        const vector_vbo = smpt.app_ctx.surface_mesh_store.dataVBO(.vertex, Vec3f, v);
        p.procedural_texturing_parameters.setVertexAttribArray(.vector, vector_vbo, 0, 0);
        p.procedural_texturing_parameters.edge_ref_vbo = vector_vbo;
    } else unreachable;

    smpt.app_ctx.requestRedraw();
}

/// Part of the Module interface.
/// Manage SDL events.
pub fn sdlEvent(m: *Module, event: *const c.SDL_Event) void {
    const smpt: *SurfaceMeshProceduralTexturing = @alignCast(@fieldParentPtr("module", m));
    // const sm_store = &zgp.surface_mesh_store;
    // const view = &zgp.view;

    assert(smpt.app_ctx.selected_model.modelType() == .surface_mesh);
    const sm = smpt.app_ctx.selected_model.surface_mesh;

    _ = sm;

    switch (event.type) {
        c.SDL_EVENT_KEY_DOWN => {
            switch (event.key.key) {
                else => {},
            }
        },
        c.SDL_EVENT_KEY_UP => {
            switch (event.key.key) {
                else => {},
            }
        },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            switch (event.button.button) {
                else => {},
            }
        },
        else => {},
    }
}

fn loadShaderSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    return try file.readToEndAlloc(allocator, 1024 * 1024);
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
        tnb_data.initialize(info.std_datas.vertex_position.?) catch |err| {
            std.debug.print("Failed to initialize Procedural Texturing data for SurfaceMesh: {}\n", .{err});
        };
        smpt.setSurfaceMeshVectorData(sm, .{ .surface_mesh = sm, .data = tnb_data.vertex_ref_edge_vec.?.data });
    }
    if (disabled) {
        c.ImGui_EndDisabled();
    }
    if (tnb_data.initialized) {
        if (c.ImGui_Checkbox("Draw texture", &tnb_data.draw_texture))
            smpt.app_ctx.requestRedraw();

        if (c.ImGui_ButtonEx("Reload shader", c.ImVec2{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0.0 })) {
            const vs_source = loadShaderSource(smpt.app_ctx.allocator, "src/rendering/shaders/procedural_texturing/vs.glsl") catch unreachable;
            defer smpt.app_ctx.allocator.free(vs_source);

            const fs_source = loadShaderSource(smpt.app_ctx.allocator, "src/rendering/shaders/procedural_texturing/fs.glsl") catch unreachable;
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

        c.ImGui_Text("Scale distorsions");
        c.ImGui_PushID("Scale distorsions");
        if (c.ImGui_SliderFloat("", &tnb_data.procedural_texturing_parameters.scale_distorsion, 0, 1))
            smpt.app_ctx.requestRedraw();
        c.ImGui_PopID();

        c.ImGui_Text("Visualize area distorsions");
        c.ImGui_PushID("Visualize area distorsions");
        if (c.ImGui_Checkbox("", &tnb_data.procedural_texturing_parameters.visu_area_distorsion)) {
            tnb_data.procedural_texturing_parameters.visu_angle_distorsion = false;
            tnb_data.procedural_texturing_parameters.visu_arap_energy = false;
            smpt.app_ctx.requestRedraw();
        }
        c.ImGui_PopID();

        c.ImGui_Text("Visualize angle distorsions");
        c.ImGui_PushID("Visualize angle distorsions");
        if (c.ImGui_Checkbox("", &tnb_data.procedural_texturing_parameters.visu_angle_distorsion)) {
            tnb_data.procedural_texturing_parameters.visu_area_distorsion = false;
            tnb_data.procedural_texturing_parameters.visu_arap_energy = false;
            smpt.app_ctx.requestRedraw();
        }
        c.ImGui_PopID();

        c.ImGui_Text("Visualize As-Rigid-As-Possible energy");
        c.ImGui_PushID("Visualize As-Rigid-As-Possible energy");
        if (c.ImGui_Checkbox("", &tnb_data.procedural_texturing_parameters.visu_arap_energy)) {
            tnb_data.procedural_texturing_parameters.visu_area_distorsion = false;
            tnb_data.procedural_texturing_parameters.visu_angle_distorsion = false;
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
