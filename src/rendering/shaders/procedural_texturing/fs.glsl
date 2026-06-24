
#define PI 3.141592653

uniform vec4 u_ambiant_color;
uniform vec3 u_light_position;
uniform sampler2D u_exemplar_texture;
uniform mat4 u_model_view_matrix;
uniform float u_scale_tex_coords;
uniform float u_scale_distorsion;
uniform bool u_visu_arap_energy;
uniform bool u_compense_distorsions;
uniform vec2 u_minmax_energy;
uniform bool u_distorsions_computed;
uniform bool u_tiles_transform_per_vertex;

in vec3 frag_position;
in vec3 v_frag_position;
in float scaling_field;
in float rotation_field;
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


struct SSBO_distorsion
{
  mat2 S[3];
  vec4 arap_energy;
};

layout(std430, binding = 4) readonly buffer ssbo_triangles_distorsion
{
  SSBO_distorsion distorsions[];
};

layout(std430, binding = 5) readonly buffer ssbo_neigh_selected_vertices
{
  float num_selected_vertices;
  float neigh_selected_vertices[];
};

layout(std430, binding = 6) readonly buffer ssbo_scaling_value
{
  float scaling_value[];
};

layout(std430, binding = 7) readonly buffer ssbo_rotation_value
{
  float rotation_value[];
};

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

    vec3 d = vec3(0,1,0);
    if(abs(N.y) >= 0.99) d = vec3(1,0,0);
    vec3 T = normalize(cross(N, d));
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

    float  d00 = dot(v0, v0);
    float  d01 = dot(v0, v1);
    float  d11 = dot(v1, v1);
    float  d20 = dot(v2, v0);
    float  d21 = dot(v2, v1);

    float denom = d00 * d11 - d01 * d01;
    denom = max(denom, 1e-16);

    float v = (d11 * d20 - d01 * d21) / denom;
    float w = (d00 * d21 - d01 * d20) / denom;
    float u = 1.0 - v - w;

    return vec3(u, v, w);
}

mat2 rotate(float theta)
{
  return mat2(cos(theta), sin(theta), -sin(theta), cos(theta));
}

float pointInTriangleBary(vec3 P, vec3 A, vec3 B, vec3 C)
{
    vec3 bary = vec3(getBarycentric(P, A, B, C));
    float eps = 1e-6;

    if(bary.x >= -eps && bary.y >= -eps && bary.z >= -eps)
        return 1.0;
    return 0.0;
}

vec4 addColorForSelectedOneRing(vec4 rgba)
{
  vec4 color = vec4(1.);
  float t = 0.;
  if (num_selected_vertices > 0)
  {
      int offset = 0;

      for (int i = 0; i < num_selected_vertices; i++)
      {
          int num_neigh = int(neigh_selected_vertices[offset]) - 1;

          vec3 center = vec3(
              neigh_selected_vertices[offset + 1],
              neigh_selected_vertices[offset + 2],
              neigh_selected_vertices[offset + 3]
          );

          int base = offset + 4;

          for (int k = 0; k < num_neigh; k++)
          {
              int k_next = (k + 1) % num_neigh;

              vec3 p1 = center;

              vec3 p2 = vec3(
                  neigh_selected_vertices[base + k * 3 + 0],
                  neigh_selected_vertices[base + k * 3 + 1],
                  neigh_selected_vertices[base + k * 3 + 2]
              );

              vec3 p3 = vec3(
                  neigh_selected_vertices[base + k_next * 3 + 0],
                  neigh_selected_vertices[base + k_next * 3 + 1],
                  neigh_selected_vertices[base + k_next * 3 + 2]
              );

              t += 0.25 * pointInTriangleBary(frag_position, p1, p2, p3);
          }

          offset += 4 + num_neigh * 3;
      }
  }
  return mix(color, rgba, t);
}

