uniform mat4 u_model_view_matrix;

in vec4 a_position;
in vec4 a_rgb;
in float a_radius;

flat out vec4 v_rgb;
flat out float v_radius;

void main() {
	gl_Position = u_model_view_matrix * a_position;
  v_rgb = a_rgb;
  v_radius = a_radius;
}
