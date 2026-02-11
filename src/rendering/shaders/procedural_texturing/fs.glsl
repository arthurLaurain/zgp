in vec3 frag_position;

precision highp float;
precision highp int;

uniform vec4 u_ambiant_color;
uniform vec3 u_light_position;
uniform sampler2D u_exemplar_texture;

in vec3 frag_position;
out vec4 f_color;

layout(std430, binding = 1) buffer ssbo_triangles
{
  int info_triangles[];
}

layout(std430, binding = 1) buffer ssbo_vertices
{
  int info_vertices[];
}

vec2 getTexCoord(vec3 P, vec3 A, vec3 B, vec3 C)
{
  vec3 N = normalize(cross(A - B, A - C));
  vec3 T = normalize(A - B);
  vec3 BT = cross(N,T);

  vec3 AP = P - A

  return vec2(dot(AP,T), dot(AP,BT));
  
}

vec3 getBarycentric(vec3 P, vec3 A, vec3 B, vec3 C)
{
    vec3 v0 = B - A;
    vec3 v1 = C - A;
    vec3 v2 = P - A;

    float d00 = dot(v0, v0);
    float d01 = dot(v0, v1);
    float d11 = dot(v1, v1);
    float d20 = dot(v2, v0);
    float d21 = dot(v2, v1);

    float denom = d00 * d11 - d01 * d01;

    float v = (d11 * d20 - d01 * d21) / denom;
    float w = (d00 * d21 - d01 * d20) / denom;
    float u = 1.0 - v - w;

    return vec3(u, v, w);
}

void main() {
  vec3 N = normalize(cross(dFdx(frag_position), dFdy(frag_position)));
  vec3 L = normalize(u_light_position - frag_position);
  float lambert_term = dot(N, L);

  int id_triangle = gl_PrimitiveID;

  vec3 id_vertices = info_triangle[id_triangle];

  vec2 r1 = rand(id_vertices.x);
  vec2 r2 = rand(id_vertices.y);
  vec2 r3 = rand(id_vertices.z);

  vec3 p1 = info_vertices[id_vertices.x];
  vec3 p2 = info_vertices[id_vertices.y];
  vec3 p3 = info_vertices[id_vertices.z];

  vec2 h1 = getTexCoord(frag_position, p1,p2,p3);
  vec2 h2 = getTexCoord(frag_position, p2,p3,p1);
  vec2 h3 = getTexCoord(frag_position, p3,p1,p2);

  vec3 barycentric = getBarycentric(frag_position, p1,p2,p3);
  float w1 = barycentric.x;
  float w2 = barycentric.y;
  float w3 = barycentric.z;

  vec3 c1 = texture(u_exemplar_texture, h1 + r1);
  vec3 c2 = texture(u_exemplar_texture, h2 + r2);
  vec3 c3 = texture(u_exemplar_texture, h3 + r3);

  vec4 albedo = (w1 * c1 + w2 * c2 + w3 * c3) * vec4(lambert_term);
  vec4 result = albedo + vec4(u_ambiant_color.rgb, 0.0);
  f_color = result;

}
