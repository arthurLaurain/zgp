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
const Distance = @import("./SurfaceMeshDistance.zig");

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

pub const FieldData = union(enum) {
    scalar: f32,
    vector: Vec3f,
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
field_edited: ?SurfaceMesh.CellData(.vertex, FieldData) = null,
pending_field_name: [32]u8 = @splat(0),
hovered_cell: ?SurfaceMesh.Cell = null,
hovered_cell_ibo: IBO,
selecting: bool = false,
selected_op_index: i32 = 0,
op: *const fn (f32, FieldOperationParam) f32 = constant,
exponential_slope: f32 = 1,
k_neighborhood: i32 = 1,
max_orientation_from_distance: f32 = 0,
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

fn constant(x: f32, _: FieldOperationParam) f32 {
    return x;
}

fn exponential_decay(x: f32, p: FieldOperationParam) f32 {
    const k = @max(0.0001, p.slope_expo);

    const a = @exp(-k * p.distance);
    const b = @exp(-k * p.radius_expo);

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

pub fn getNeighTriangleID(
    sm: *SurfaceMesh,
    k: u32,
    source: SurfaceMesh.Cell,
) !std.ArrayList(std.ArrayList(SurfaceMesh.Cell)) {
    var rings: std.ArrayList(std.ArrayList(SurfaceMesh.Cell)) = .empty;

    var marker = try SurfaceMesh.DartMarker.init(sm);
    defer marker.deinit();

    var first_ring: std.ArrayList(SurfaceMesh.Cell) = .empty;
    try first_ring.append(sm.allocator, source);
    try rings.append(sm.allocator, first_ring);

    marker.mark(source.dart());

    var level: u32 = 0;
    while (level < k) : (level += 1) {
        const current_ring = rings.items[level];

        var next_ring: std.ArrayList(SurfaceMesh.Cell) = .empty;

        for (current_ring.items) |cell| {
            var current: u32 = cell.dart();
            while (true) {
                if (!marker.isMarked(current)) {
                    next_ring.append(sm.allocator, .{ .vertex = sm.phi2(current) }) catch unreachable;
                    marker.mark(current);
                }
                current = sm.phi1(sm.phi2(current));
                if (current == cell.dart()) break;
            }
        }

        if (next_ring.items.len == 0)
            break;

        try rings.append(sm.allocator, next_ring);
    }

    printArrayList(rings);
    return rings;
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

pub fn gaussianMean(
    rings: std.ArrayList(std.ArrayList(SurfaceMesh.Cell)),
    field: SurfaceMesh.CellData(.vertex, f32),
    sigma: f32,
) f32 {
    var sum: f32 = 0;
    var weight_sum: f32 = 0;

    for (rings.items, 0..) |ring, i| {
        const fi: f32 = @floatFromInt(i);
        const w = std.math.exp(-(fi * fi) / (2.0 * sigma * sigma));

        for (ring.items) |cell| {
            sum += w * field.value(cell);
            weight_sum += w;
        }
    }

    return if (weight_sum == 0) sum else sum / weight_sum;
}

pub fn smoothField(field: SurfaceMesh.CellData(.vertex, f32), sm: *SurfaceMesh, k: u32) !void {
    var cell_it = SurfaceMesh.CellIterator.init(sm, .vertex) catch unreachable;
    defer cell_it.deinit();
    var field_copy = try sm.allocator.alloc(f32, sm.nbCells(.vertex));
    defer sm.allocator.free(field_copy);

    @memset(field_copy, 0);
    var j: usize = 0;
    while (cell_it.next()) |cell| {
        var rings: std.ArrayList(std.ArrayList(SurfaceMesh.Cell)) = getNeighTriangleID(sm, k, cell) catch unreachable;
        field_copy[j] = uniformMean(rings, field);
        for (0..rings.items.len) |i| {
            rings.items[i].deinit(sm.allocator);
        }
        rings.deinit(sm.allocator);
        j = j + 1;
    }

    cell_it.reset();
    j = 0;
    while (cell_it.next()) |cell| {
        field.valuePtrByIndex(sm.cellIndex(cell)).* = field_copy[j];
        j = j + 1;
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
                                const v1 = info.std_datas.vertex_position.?.value(cell);
                                const v2 = info.std_datas.vertex_position.?.value(fg.hovered_cell.?);
                                op_param.distance = vec.norm3f(vec.sub3f(v1, v2));
                                op_param.radius_expo = fgd.point_sphere_shader_parameters.sphere_radius;
                                op_param.slope_expo = fg.exponential_slope;
                            },
                            else => {},
                        }
                        switch (action) {
                            .add => {
                                celldata.valuePtr(cell).*.scalar = celldata.value(cell).scalar + fg.op(fg.value_increment, op_param);
                            },
                            .remove => {
                                celldata.valuePtr(cell).*.scalar = @max(0, celldata.value(cell).scalar - fg.op(fg.value_increment, op_param));
                            },
                        }
                    }
                    sm_store.surfaceMeshDataUpdated(sm, .vertex, FieldData, celldata);
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
            const maybe_data = sm.addData(.vertex, FieldData, data_name);

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
    switch (imgui_utils.surfaceMeshCellDataComboBox(sm, .vertex, FieldData, fg.field_edited)) {
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
            //     fg.app_ctx.requestRedraw();
            // }
        }

        c.ImGui_SeparatorText("Orientation field from distance");

        _ = c.ImGui_SliderFloat("Max orientation", &fg.max_orientation_from_distance, 0, 31.4159);
        if (c.ImGui_Button("Create vector field from from distance gradient")) {
            var cell_it = SurfaceMesh.CellIterator.init(sm, .face) catch unreachable;
            const info = fg.app_ctx.surface_mesh_store.surfaceMeshInfo(sm);

            if (sm.getData(.vertex, f32, "distance")) |distance_data| {

                // var distance_maximum: f32 = distance_data.valueByIndex(0);
                // var distance_minimum: f32 = distance_data.valueByIndex(0);
                // var index_minimum: i32 = 0;
                // var i: i32 = 0;

                // // First loop to seek maximum distance
                // while (cell_it.next()) |cell| {
                //     const current_distance = distance_data.value(cell);
                //     if (distance_maximum < current_distance) {
                //         distance_maximum = current_distance;
                //     } else if (distance_minimum > current_distance) {
                //         index_minimum = i;
                //         distance_minimum = current_distance;
                //     }
                //     i = i + 1;
                // }
                // cell_it.reset();
                // // Second loop to apply normalized orientation to all field points
                // while (cell_it.next()) |cell| {
                //     const current_distance = distance_data.value(cell);
                //     field.valuePtr(cell).*.value = (current_distance / distance_maximum) * fg.max_orientation_from_distance;
                //     field.valuePtr(cell).*.additional_value = @floatFromInt(index_minimum);
                // }

                const data = sm.addData(.face, Vec3f, "gradient_distance_field") catch
                    {
                        std.log.debug("Error creating gradient distance field data\n", .{});
                        unreachable;
                    };

                while (cell_it.next()) |cell| {
                    const p0 = info.std_datas.vertex_position.?.value(.{ .vertex = cell.dart() });
                    const p1 = info.std_datas.vertex_position.?.value(.{ .vertex = sm.phi1(cell.dart()) });
                    const p2 = info.std_datas.vertex_position.?.value(.{ .vertex = sm.phi1(sm.phi1(cell.dart())) });

                    const f0 = distance_data.value(.{ .vertex = cell.dart() });
                    const f1 = distance_data.value(.{ .vertex = sm.phi1(cell.dart()) });
                    const f2 = distance_data.value(.{ .vertex = sm.phi1(sm.phi1(cell.dart())) });

                    const e1 = vec.sub3f(p1, p0);
                    const e2 = vec.sub3f(p2, p0);

                    const cross = vec.cross3f(e1, e2);
                    const two_area = vec.norm3f(cross);

                    const n = vec.divScalar3f(cross, two_area);

                    const u = vec.sub3f(p0, p2);
                    const v = vec.sub3f(p1, p0);

                    const u_perp = vec.cross3f(n, u);
                    const v_perp = vec.cross3f(n, v);

                    const grad = vec.add3f(vec.mulScalar3f(vec.divScalar3f(u_perp, two_area), f1 - f0), vec.mulScalar3f(vec.divScalar3f(v_perp, two_area), f2 - f0));
                    const grad_normalized = vec.normalized3f(grad);
                    data.valuePtr(cell).* = grad_normalized;
                }

                fg.app_ctx.surface_mesh_store.surfaceMeshDataUpdated(sm, .face, Vec3f, data);
            } else {
                std.log.debug("No distance field computed\n", .{});
            }
        }
    }
}
