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
        .rightPanel = rightPanel,
    },
},

const FieldDataType = union(enum) {
    f32: f32,
    Vec3f: Vec3f,
};
const FieldDataTypeTag = std.meta.Tag(FieldDataType);

const Field = struct {
    var name: [32]u8 = @splat(0);
    var datatype: FieldDataTypeTag = .f32;
};

const FieldEntry = struct {
    name: []u8,
    datatype: []u8,
};

var fields_list: std.ArrayList(FieldEntry) = .empty;

pub fn init(app_ctx: *AppContext) FieldsGenerator {
    return .{
        .app_ctx = app_ctx,
    };
}

pub fn deinit(fg: *FieldsGenerator) void {
    for (fields_list.items) |value| {
        fg.app_ctx.allocator.free(value.name);
        fg.app_ctx.allocator.free(value.datatype);
    }
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
        _ = c.ImGui_InputText("##Name", &Field.name, Field.name.len, c.ImGuiInputTextFlags_CharsNoBlank);

        if (c.ImGui_RadioButton("Scalar", std.mem.eql(u8, @tagName(Field.datatype), "f32"))) {
            Field.datatype = .f32;
        }

        c.ImGui_SameLine();

        if (c.ImGui_RadioButton("Vector", std.mem.eql(u8, @tagName(Field.datatype), "Vec3f"))) {
            Field.datatype = .Vec3f;
        }
        c.ImGui_PopID();

        if (c.ImGui_ButtonEx("Create", c.ImVec2{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0.0 })) {
            switch (Field.datatype) {
                inline else => |data_type| {
                    const data_name = std.mem.sliceTo(&Field.name, 0);
                    _ = sm.addData(.vertex, @FieldType(FieldDataType, @tagName(data_type)), data_name) catch |err|
                        {
                            zgp_log.err("Error adding {s} {s} data: {}", .{ data_name, @tagName(data_type), err });
                        };

                    const datatype_label: []const u8 = switch (Field.datatype) {
                        .f32 => "Scalar field",
                        .Vec3f => "Vector field",
                    };
                    const name = fg.app_ctx.allocator.dupe(u8, data_name) catch unreachable;
                    const datatype = fg.app_ctx.allocator.dupe(u8, datatype_label) catch unreachable;

                    const pending_field = FieldEntry{
                        .name = name,
                        .datatype = datatype,
                    };
                    //TODO check existing field with same name
                    fields_list.append(fg.app_ctx.allocator, pending_field) catch unreachable;
                    Field.name = @splat(0);
                    c.ImGui_CloseCurrentPopup();
                },
            }
        }
        // c.ImGui_SameLine();
        if (c.ImGui_ButtonEx("Close", c.ImVec2{ .x = c.ImGui_GetContentRegionAvail().x, .y = 0.0 })) {
            Field.name = @splat(0);
            c.ImGui_CloseCurrentPopup();
        }
    }

    var buffer: [128]u8 = undefined;
    var text = std.fmt.bufPrintZ(&buffer, "Existing Fields {d}", .{fields_list.items.len}) catch "";
    c.ImGui_Text(text);

    for (fields_list.items) |value| {
        text = std.fmt.bufPrintZ(&buffer, "{s} {s}", .{ value.name, value.datatype }) catch "Error";
        c.ImGui_Text(text);
    }
}
