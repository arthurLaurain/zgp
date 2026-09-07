uniform mat4 u_model_view_matrix;
uniform mat4 u_projection_matrix;

in vec4 a_position;
in vec4 a_rgb;

out vec3 v_position;
out vec4 v_rgb;

void main() {
  vec4 pos = u_model_view_matrix * a_position;
  gl_Position = u_projection_matrix * pos;
  v_position = pos.xyz;
  v_rgb = a_rgb;
}
