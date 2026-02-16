const SurfaceMeshProceduralTexturing = @This();

const std = @import("std");
const gl = @import("gl");
const assert = std.debug.assert;

// const imgui_utils = @import("../utils/imgui.zig");
// const zgp_log = std.log.scoped(.zgp);

const zgp = @import("../main.zig");
const c = zgp.c;

const Module = @import("Module.zig");
const SurfaceMesh = @import("../models/surface/SurfaceMesh.zig");
const SurfaceMeshStdData = @import("../models/surface/SurfaceMeshStdDatas.zig").SurfaceMeshStdData;
const ProceduralTexturing = @import("../rendering/shaders/procedural_texturing/ProceduralTexturing.zig");
const Texture2D = @import("../rendering/Texture2D");

const vec = @import("../geometry/vec.zig");
const Vec3f = vec.Vec3f;
const mat = @import("../geometry/mat.zig");
const Mat4f = mat.Mat4f;
const VBO = @import("../rendering/VBO.zig");
const SSBO = @import("../rendering/SSBO.zig");

const TnBData = struct {
    surface_mesh: *SurfaceMesh,
    vertex_position: ?SurfaceMesh.CellData(.vertex, Vec3f) = null,
    vertex_ref_edge: ?SurfaceMesh.CellData(.vertex, SurfaceMesh.Cell) = null,
    vertex_ref_edge_vec: ?SurfaceMesh.CellData(.vertex, Vec3f) = null,
    procedural_texturing_parameters: ProceduralTexturing.Parameters,

    draw_texture: bool = true,
    initialized: bool = false,

    pub fn init(sm: *SurfaceMesh) TnBData {
        var pt = ProceduralTexturing.Parameters.init();

        //TODO handle error
        pt.exemplar_texture.loadFromFile("/home/arthur_laurain/zgp/src/utils/texture.png") catch unreachable;
        const ssbo_info_triangles = SSBO.init();
        const ssbo_info_vertices = SSBO.init();

        pt.ssbo_info_triangles = ssbo_info_triangles;
        pt.ssbo_info_vertices = ssbo_info_vertices;

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

module: Module = .{
    .name = "Surface Mesh Procedural Texturing",
    .vtable = &.{
        .surfaceMeshCreated = surfaceMeshCreated,
        .surfaceMeshDestroyed = surfaceMeshDestroyed,
        .surfaceMeshStdDataChanged = surfaceMeshStdDataChanged,
        .sdlEvent = sdlEvent,
        .uiPanel = uiPanel,
        .draw = draw,
    },
},

allocator: std.mem.Allocator,
surface_meshes_data: std.AutoHashMap(*SurfaceMesh, TnBData),

pub fn init(allocator: std.mem.Allocator) SurfaceMeshProceduralTexturing {
    return .{
        .allocator = allocator,
        .surface_meshes_data = .init(allocator),
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
                const position_vbo: VBO = zgp.surface_mesh_store.dataVBO(.vertex, Vec3f, vertex_position);
                p.procedural_texturing_parameters.setVertexAttribArray(.position, position_vbo, 0, 0);
                p.procedural_texturing_parameters.vertices_position_vbo = position_vbo;
            } else {
                p.procedural_texturing_parameters.unsetVertexAttribArray(.position);
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

/// Part of the Module interface.
/// Remove the TnBData associated to the destroyed SurfaceMesh.
pub fn surfaceMeshDestroyed(m: *Module, surface_mesh: *SurfaceMesh) void {
    const smpt: *SurfaceMeshProceduralTexturing = @alignCast(@fieldParentPtr("module", m));
    const tnb_data = smpt.surface_meshes_data.getPtr(surface_mesh) orelse return;
    tnb_data.deinit();
    _ = smpt.surface_meshes_data.remove(surface_mesh);
}

/// Part of the Module interface.
/// Manage SDL events.
pub fn sdlEvent(m: *Module, event: *const c.SDL_Event) void {
    const smpt: *SurfaceMeshProceduralTexturing = @alignCast(@fieldParentPtr("module", m));
    _ = smpt;
    // const sm_store = &zgp.surface_mesh_store;
    // const view = &zgp.view;

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
pub fn uiPanel(m: *Module) void {
    const smpt: *SurfaceMeshProceduralTexturing = @alignCast(@fieldParentPtr("module", m));
    const sm_store = &zgp.surface_mesh_store;

    const style = c.ImGui_GetStyle();

    c.ImGui_PushItemWidth(c.ImGui_GetWindowWidth() - style.*.ItemSpacing.x * 2);
    defer c.ImGui_PopItemWidth();

    if (zgp.surface_mesh_store.selected_surface_mesh) |sm| {
        const info = sm_store.surfaceMeshInfo(sm);
        const tnb_data = smpt.surface_meshes_data.getPtr(sm).?;

        const disabled = info.std_data.vertex_position == null;
        if (disabled) {
            c.ImGui_BeginDisabled(true);
        }
        if (c.ImGui_ButtonEx(if (tnb_data.initialized) "Reinitialize data" else "Initialize data", c.ImVec2{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0.0 })) {
            tnb_data.initialize(info.std_data.vertex_position.?) catch |err| {
                std.debug.print("Failed to initialize Procedural Texturing data for SurfaceMesh: {}\n", .{err});
            };
        }
        if (disabled) {
            c.ImGui_EndDisabled();
        }
        if (tnb_data.initialized) {
            if (c.ImGui_Checkbox("Draw texture", &tnb_data.draw_texture))
                zgp.requestRedraw();
            //_ = c.ImGui_Image(tnb_data.procedural_texturing_parameters.exemplar_texture.index, .{ 1920, 960 });

            if (c.ImGui_ButtonEx("Reload shader", c.ImVec2{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0.0 })) {
                gl.DeleteProgram(tnb_data.procedural_texturing_parameters.shader.program.index);

                tnb_data.procedural_texturing_parameters.shader.program.index = gl.CreateProgram();

                const vs_source = loadShaderSource(smpt.allocator, "src/rendering/shaders/procedural_texturing/vs.glsl") catch unreachable;
                defer smpt.allocator.free(vs_source);

                const fs_source = loadShaderSource(smpt.allocator, "src/rendering/shaders/procedural_texturing/fs.glsl") catch unreachable;
                defer smpt.allocator.free(fs_source);

                tnb_data.procedural_texturing_parameters.shader.program.setShader(.vertex, vs_source) catch unreachable;
                tnb_data.procedural_texturing_parameters.shader.program.setShader(.fragment, fs_source) catch unreachable;
                tnb_data.procedural_texturing_parameters.shader.program.linkProgram() catch unreachable;

                zgp.requestRedraw();
            }
            if (c.ImGui_SliderFloat("Scale length texture coordinates", &tnb_data.procedural_texturing_parameters.scale_tex_coords, 0, 1))
                zgp.requestRedraw();
        }
    } else {
        c.ImGui_Text("No SurfaceMesh selected");
    }
}

pub fn draw(m: *Module, view_matrix: Mat4f, projection_matrix: Mat4f) void {
    const smpt: *SurfaceMeshProceduralTexturing = @alignCast(@fieldParentPtr("module", m));
    var sm_it = zgp.surface_mesh_store.surface_meshes.iterator();
    while (sm_it.next()) |entry| {
        const sm = entry.value_ptr.*;
        const info = zgp.surface_mesh_store.surfaceMeshInfo(sm);
        const p = smpt.surface_meshes_data.getPtr(sm).?;
        if (p.draw_texture) {
            p.procedural_texturing_parameters.model_view_matrix = @bitCast(view_matrix);
            p.procedural_texturing_parameters.projection_matrix = @bitCast(projection_matrix);
            p.procedural_texturing_parameters.draw(info.triangles_ibo);
        }
    }
}
