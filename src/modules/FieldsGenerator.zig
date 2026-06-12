const FieldsGenerator = @This();

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const imgui_utils = @import("../ui/imgui.zig");
const AppContext = @import("../main.zig").AppContext;
const Allocator = std.mem.Allocator;
const Module = @import("Module.zig");
const zgp_log = std.log.scoped(.zgp);
const gl = @import("gl");
const SurfaceMesh = @import("../models/surface/SurfaceMesh.zig");
const SurfaceMeshStdData = @import("../models/SurfaceMeshStore.zig").SurfaceMeshStdData;
const vec = @import("../geometry/vec.zig");
const selection = @import("../models/surface/selection.zig");
const Vec3f = vec.Vec3f;
const Vec4f = vec.Vec4f;
const color = @import("../utils/color.zig");
const mat = @import("../geometry/mat.zig");
const Mat4f = mat.Mat4f;
const PointSphere = @import("../rendering/shaders/point_sphere/PointSphere.zig");
const LineCylinder = @import("../rendering/shaders/line_cylinder/LineCylinder.zig");
const TriFlat = @import("../rendering/shaders/tri_flat/TriFlat.zig");
const IBO = @import("../rendering/IBO.zig");

const FieldGeneratorData = struct {
    point_sphere_shader_parameters: PointSphere.Parameters,

    pub fn init() FieldGeneratorData {
        var p = PointSphere.Parameters.init();
        p.sphere_radius = 0.002;
        p.sphere_color = .{ 0.0, 1.0, 0.0, 1.0 };
        return .{
            .point_sphere_shader_parameters = p,
        };
    }

    pub fn deinit(fg: *FieldGeneratorData) void {
        fg.point_sphere_shader_parameters.deinit();
    }
};

const SelectionAction = enum {
    add,
    remove,
};

app_ctx: *AppContext,
module: Module = .{
    .name = "Fields generator",
    .supported_models = .{ .surface_mesh = true },
    .vtable = &.{
        .surfaceMeshCreated = surfaceMeshCreated,
        .surfaceMeshDestroyed = surfaceMeshDestroyed,
        .surfaceMeshStdDataChanged = surfaceMeshStdDataChanged,
        .rightPanel = rightPanel,
        .sdlEvent = sdlEvent,
        .draw = draw,
    },
},

surface_meshes_data: std.AutoHashMapUnmanaged(*SurfaceMesh, FieldGeneratorData) = .empty,
value_increment: f32 = 1,
field_edited: ?SurfaceMesh.CellData(.vertex, f32) = null,
pending_field_name: [32]u8 = @splat(0),
hovered_cell: ?SurfaceMesh.Cell = null,
hovered_cell_ibo: IBO,
selecting: bool = false,
selected_op_index: i32 = 0,
op: *const fn (f32, FieldOperationParam) f32 = sum,
exponential_slope: f32 = 1,

const functions = [_]FunctionEntry{
    .{ .name = "Add", .func = sum },
    .{ .name = "Exponential Decay", .func = exponential_decay },
};

const FunctionEntry = struct {
    name: []const u8,
    func: *const fn (f32, FieldOperationParam) f32,
};

const FieldOperationParam = struct {
    distance: f32 = 0,
    radius_expo: f32 = 0,
    slope_expo: f32 = 0,
};

pub fn init(app_ctx: *AppContext) FieldsGenerator {
    return .{
        .app_ctx = app_ctx,
        .hovered_cell_ibo = .init(),
    };
}

pub fn deinit(fg: *FieldsGenerator) void {
    var data_it = fg.surface_meshes_data.iterator();
    while (data_it.next()) |entry| {
        var d = entry.value_ptr.*;
        d.deinit();
    }
    fg.surface_meshes_data.deinit(fg.app_ctx.allocator);
    fg.hovered_cell_ibo.deinit();
}

fn sum(x: f32, _: FieldOperationParam) f32 {
    return x;
}

fn exponential_decay(x: f32, p: FieldOperationParam) f32 {
    return x * (@exp(-p.slope_expo * p.distance) - @exp(-p.slope_expo * p.radius_expo)) / (1 - @exp(-p.slope_expo * p.radius_expo));
}

