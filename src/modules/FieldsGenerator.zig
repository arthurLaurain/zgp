const FieldsGenerator = @This();

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const imgui_utils = @import("../ui/imgui.zig");
const AppContext = @import("../main.zig").AppContext;
const Module = @import("Module.zig");
const zgp_log = std.log.scoped(.zgp);
const SurfaceMesh = @import("../models/surface/SurfaceMesh.zig");
const SurfaceMeshStdData = @import("../models/SurfaceMeshStore.zig").SurfaceMeshStdData;
const vec = @import("../geometry/vec.zig");
const Vec3f = vec.Vec3f;

app_ctx: *AppContext,
module: Module = .{
    .name = "Fields generator",
    .supported_models = .{ .surface_mesh = true },
    .vtable = &.{
        // .surfaceMeshCreated = surfaceMeshCreated,
        // .surfaceMeshDestroyed = surfaceMeshDestroyed,
        .sdlEvent = sdlEvent,
        .rightPanel = rightPanel,
    },
},

const FieldData = struct {
    name: [32]u8,
    selected_vertex_set: ?*SurfaceMesh.CellSet = null,
    cell_data: ?*SurfaceMesh.CellData(.vertex, f32) = null,
};

var fields_list: std.ArrayList(FieldData) = .empty;
var field_edited: *FieldData = undefined;
var isEditing = false;
var selected_vertex_set: ?*SurfaceMesh.CellSet = null;
var pending_field: FieldData = .{ .name = @splat(0) };

pub fn init(app_ctx: *AppContext) FieldsGenerator {
    return .{
        .app_ctx = app_ctx,
    };
}

pub fn deinit(fg: *FieldsGenerator) void {
    fields_list.deinit(fg.app_ctx.allocator);
}

/// Part of the Module interface.
/// Manage SDL events.
pub fn sdlEvent(_: *Module, _: *const c.SDL_Event) bool {
    // if (!isEditing) return false;
    // const fg: *FieldsGenerator = @alignCast(@fieldParentPtr("module", m));
    // const sm_store = &fg.app_ctx.surface_mesh_store;
    // const sm = fg.app_ctx.selected_model.surface_mesh;
    // const info = sm_store.surfaceMeshInfo(sm);
    // return switch (event.type) {
    //     c.SDL_EVENT_KEY_DOWN => blk: {
    //         switch (event.key.key) {
    //             c.SDLK_UP => {
    //                 for (field_edited.selected_vertex_set.?.indices.items) |_| {}
    //             },
    //         }
    //     },
    // };

    return true;
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
        _ = c.ImGui_InputText("##Name", &pending_field.name, pending_field.name.len, c.ImGuiInputTextFlags_CharsNoBlank);
        c.ImGui_PopID();

        c.ImGui_Text("Vertex set:");
        c.ImGui_PushID("vertex set");
        switch (imgui_utils.surfaceMeshCellSetComboBox(sm, .vertex, selected_vertex_set)) {
            .unchanged => {},
            .cleared => selected_vertex_set = null,
            .changed => |cell_set| selected_vertex_set = cell_set,
        }
        c.ImGui_PopID();

        if (c.ImGui_ButtonEx("Create", c.ImVec2{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0.0 })) {
            const data_name = std.mem.sliceTo(&pending_field.name, 0);
            _ = sm.addData(.vertex, f32, data_name) catch unreachable;

            //TODO check existing field with same name
            fields_list.append(fg.app_ctx.allocator, pending_field) catch unreachable;
            c.ImGui_CloseCurrentPopup();
        }
        // c.ImGui_SameLine();
        if (c.ImGui_ButtonEx("Close", c.ImVec2{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0.0 })) {
            pending_field.name = @splat(0);
            c.ImGui_CloseCurrentPopup();
        }
    }

    var buffer: [128]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buffer, "Existing Fields {d}", .{fields_list.items.len}) catch "";

    c.ImGui_SeparatorText(text);

    var i: usize = 0;
    while (i < fields_list.items.len) {
        const value: FieldData = fields_list.items[i];
        c.ImGui_Text(&value.name);
        c.ImGui_SameLine();
        const text_button_edit = std.fmt.bufPrintZ(&buffer, "edit{d}", .{i}) catch unreachable;
        c.ImGui_PushID(text_button_edit);
        if (c.ImGui_ButtonEx(if (isEditing) "Stop editing" else "Edit", c.ImVec2{ .x = c.ImGui_GetContentRegionAvail().x / 2, .y = 0.0 })) {
            if (!isEditing) {
                isEditing = true;
                field_edited = &fields_list.items[i];
            } else {
                isEditing = false;
            }
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
