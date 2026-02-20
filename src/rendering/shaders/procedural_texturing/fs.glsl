uniform vec4 u_ambiant_color;
uniform vec3 u_light_position;
uniform sampler2D u_exemplar_texture;
uniform mat4 u_model_view_matrix;
uniform float u_scale_tex_coords;

in vec3 frag_position;
out vec4 f_color;

// using raw buffer to avoid vec3/ivec3 in SSBO because they need to be aligned to a 16 byte boundary while IBO/VBO uses 12 floats vec3
layout(std430, binding = 0) readonly buffer ssbo_triangles
{
  int info_triangles[];
};

layout(std430, binding = 1) readonly buffer ssbo_vertices
{
  float info_vertices[];
};

layout(std430, binding = 2) readonly buffer ssbo_edge_ref
{
  float edge_ref_ssbo[];
};

layout(std430, binding = 3) readonly buffer ssbo_vertices_normal
{
  float vertices_normal[];
};

mat2 rotate(float theta)
{
    float c = cos(theta);
    float s = sin(theta);
    return mat2(
        c, -s,
        s,  c
    );
}

vec2 getTexCoord(vec3 P, vec3 A, vec3 B, vec3 C)
{
  vec3 N = normalize(cross(B - A, C - A));
  vec3 T = normalize(B - A);
  vec3 BT = cross(N,T);

  vec3 AP = P - A;

  return vec2(dot(AP,T), dot(AP,BT));
  
}

vec2 getTexCoordFromVertexPlane(vec3 P, vec3 A, vec3 N)
{
    vec3 projPoint = P - dot(P - A, N) * N;

    vec3 up = abs(N.z) > 0.99 ? vec3(0,1,0) : vec3(0,0,1);
    vec3 T = normalize(cross(N, up));
    vec3 BT = cross(N, T);

    vec3 AP = projPoint - A;
    return vec2(dot(AP, T), dot(AP, BT));
}

vec2 hash12(int n){
    float x = fract(sin(float(n)*12.9898)*43758.5453);
    float y = fract(sin(float(n)*78.233 )*43758.5453);
    return vec2(x,y);
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
    denom = max(denom, 1e-8);

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

  ivec3 id_vertices = ivec3(info_triangles[3*id_triangle], info_triangles[3*id_triangle + 1], info_triangles[3*id_triangle + 2]);

  vec3 p1 = (vec4(info_vertices[id_vertices.x * 3], info_vertices[id_vertices.x * 3 + 1], info_vertices[id_vertices.x * 3 + 2],1.)).xyz;
  vec3 p2 = (vec4(info_vertices[id_vertices.y * 3], info_vertices[id_vertices.y * 3 + 1], info_vertices[id_vertices.y * 3 + 2],1.)).xyz;
  vec3 p3 = (vec4(info_vertices[id_vertices.z * 3], info_vertices[id_vertices.z * 3 + 1], info_vertices[id_vertices.z * 3 + 2],1.)).xyz;

  vec3 n1 = (vec4(vertices_normal[id_vertices.x * 3], vertices_normal[id_vertices.x * 3 + 1], vertices_normal[id_vertices.x * 3 + 2],1.)).xyz;
  vec3 n2 = (vec4(vertices_normal[id_vertices.y * 3], vertices_normal[id_vertices.y * 3 + 1], vertices_normal[id_vertices.y * 3 + 2],1.)).xyz;
  vec3 n3 = (vec4(vertices_normal[id_vertices.z * 3], vertices_normal[id_vertices.z * 3 + 1], vertices_normal[id_vertices.z * 3 + 2],1.)).xyz;

  // vec3 edge_ref1 = (vec4(edge_ref_ssbo[id_vertices.x * 3], edge_ref_ssbo[id_vertices.x * 3 + 1], edge_ref_ssbo[id_vertices.x * 3 + 2],1.)).xyz;
  // vec3 edge_ref2 = (vec4(edge_ref_ssbo[id_vertices.y * 3], edge_ref_ssbo[id_vertices.y * 3 + 1], edge_ref_ssbo[id_vertices.y * 3 + 2],1.)).xyz;
  // vec3 edge_ref3 = (vec4(edge_ref_ssbo[id_vertices.z * 3], edge_ref_ssbo[id_vertices.z * 3 + 1], edge_ref_ssbo[id_vertices.z * 3 + 2],1.)).xyz;

  // vec2 h1 = getTexCoord(frag_position, p1,p2,p3) * u_scale_tex_coords;
  // vec2 h2 = getTexCoord(frag_position, p2,p3,p1) * u_scale_tex_coords;
  // vec2 h3 = getTexCoord(frag_position, p3,p1,p2) * u_scale_tex_coords;

  vec2 h1 = getTexCoordFromVertexPlane(frag_position, p1, n1) * u_scale_tex_coords;
  vec2 h2 = getTexCoordFromVertexPlane(frag_position, p2, n2) * u_scale_tex_coords;
  vec2 h3 = getTexCoordFromVertexPlane(frag_position, p3, n3) * u_scale_tex_coords;

  vec3 barycentric = getBarycentric(frag_position, p1,p2,p3);
  float w1 = barycentric.x;
  float w2 = barycentric.y;
  float w3 = barycentric.z;

  vec2 r1 = hash12(int(id_vertices.x));
  vec2 r2 = hash12(int(id_vertices.y));
  vec2 r3 = hash12(int(id_vertices.z));

  vec3 c1 = texture(u_exemplar_texture, h1 + r1).xyz;
  vec3 c2 = texture(u_exemplar_texture, h2 + r2).xyz;
  vec3 c3 = texture(u_exemplar_texture, h3 + r3).xyz;

  vec3 albedo = vec3(c3);
  vec4 result = vec4(albedo,1.);
  f_color = result;
}