/// Part of the Module interface.
/// Create and store a TnBData for the created SurfaceMesh.
pub fn surfaceMeshCreated(m: *Module, surface_mesh: *SurfaceMesh) void {
    const fg: *FieldsGenerator = @alignCast(@fieldParentPtr("module", m));
    fg.surface_meshes_data.put(fg.app_ctx.allocator, surface_mesh, FieldGeneratorData.init()) catch |err| {
        std.debug.print("Failed to store TnBData for new SurfaceMesh: {}\n", .{err});
        return;
    };
}

/// Part of the Module interface.
/// Remove the TnBData associated to the destroyed SurfaceMesh.
pub fn surfaceMeshDestroyed(m: *Module, surface_mesh: *SurfaceMesh) void {
    const fg: *FieldsGenerator = @alignCast(@fieldParentPtr("module", m));
    const p = fg.surface_meshes_data.getPtr(surface_mesh) orelse return;
    p.deinit();
    _ = fg.surface_meshes_data.remove(surface_mesh);
}

/// Part of the Module interface.
/// Update FieldGeneratorData when standard data of SurfaceMesh changes.
pub fn surfaceMeshStdDataChanged(
    m: *Module,
    surface_mesh: *SurfaceMesh,
    std_data: SurfaceMeshStdData,
) void {
    const fg: *FieldsGenerator = @alignCast(@fieldParentPtr("module", m));
    const fgd = fg.surface_meshes_data.getPtr(surface_mesh) orelse return;
    switch (std_data) {
        .vertex_position => |maybe_vertex_position| {
            if (maybe_vertex_position) |vertex_position| {
                const position_vbo = fg.app_ctx.surface_mesh_store.dataVBO(.vertex, Vec3f, vertex_position);
                fgd.point_sphere_shader_parameters.setVertexAttribArray(.position, position_vbo, 0, 0);
            } else {
                fgd.point_sphere_shader_parameters.unsetVertexAttribArray(.position);
            }
        },
        else => return,
    }
}

pub fn draw(m: *Module, view_matrix: Mat4f, projection_matrix: Mat4f) void {
    const fg: *FieldsGenerator = @alignCast(@fieldParentPtr("module", m));
    if (!fg.selecting) return;

    // only draw selection for the currently selected SurfaceMesh & CellSet
    if (fg.app_ctx.selected_model.modelType() != .surface_mesh) return;
    const sm = fg.app_ctx.selected_model.surface_mesh;
    const sdp = fg.surface_meshes_data.getPtr(sm).?;

    // draw currently hovered cell
    if (fg.hovered_cell) |_| {
        const modState = c.SDL_GetModState();
        const action: SelectionAction = if (modState & c.SDL_KMOD_SHIFT != 0) .remove else .add;

        const sphere_radius_backup = sdp.point_sphere_shader_parameters.sphere_radius;
        const sphere_color_backup = sdp.point_sphere_shader_parameters.sphere_color;
        const sphere_color_basis = sdp.point_sphere_shader_parameters.sphere_color;
        const sphere_color: Vec4f = switch (action) {
            .add => .{ sphere_color_basis[0], sphere_color_basis[1], sphere_color_basis[2], 0.5 },
            .remove => blk: {
                const opposite_color = color.perceptualOppositeRGB(.{ sphere_color_basis[0], sphere_color_basis[1], sphere_color_basis[2] });
                break :blk .{ opposite_color[0], opposite_color[1], opposite_color[2], 0.8 };
            },
        };
        sdp.point_sphere_shader_parameters.sphere_color = sphere_color;
        sdp.point_sphere_shader_parameters.model_view_matrix = @bitCast(view_matrix);
        sdp.point_sphere_shader_parameters.projection_matrix = @bitCast(projection_matrix);
        gl.Enable(gl.BLEND);
        gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
        sdp.point_sphere_shader_parameters.draw(fg.hovered_cell_ibo);
        gl.Disable(gl.BLEND);
        sdp.point_sphere_shader_parameters.sphere_radius = sphere_radius_backup;
        sdp.point_sphere_shader_parameters.sphere_color = sphere_color_backup;
    }
}

