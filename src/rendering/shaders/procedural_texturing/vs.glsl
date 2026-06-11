
uniform mat4 u_model_view_matrix;
uniform mat4 u_projection_matrix;

in vec4 a_position;
in float a_scaling_field;

out vec3 frag_position;
out vec3 v_frag_position;
out float scaling_field;

void main()
{
    vec4 view_pos = u_model_view_matrix * a_position;
    frag_position = a_position.xyz;
    v_frag_position = view_pos.xyz;
    scaling_field = a_scaling_field;
    gl_Position = u_projection_matrix * view_pos;
}
