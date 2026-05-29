const FieldsGenerator = @This();

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const imgui_utils = @import("../ui/imgui.zig");
const AppContext = @import("../main.zig").AppContext;
const Allocator = std.mem.Allocator;
const Module = @import("Module.zig");
const zgp_log = std.log.scoped(.zgp);
const SurfaceMesh = @import("../models/surface/SurfaceMesh.zig");
const SurfaceMeshStdData = @import("../models/SurfaceMeshStore.zig").SurfaceMeshStdData;
const vec = @import("../geometry/vec.zig");
const Vec3f = vec.Vec3f;

const FieldData = struct {
    name: [32]u8,
    selected_vertex_set: ?*SurfaceMesh.CellSet = null,
    cell_data: ?SurfaceMesh.CellData(.vertex, f32) = null,
    value: f32 = 0,
};

const FieldGeneratorData = struct {
    fields_list: std.ArrayList(FieldData) = .empty,
    selected_vertex_set: ?*SurfaceMesh.CellSet = null,
    pending_field: FieldData = .{ .name = @splat(0) },

    pub fn deinit(fgd: *FieldGeneratorData, allocator: Allocator) void {
        fgd.fields_list.deinit(allocator);
    }
};

app_ctx: *AppContext,
module: Module = .{
    .name = "Fields generator",
    .supported_models = .{ .surface_mesh = true },
    .vtable = &.{
        .surfaceMeshCreated = surfaceMeshCreated,
        .surfaceMeshDestroyed = surfaceMeshDestroyed,
        .surfaceMeshCellSetUpdated = surfaceMeshCellSetUpdated,
        .rightPanel = rightPanel,
    },
},

surface_meshes_data: std.AutoHashMapUnmanaged(*SurfaceMesh, FieldGeneratorData) = .empty,

pub fn init(app_ctx: *AppContext) FieldsGenerator {
    return .{
        .app_ctx = app_ctx,
    };
}

pub fn deinit(fg: *FieldsGenerator) void {
    var data_it = fg.surface_meshes_data.iterator();
    while (data_it.next()) |entry| {
        var d = entry.value_ptr.*;
        d.deinit(fg.app_ctx.allocator);
    }
    fg.surface_meshes_data.deinit(fg.app_ctx.allocator);
}

/// Part of the Module interface.
/// Create and store a TnBData for the created SurfaceMesh.
pub fn surfaceMeshCreated(m: *Module, surface_mesh: *SurfaceMesh) void {
    const fg: *FieldsGenerator = @alignCast(@fieldParentPtr("module", m));
    fg.surface_meshes_data.put(fg.app_ctx.allocator, surface_mesh, .{}) catch |err| {
        std.debug.print("Failed to store TnBData for new SurfaceMesh: {}\n", .{err});
        return;
    };
}

/// Part of the Module interface.
/// Remove the TnBData associated to the destroyed SurfaceMesh.
pub fn surfaceMeshDestroyed(m: *Module, surface_mesh: *SurfaceMesh) void {
    const fg: *FieldsGenerator = @alignCast(@fieldParentPtr("module", m));
    const p = fg.surface_meshes_data.getPtr(surface_mesh) orelse return;
    p.deinit(fg.app_ctx.allocator);
    _ = fg.surface_meshes_data.remove(surface_mesh);
}

pub fn surfaceMeshCellSetUpdated(m: *Module, sm: *SurfaceMesh, cell_set: *const SurfaceMesh.CellSet) void {
    const fg: *FieldsGenerator = @alignCast(@fieldParentPtr("module", m));
    const p = fg.surface_meshes_data.getPtr(sm) orelse return;
    for (p.fields_list.items) |field| {
        if (field.selected_vertex_set.? == cell_set) {
            field.cell_data.?.data.fill(0);
            for (field.selected_vertex_set.?.indices.items) |indice| {
                field.cell_data.?.valuePtrByIndex(indice).* = field.value;
            }
            fg.app_ctx.surface_mesh_store.surfaceMeshDataUpdated(sm, .vertex, f32, field.cell_data.?);
        }
    }
    fg.app_ctx.requestRedraw();
}