/// Part of the Module interface.
/// Manage SDL events.
pub fn sdlEvent(m: *Module, event: *const c.SDL_Event) bool {
    const fg: *FieldsGenerator = @alignCast(@fieldParentPtr("module", m));
    const sm_store = &fg.app_ctx.surface_mesh_store;
    const sm = fg.app_ctx.selected_model.surface_mesh;
    const view = &fg.app_ctx.view;
    const fgd: *FieldGeneratorData = fg.surface_meshes_data.getPtr(sm).?;

    return switch (event.type) {
        c.SDL_EVENT_MOUSE_MOTION => blk: {
            if (!fg.selecting) break :blk false;
            if (fg.field_edited) |_| {
                const info_motion = sm_store.surfaceMeshInfo(sm);
                if (info_motion.bvh.initialized) {
                    const ray = view.viewToWorldRay(event.motion.x, event.motion.y);
                    fg.hovered_cell = info_motion.bvh.intersectedVertex(ray); // within sphere selection is always centered on a vertex
                    if (fg.hovered_cell) |cell| {
                        fg.hovered_cell_ibo.fillFromSurfaceMeshCellSlice(sm, &[_]SurfaceMesh.Cell{cell}, fg.app_ctx.allocator) catch |err| {
                            std.debug.print("Failed to fill selecting cell IBO: {}\n", .{err});
                            break :blk false;
                        };
                    } else {
                        fg.hovered_cell_ibo.fillFromIndexSlice(&.{}, &.{});
                    }
                    fg.app_ctx.requestRedraw();
                    break :blk true;
                }
            }
            break :blk false;
        },

        c.SDL_EVENT_KEY_DOWN => blk: {
            switch (event.key.key) {
                c.SDLK_F => {
                    fg.selecting = true;
                    fg.app_ctx.requestRedraw();
                    break :blk true;
                },
                else => {},
            }
            break :blk false;
        },
        c.SDL_EVENT_KEY_UP => blk: {
            switch (event.key.key) {
                c.SDLK_F => {
                    fg.selecting = false;
                    fg.app_ctx.requestRedraw();
                    break :blk true;
                },
                else => {},
            }
            break :blk false;
        },

        c.SDL_EVENT_MOUSE_BUTTON_DOWN => blk: {
            if (!fg.selecting) break :blk false;
            const info_button = sm_store.surfaceMeshInfo(sm);
            if (info_button.std_datas.vertex_position) |vertex_position| {

                // TODO remove unused edges and faces sampling
                var vertices_in_sphere: std.ArrayList(SurfaceMesh.Cell) = .empty;
                defer vertices_in_sphere.deinit(fg.app_ctx.allocator);
                var edges_in_sphere: std.ArrayList(SurfaceMesh.Cell) = .empty;
                defer edges_in_sphere.deinit(fg.app_ctx.allocator);
                var faces_in_sphere: std.ArrayList(SurfaceMesh.Cell) = .empty;
                defer faces_in_sphere.deinit(fg.app_ctx.allocator);
                if (fg.hovered_cell) |cell| {
                    selection.cellsWithinSphereAroundVertex(sm, cell, fgd.point_sphere_shader_parameters.sphere_radius, vertex_position, &vertices_in_sphere, &edges_in_sphere, &faces_in_sphere) catch |err|
                        {
                            std.debug.print("Failed to select cells within sphere: {}\\n", .{err});
                            break :blk false;
                        };
                }

                if (fg.field_edited) |celldata| {
                    const modState = c.SDL_GetModState();

                    const action: SelectionAction = if (modState & c.SDL_KMOD_SHIFT != 0) .remove else .add;

                    var op_param: FieldOperationParam = .{};
                    const info = sm_store.surfaceMeshInfo(sm);
                    for (vertices_in_sphere.items) |cell| {
                        switch (fg.op) {
                            exponential_decay => {
                                const v1 = info.std_datas.vertex_position.?.valueByIndex(sm.cellIndex(cell));
                                const v2 = info.std_datas.vertex_position.?.valueByIndex(sm.cellIndex(fg.hovered_cell.?));
                                op_param.distance = vec.norm3f(vec.sub3f(v1, v2));
                                op_param.radius_expo = fgd.point_sphere_shader_parameters.sphere_radius;
                                op_param.slope_expo = fg.exponential_slope;
                            },
                            else => {},
                        }
                        switch (action) {
                            .add => {
                                celldata.valuePtrByIndex(sm.cellIndex(cell)).* = celldata.valueByIndex(sm.cellIndex(cell)) + fg.op(fg.value_increment, op_param);
                            },
                            .remove => {
                                celldata.valuePtrByIndex(sm.cellIndex(cell)).* = @max(0, celldata.valueByIndex(sm.cellIndex(cell)) - fg.op(fg.value_increment, op_param));
                            },
                        }
                    }
                    sm_store.surfaceMeshDataUpdated(sm, .vertex, f32, celldata);
                    break :blk true;
                }
            }
            break :blk false;
        },
        c.SDL_EVENT_MOUSE_WHEEL => blk: {
            if (!fg.selecting) break :blk false;
            if (fg.field_edited) |_| {
                fgd.point_sphere_shader_parameters.sphere_radius += event.wheel.y * 0.001;
                fg.app_ctx.requestRedraw();
                break :blk true;
            }
            break :blk false;
        },
        else => {
            return false;
        },
    };
}
/// Part of the Module interface.
/// Show a UI panel to control the deformation of the selected SurfaceMesh.
pub fn rightPanel(m: *Module) void {
    const fg: *FieldsGenerator = @alignCast(@fieldParentPtr("module", m));
    const style = c.ImGui_GetStyle();

    assert(fg.app_ctx.selected_model.modelType() == .surface_mesh);
    const sm = fg.app_ctx.selected_model.surface_mesh;

    if (c.ImGui_ButtonEx("Generate new field", c.ImVec2{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0.0 })) {
        c.ImGui_OpenPopup("Generate new field", c.ImGuiPopupFlags_NoReopen);
    }
    if (c.ImGui_BeginPopupModal("Generate new field", 0, c.ImGuiWindowFlags_AlwaysAutoResize)) {
        defer c.ImGui_EndPopup();
        c.ImGui_PushItemWidth(c.ImGui_GetWindowWidth() - style.*.ItemSpacing.x * 2);
        defer c.ImGui_PopItemWidth();

        c.ImGui_Text("Name:");
        c.ImGui_PushID("Name:");
        _ = c.ImGui_InputText("##Name", &fg.pending_field_name, fg.pending_field_name.len, c.ImGuiInputTextFlags_CharsNoBlank);
        c.ImGui_PopID();

        if (c.ImGui_ButtonEx("Create", c.ImVec2{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0.0 })) {
            const data_name = std.mem.sliceTo(&fg.pending_field_name, 0);
            const maybe_data = sm.addData(.vertex, f32, data_name);
            if (maybe_data) |data| {
                fg.field_edited = data;
            } else |err| {
                zgp_log.err("Error adding field data: {}", .{err});
            }
            c.ImGui_CloseCurrentPopup();
        }
        // c.ImGui_SameLine();
        if (c.ImGui_ButtonEx("Close", c.ImVec2{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0.0 })) {
            fg.pending_field_name = @splat(0);
            c.ImGui_CloseCurrentPopup();
        }
    }

    c.ImGui_SeparatorText("Edit fields");
    switch (imgui_utils.surfaceMeshCellDataComboBox(sm, .vertex, f32, fg.field_edited)) {
        .unchanged => {},
        .cleared => {
            fg.field_edited = null;
        },
        .changed => |field| {
            fg.field_edited = field;
        },
    }
    if (fg.field_edited) |_| {
        c.ImGui_SameLine();
        c.ImGui_Text("Celldata");

        if (c.ImGui_BeginCombo(" Function", functions[@intCast(fg.selected_op_index)].name.ptr, 0)) {
            for (functions, 0..) |f, i| {
                const is_selected = (fg.selected_op_index == i);

                if (c.ImGui_SelectableEx(f.name.ptr, is_selected, 0, c.ImVec2{ .x = 0, .y = 0 })) {
                    fg.selected_op_index = @intCast(i);
                    fg.op = functions[@intCast(fg.selected_op_index)].func;
                }
            }
            c.ImGui_EndCombo();
        }

        c.ImGui_SeparatorText("Fields operations parameters");
        _ = c.ImGui_SliderFloat(" Value increment", &fg.value_increment, 0, 10);
        switch (fg.op) {
            exponential_decay => {
                _ = (c.ImGui_SliderFloat("Exponential decay slope", &fg.exponential_slope, 0, 10));
            },
            else => {},
        }
    }
}