void main() {

  vec3 N = normalize(cross(dFdx(v_frag_position), dFdy(v_frag_position)));
  vec3 L = normalize(u_light_position - v_frag_position);
  float lambert_term = dot(N, L);

  int id_triangle = gl_PrimitiveID;

  ivec3 id_vertices = ivec3(info_triangles[3*id_triangle], info_triangles[3*id_triangle + 1], info_triangles[3*id_triangle + 2]);

  vec3 p1 = (vec4(info_vertices[id_vertices.x * 3], info_vertices[id_vertices.x * 3 + 1], info_vertices[id_vertices.x * 3 + 2],1.)).xyz;
  vec3 p2 = (vec4(info_vertices[id_vertices.y * 3], info_vertices[id_vertices.y * 3 + 1], info_vertices[id_vertices.y * 3 + 2],1.)).xyz;
  vec3 p3 = (vec4(info_vertices[id_vertices.z * 3], info_vertices[id_vertices.z * 3 + 1], info_vertices[id_vertices.z * 3 + 2],1.)).xyz;

  vec3 n1 = (vec4(vertices_normal[id_vertices.x * 3], vertices_normal[id_vertices.x * 3 + 1], vertices_normal[id_vertices.x * 3 + 2],1.)).xyz;
  vec3 n2 = (vec4(vertices_normal[id_vertices.y * 3], vertices_normal[id_vertices.y * 3 + 1], vertices_normal[id_vertices.y * 3 + 2],1.)).xyz;
  vec3 n3 = (vec4(vertices_normal[id_vertices.z * 3], vertices_normal[id_vertices.z * 3 + 1], vertices_normal[id_vertices.z * 3 + 2],1.)).xyz;

  vec2 u1;
  vec2 u2;
  vec2 u3;

  
  if(u_tiles_transform_per_vertex)
  {
    mat2 ro1 = rotate(rotation_value[id_vertices.x]);
    mat2 ro2 = rotate(rotation_value[id_vertices.y]);
    mat2 ro3 = rotate(rotation_value[id_vertices.z]);
    u1 = ro1 * getTexCoordFromVertexPlane(frag_position, p1, n1) * u_scale_tex_coords * scaling_value[id_vertices.x];
    u2 = ro2 * getTexCoordFromVertexPlane(frag_position, p2, n2) * u_scale_tex_coords * scaling_value[id_vertices.y];
    u3 = ro3 * getTexCoordFromVertexPlane(frag_position, p3, n3) * u_scale_tex_coords * scaling_value[id_vertices.z];
  }
  else
  {
  
    mat2 rotation_transform = rotate(rotation_field);
    u1 = rotation_transform * getTexCoordFromVertexPlane(frag_position, p1, n1) * u_scale_tex_coords * scaling_field;
    u2 = rotation_transform * getTexCoordFromVertexPlane(frag_position, p2, n2) * u_scale_tex_coords * scaling_field;
    u3 = rotation_transform * getTexCoordFromVertexPlane(frag_position, p3, n3) * u_scale_tex_coords * scaling_field;
  }
  vec3 bary = vec3(getBarycentric(vec3(frag_position), p1, p2, p3));

  vec2 r1 = hash12(int(id_vertices.x));
  vec2 r2 = hash12(int(id_vertices.y));
  vec2 r3 = hash12(int(id_vertices.z));

  vec3 c1;
  vec3 c2;
  vec3 c3;

  float w1 = bary.x;
  float w2 = bary.y;
  float w3 = bary.z;

  SSBO_distorsion distorsion;
  if(u_compense_distorsions && u_distorsions_computed)
  {
    distorsion = distorsions[id_triangle];
    c1 = texture(u_exemplar_texture, distorsion.S[0] * u1.xy + r1).xyz;
    c2 = texture(u_exemplar_texture, distorsion.S[1] * u2.xy + r2).xyz;
    c3 = texture(u_exemplar_texture, distorsion.S[2] * u3.xy + r3).xyz;
  }
  else
  {
    c1 = texture(u_exemplar_texture, u1.xy + r1).xyz;
    c2 = texture(u_exemplar_texture, u2.xy + r2).xyz;
    c3 = texture(u_exemplar_texture, u3.xy + r3).xyz;
  }
  vec3 albedo = vec3(w1 * c1 + w2 * c2 + w3 * c3);
  vec4 result = vec4(albedo * lambert_term,1.);
  
  if(u_visu_arap_energy && u_distorsions_computed)
  {
    float energy = w1 * distorsion.arap_energy.x + w2 * distorsion.arap_energy.y + w3 * distorsion.arap_energy.z;
    
    f_color = vec4(smoothstep(u_minmax_energy.x, u_minmax_energy.y, energy), 0., 0.  , 1.);
  }
  else
    f_color = vec4(result);

  
  f_color = f_color * addColorForSelectedOneRing(vec4(1.,0.,0.,1.));
}