
uniform mat4 u_view_matrix;
uniform mat4 u_projection_matrix;

layout(location = 0) in vec4 a_position;
layout(location = 1) in float a_scaling_field;
layout(location = 2) in vec3 a_rotation_field;
layout(location = 3) in vec3 a_edge_ref;

layout(std430, binding = 3) readonly buffer ssbo_vertices_normal
{
  float vertices_normal[];
};

out vec3 frag_position;
out vec3 v_frag_position;
out float scaling_field;
out vec3 rotation_field;
out vec3 edge_ref;
out vec3 vertex_normal;

void main()
{

    int id_triangle = gl_VertexID;
    vertex_normal = vec3(vertices_normal[id_triangle * 3], vertices_normal[id_triangle * 3 +1], vertices_normal[id_triangle * 3 + 2]);

    frag_position = a_position.xyz;
    vec4 view_pos = u_view_matrix *a_position;
    v_frag_position = view_pos.xyz;
    scaling_field = a_scaling_field;
    rotation_field = a_rotation_field;
    edge_ref = normalize(a_edge_ref).xyz;
    gl_Position = u_projection_matrix * view_pos;
}
