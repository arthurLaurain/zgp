in vec3 frag_position;

precision highp float;
precision highp int;

uniform vec4 u_ambiant_color;
uniform vec3 u_light_position;

out vec4 f_color;

void main() {
  vec3 N = normalize(cross(dFdx(frag_position), dFdy(frag_position)));
  vec3 L = normalize(u_light_position - frag_position);
  float lambert_term = dot(N, L);
  vec4 albedo = vec4(0.8,0.5,0.3,1.) * lambert_term;
  vec4 result = albedo + vec4(u_ambiant_color.rgb, 0.0);
  f_color = result;

}