/// Part of the Module interface.
/// Show a UI panel to control the deformation of the selected SurfaceMesh.
pub fn rightPanel(m: *Module) void {
    const fg: *FieldsGenerator = @alignCast(@fieldParentPtr("module", m));
    const style = c.ImGui_GetStyle();

    assert(fg.app_ctx.selected_model.modelType() == .surface_mesh);
    const sm = fg.app_ctx.selected_model.surface_mesh;
    const p = fg.surface_meshes_data.getPtr(sm) orelse return;

    if (c.ImGui_ButtonEx("Generate new field", c.ImVec2{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0.0 })) {
        c.ImGui_OpenPopup("Generate new field", c.ImGuiPopupFlags_NoReopen);
    }
    if (c.ImGui_BeginPopupModal("Generate new field", 0, c.ImGuiWindowFlags_AlwaysAutoResize)) {
        defer c.ImGui_EndPopup();
        c.ImGui_PushItemWidth(c.ImGui_GetWindowWidth() - style.*.ItemSpacing.x * 2);
        defer c.ImGui_PopItemWidth();

        c.ImGui_Text("Name:");
        c.ImGui_PushID("Name:");
        _ = c.ImGui_InputText("##Name", &p.pending_field.name, p.pending_field.name.len, c.ImGuiInputTextFlags_CharsNoBlank);
        c.ImGui_PopID();

        c.ImGui_Text("Vertex set:");
        c.ImGui_PushID("vertex set");
        switch (imgui_utils.surfaceMeshCellSetComboBox(sm, .vertex, p.selected_vertex_set)) {
            .unchanged => {},
            .cleared => p.selected_vertex_set = null,
            .changed => |cell_set| p.selected_vertex_set = cell_set,
        }
        c.ImGui_PopID();

        if (c.ImGui_ButtonEx("Create", c.ImVec2{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0.0 })) {
            const data_name = std.mem.sliceTo(&p.pending_field.name, 0);
            const maybe_data = sm.addData(.vertex, f32, data_name);
            if (maybe_data) |data| {
                p.pending_field.cell_data = data;
            } else |err| {
                zgp_log.err("Error adding field data: {}", .{err});
            }

            p.pending_field.selected_vertex_set = p.selected_vertex_set;

            //TODO check existing field with same name
            p.fields_list.append(fg.app_ctx.allocator, p.pending_field) catch unreachable;
            c.ImGui_CloseCurrentPopup();
        }
        // c.ImGui_SameLine();
        if (c.ImGui_ButtonEx("Close", c.ImVec2{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0.0 })) {
            p.pending_field.name = @splat(0);
            c.ImGui_CloseCurrentPopup();
        }
    }

    var buffer: [128]u8 = undefined;
    var text = std.fmt.bufPrintZ(&buffer, "Existing Fields {d}", .{p.fields_list.items.len}) catch "";

    c.ImGui_SeparatorText(text);

    var i: usize = 0;
    while (i < p.fields_list.items.len) {
        const value: FieldData = p.fields_list.items[i];
        c.ImGui_Text(&value.name);
        c.ImGui_SameLine();
        c.ImGui_Text("Field value");
        text = std.fmt.bufPrintZ(&buffer, "Field value {d}", .{i}) catch "";
        c.ImGui_PushID(text);
        if (c.ImGui_SliderFloat("", &p.fields_list.items[i].value, 0, 50)) {
            for (p.fields_list.items[i].selected_vertex_set.?.indices.items) |indice| {
                p.fields_list.items[i].cell_data.?.valuePtrByIndex(indice).* = p.fields_list.items[i].value;
            }
            fg.app_ctx.surface_mesh_store.surfaceMeshDataUpdated(sm, .vertex, f32, p.fields_list.items[i].cell_data.?);
        }
        c.ImGui_PopID();
        // TODO Enable fields removal
        // c.ImGui_SameLine();
        // const text_button_close = std.fmt.bufPrintZ(&buffer, "del{d}", .{i}) catch unreachable;
        // c.ImGui_PushID(text_button_close);
        // if (c.ImGui_ButtonEx("Delete", c.ImVec2{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0.0 })) {
        //     fg.freeFieldData(&value);
        //     sm.removeData(.vertex, Field.datatype, value.cell_data_handle);
        //     _ = fields_list.orderedRemove(i);
        //     c.ImGui_PopID();
        //     continue;
        // }
        // c.ImGui_PopID();

        i = i + 1;
    }
}
