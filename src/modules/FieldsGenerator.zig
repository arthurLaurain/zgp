const FieldsGenerator = @This();

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const imgui_utils = @import("../ui/imgui.zig");
const AppContext = @import("../AppContext.zig");
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
const Distance = @import("./SurfaceMeshDistance.zig");

const FieldGeneratorData = struct {
    point_sphere_shader_parameters: PointSphere.Parameters,

    pub fn init() FieldGeneratorData {
        var p = PointSphere.Parameters.init();
        p.sphere_radius = 0.002;
        p.sphere_color = .{ 0.0, 0.0, 1.0, 1.0 };
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

app_ctx: *AppContext = undefined,
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
field_edited: ?SurfaceMesh.VertexData(f32) = null,
pending_field_name: [32]u8 = @splat(0),
hovered_cell: ?SurfaceMesh.Vertex = null,
hovered_cell_ibo: IBO = undefined,
selecting: bool = false,
selection_radius: f32 = 0.05,
selected_op_index: i32 = 0,
op: *const fn (f32, FieldOperationParam) f32 = constant,
exponential_slope: f32 = 1,
k_neighborhood: i32 = 1,
const functions = [_]FunctionEntry{
    .{ .name = "Constant", .func = constant },
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

pub fn init(fg: *FieldsGenerator, app_ctx: *AppContext) !void {
    fg.app_ctx = app_ctx;
    fg.hovered_cell_ibo = .init();
    try app_ctx.surface_mesh_store.addListener(&fg.module);
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

fn constant(x: f32, _: FieldOperationParam) f32 {
    return x;
}

fn exponential_decay(x: f32, p: FieldOperationParam) f32 {
    const k = @max(0.0001, p.slope_expo);

    const a = @exp(-k * p.distance);
    const b = @exp(-k * p.radius_expo);

    std.log.debug("Oui\n", .{});
    return x * (a - b) / (1.0 - b);
}

/// Part of the Module interface.
/// Create and store a FieldGeneratorData for the created SurfaceMesh.
pub fn surfaceMeshCreated(m: *Module, surface_mesh: *SurfaceMesh) void {
    const fg: *FieldsGenerator = @alignCast(@fieldParentPtr("module", m));
    fg.surface_meshes_data.put(fg.app_ctx.allocator, surface_mesh, FieldGeneratorData.init()) catch |err| {
        std.debug.print("Failed to store FieldGeneratorData for new SurfaceMesh: {}\n", .{err});
        return;
    };
}

/// Part of the Module interface.
/// Remove the FieldGeneratorData associated to the destroyed SurfaceMesh.
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

pub fn printArrayList(a: std.ArrayList(std.ArrayList(SurfaceMesh.Cell))) void {
    for (0..a.items.len) |i| {
        for (0..a.items[i].items.len) |j| {
            std.log.debug("{d} {d} {d}\n", .{ i, j, a.items[i].items[j].vertex });
        }
    }
}

pub fn uniformMean(
    rings: std.ArrayList(std.ArrayList(SurfaceMesh.Cell)),
    field: SurfaceMesh.CellData(.vertex, f32),
) f32 {
    var sum: f32 = 0;
    var count: f32 = 0;

    for (rings.items) |ring| {
        for (ring.items) |cell| {
            sum += field.value(cell);
            count += 1;
        }
    }

    if (count == 0) return sum;
    return sum / count;
}

pub fn draw(m: *Module, view_matrix: Mat4f, projection_matrix: Mat4f) void {
    const fg: *FieldsGenerator = @alignCast(@fieldParentPtr("module", m));
    if (!fg.selecting) return;

    // only draw selection for the currently selected SurfaceMesh & CellSet
    if (fg.app_ctx.selected_model.modelType() != .surface_mesh) return;
    const sm = fg.app_ctx.selected_model.surface_mesh;
    const fg_data = fg.surface_meshes_data.getPtr(sm).?;

    // draw currently hovered cell
    if (fg.hovered_cell) |_| {
        const modState = c.SDL_GetModState();
        const action: SelectionAction = if (modState & c.SDL_KMOD_SHIFT != 0) .remove else .add;

        const sphere_radius_backup = fg_data.point_sphere_shader_parameters.sphere_radius;
        const sphere_color_backup = fg_data.point_sphere_shader_parameters.sphere_color;
        const sphere_color_basis = fg_data.point_sphere_shader_parameters.sphere_color;
        const sphere_color: Vec4f = switch (action) {
            .add => .{ sphere_color_basis[0], sphere_color_basis[1], sphere_color_basis[2], 0.5 },
            .remove => blk: {
                const opposite_color = color.perceptualOppositeRGB(.{ sphere_color_basis[0], sphere_color_basis[1], sphere_color_basis[2] });
                break :blk .{ opposite_color[0], opposite_color[1], opposite_color[2], 0.8 };
            },
        };
        fg_data.point_sphere_shader_parameters.sphere_color = sphere_color;
        fg_data.point_sphere_shader_parameters.model_view_matrix = @bitCast(view_matrix);
        fg_data.point_sphere_shader_parameters.projection_matrix = @bitCast(projection_matrix);
        gl.Enable(gl.BLEND);
        gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
        fg_data.point_sphere_shader_parameters.draw(fg.hovered_cell_ibo);
        gl.Disable(gl.BLEND);
        fg_data.point_sphere_shader_parameters.sphere_radius = sphere_radius_backup;
        fg_data.point_sphere_shader_parameters.sphere_color = sphere_color_backup;
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
                    if (fg.hovered_cell) |cell_index| {
                        fg.hovered_cell_ibo.fillFromSurfaceMeshCellSlice(sm, &[_]SurfaceMesh.Vertex{.{ .index = cell_index.index }}, fg.app_ctx.allocator) catch |err| {
                            std.debug.print("Failed to fill selecting cell IBO: {}\n", .{err});
                            break :blk false;
                        };
                    } else {
                        fg.hovered_cell_ibo.fillFromIndexSlice(&.{}, &.{});
                    }
                    fg.app_ctx.view.requestRedraw();
                    break :blk true;
                }
            }
            break :blk false;
        },

        c.SDL_EVENT_KEY_DOWN => blk: {
            switch (event.key.key) {
                c.SDLK_F => {
                    fg.selecting = true;
                    fg.app_ctx.view.requestRedraw();
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
                    fg.app_ctx.view.requestRedraw();
                    break :blk true;
                },
                else => {},
            }
            break :blk false;
        },

        c.SDL_EVENT_MOUSE_BUTTON_DOWN => blk: {
            if (!fg.selecting) break :blk false;
            const info = sm_store.surfaceMeshInfo(sm);
            if (info.std_datas.vertex_position) |vertex_position| {
                var sel_ctx: selection.WithinSphereSelectionContext = .{};
                sel_ctx.init(sm, vertex_position, fg.selection_radius) catch |err| {
                    std.debug.print("Failed to initialize selection context: {}\n", .{err});
                    break :blk false;
                };
                defer sel_ctx.deinit();
                const modState = c.SDL_GetModState();
                const action: SelectionAction = if (modState & c.SDL_KMOD_SHIFT != 0) .remove else .add;

                if (fg.hovered_cell) |cell| {
                    sel_ctx.cellsWithinSphereAroundVertex(.{ .index = cell.index }) catch |err|
                        {
                            std.debug.print("Failed to select cells within sphere: {}\\n", .{err});
                            break :blk false;
                        };
                }
                if (fg.field_edited) |*celldata| {
                    var list_vertices_changed: std.ArrayList(u32) = .empty;
                    defer list_vertices_changed.deinit(fg.app_ctx.allocator);
                    var op_param: FieldOperationParam = .{};
                    for (sel_ctx.vertex_buffer.items) |cell| {
                        list_vertices_changed.append(fg.app_ctx.allocator, cell.index) catch unreachable;
                        switch (fg.op) {
                            exponential_decay => {
                                const v1 = vertex_position.value(cell);
                                const v2 = vertex_position.value(fg.hovered_cell.?);
                                op_param.distance = vec.norm(vec.sub(v1, v2));
                                op_param.radius_expo = fgd.point_sphere_shader_parameters.sphere_radius;
                                op_param.slope_expo = fg.exponential_slope;
                            },
                            else => {},
                        }
                        switch (action) {
                            .add => {
                                celldata.valuePtr(cell).* = celldata.value(cell) + fg.op(fg.value_increment, op_param);
                            },
                            .remove => {
                                celldata.valuePtr(cell).* = @max(0, celldata.value(cell) - fg.op(fg.value_increment, op_param));
                            },
                        }
                    }
                    if (sel_ctx.vertex_buffer.items.len > 0) {
                        sm_store.surfaceMeshDataUpdatedWithCells(sm, .vertex, f32, celldata.*, list_vertices_changed);
                    }
                    break :blk true;
                }
            }
            break :blk false;
        },
        c.SDL_EVENT_MOUSE_WHEEL => blk: {
            if (!fg.selecting) break :blk false;
            if (fg.field_edited) |_| {
                fgd.point_sphere_shader_parameters.sphere_radius += event.wheel.y * 0.001;
                fg.app_ctx.view.requestRedraw();
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
        _ = c.ImGui_OpenPopup("Generate new field", c.ImGuiPopupFlags_NoReopen);
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
        if (fg.field_edited) |_| {
            _ = c.ImGui_SliderFloat(" Value increment", &fg.value_increment, 0, 10);
            switch (fg.op) {
                exponential_decay => {
                    _ = (c.ImGui_SliderFloat("Exponential decay slope", &fg.exponential_slope, 0, 100));
                },
                else => {},
            }

            // _ = c.ImGui_SliderInt("K-neighborhood", &fg.k_neighborhood, 1, 5);
            // if (c.ImGui_Button("Smooth Field")) {
            //     smoothField(field, sm, @intCast(fg.k_neighborhood)) catch unreachable;
            //     fg.app_ctx.surface_mesh_store.surfaceMeshDataUpdated(sm, .vertex, f32, field);
            //     fg.app_ctx.view.requestRedraw();
            // }
        }
    }

    c.ImGui_SeparatorText("Vector field preset");
    if (c.ImGui_Button("Create vector field from from distance gradient")) {
        var cell_it = sm.faceIterator();
        const info = fg.app_ctx.surface_mesh_store.surfaceMeshInfo(sm);

        if (sm.getData(.vertex, f32, "distance")) |distance_data| {
            const t = std.Io.Timestamp.now(fg.app_ctx.io, .real);

            var gradient_distance_field_face_data = sm.addData(.face, Vec3f, "gradient_distance_field") catch
                {
                    std.log.debug("Error creating gradient distance field data\n", .{});
                    unreachable;
                };
            defer sm.removeData(gradient_distance_field_face_data);
            while (cell_it.next()) |cell| {
                const p0 = info.std_datas.vertex_position.?.value(sm.vertex(sm.dart(cell)));
                const p1 = info.std_datas.vertex_position.?.value(sm.vertex(sm.phi1(sm.dart(cell))));
                const p2 = info.std_datas.vertex_position.?.value(sm.vertex(sm.phi1(sm.phi1(sm.dart(cell)))));

                const f0 = distance_data.value(sm.vertex(sm.dart(cell)));
                const f1 = distance_data.value(sm.vertex(sm.phi1(sm.dart(cell))));
                const f2 = distance_data.value(sm.vertex(sm.phi1(sm.phi1(sm.dart(cell)))));

                const e1 = vec.sub(p1, p0);
                const e2 = vec.sub(p2, p0);

                const cross = vec.cross(e1, e2);
                const two_area = vec.norm(cross);

                const n = vec.divScalar(cross, two_area);

                const u = vec.sub(p0, p2);
                const v = vec.sub(p1, p0);

                const u_perp = vec.cross(n, u);
                const v_perp = vec.cross(n, v);

                const grad = vec.add(vec.mulScalar(vec.divScalar(u_perp, two_area), f1 - f0), vec.mulScalar(vec.divScalar(v_perp, two_area), f2 - f0));
                const grad_normalized = vec.normalized(grad);
                gradient_distance_field_face_data.valuePtr(cell).* = grad_normalized;
            }

            var cell_it2 = sm.vertexIterator();
            var gradient_distance_field_vertex = sm.addData(.vertex, Vec3f, "vertex_gradient_distance_field") catch
                {
                    std.log.debug("Error creating gradient distance field data\n", .{});
                    unreachable;
                };
            while (cell_it2.next()) |cell| {
                const d_start = sm.dart(cell);
                var d_next = d_start;
                var n: f32 = 0;
                var sum: Vec3f = .{ 0, 0, 0 };
                while (true) {
                    d_next = sm.phi2(d_next);
                    const grad = gradient_distance_field_face_data.value(sm.face(d_next));
                    sum = vec.add(sum, grad);
                    d_next = sm.phi1(d_next);
                    n = n + 1;
                    if (d_next == d_start) break;
                }
                const mean_vectors = vec.divScalar(sum, n);
                gradient_distance_field_vertex.valuePtr(cell).* = mean_vectors;
            }
            fg.app_ctx.surface_mesh_store.surfaceMeshDataUpdated(sm, .vertex, Vec3f, gradient_distance_field_vertex);

            const elapsed: f64 = @floatFromInt(std.Io.Timestamp.untilNow(t, fg.app_ctx.io, .real).nanoseconds);
            zgp_log.info("Gradient distance field computed in : {d:.3}ms", .{elapsed / std.time.ns_per_ms});
        } else {
            std.log.debug("No distance field computed\n", .{});
        }
    }
}
