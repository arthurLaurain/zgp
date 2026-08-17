uniform mat4 u_model_view_matrix;

in vec4 a_position;
in vec4 a_rgb;

flat out vec4 v_rgb;

void main() {
	gl_Position = u_model_view_matrix * a_position;
  v_rgb = a_rgb;
}
