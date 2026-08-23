precision highp float;
precision highp int;

uniform vec4 u_ambiant_color;
uniform vec3 u_light_position;
uniform bool u_dim_backfaces;

// uniform float u_scale;
float u_scale = 80.0;

in vec3 v_position;
in vec2 v_uv;

out vec4 f_color;

void main() {
  // circular
//   float BorW = mod(floor(length(v_uv) * u_scale), 2.0);
  // checkerboard
  vec2 scaled_uv = floor(v_uv * u_scale);
  float BorW = mod(scaled_uv.x + scaled_uv.y, 2.0);

  vec4 result = vec4(vec3(BorW), 1.0);
  result += vec4(u_ambiant_color.rgb, 0.0);
  f_color = result;
  if (u_dim_backfaces && !gl_FrontFacing) {
    f_color *= 0.5;
  }
}
