
uniform mat4 u_view_matrix;
uniform mat4 u_projection_matrix;

in vec4 a_position;
in float a_scaling_field;
in float a_rotation_field;
in vec3 a_edge_ref;

out vec3 frag_position;
out vec3 v_frag_position;
out float scaling_field;
out float rotation_field;
out vec3 edge_ref;

void main()
{

    frag_position = a_position.xyz;
    vec4 view_pos = u_view_matrix * a_position;
    v_frag_position = view_pos.xyz;
    scaling_field = a_scaling_field;
    rotation_field = a_rotation_field;
    edge_ref = normalize(a_edge_ref).xyz;
    gl_Position = u_projection_matrix * view_pos;
}
