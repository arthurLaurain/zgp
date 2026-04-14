
#define PI 3.141592653

uniform vec4 u_ambiant_color;
uniform vec3 u_light_position;
uniform sampler2D u_exemplar_texture;
uniform mat4 u_model_view_matrix;
uniform float u_scale_tex_coords;
uniform float u_scale_distorsion;
uniform bool u_visu_area_distorsion;
uniform bool u_visu_angle_distorsion;
uniform bool u_visu_arap_energy;
uniform bool u_compense_distorsions;

in vec3 frag_position;
in vec3 v_frag_position;
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

layout(std430, binding = 4) readonly buffer ssbo_triangles_distorsion
{
  double triangles_distorsion[];
};

layout(std430, binding = 5) readonly buffer ssbo_neigh_selected_vertices
{
  double num_selected_vertices;
  double neigh_selected_vertices[];
};

vec2 getTexCoord(vec3 P, vec3 A, vec3 B, vec3 C)
{
  vec3 N = normalize(cross(B - A, C - A));
  vec3 T = normalize(B - A);
  vec3 BT = cross(N,T);

  vec3 AP = P - A;

  return vec2(dot(AP,T), dot(AP,BT));
  
}



bool pointOnTriangle(vec3 p, dvec3 a, dvec3 b, dvec3 c)
{
    double scale = length(b - a) + length(c - a) + length(c - b);
    double eps = 1e-6 * scale;

    dvec3 v0 = b - a;
    dvec3 v1 = c - a;
    dvec3 v2 = p - a;

    dvec3 n = cross(v0, v1);
    double n_len = length(n);

    if(n_len < eps)
        return false;

    n /= n_len;


    double d00 = dot(v0, v0);
    double d01 = dot(v0, v1);
    double d11 = dot(v1, v1);
    double d20 = dot(v2, v0);
    double d21 = dot(v2, v1);

    double denom = d00 * d11 - d01 * d01;

    if(abs(denom) < eps)
        return false;

    double v = (d11 * d20 - d01 * d21) / denom;
    double w = (d00 * d21 - d01 * d20) / denom;
    double u = 1.0 - v - w;

    return (u >= -eps && v >= -eps && w >= -eps &&
        u <= 1.0 + eps && v <= 1.0 + eps && w <= 1.0 + eps);
}

vec2 getTexCoordFromVertexPlane(vec3 P, vec3 A, vec3 N)
{
    vec3 projPoint = P - dot(P - A, N) * N;

    vec3 up = vec3(0,1,0);
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

dvec3 getBarycentric(dvec3 P, dvec3 A, dvec3 B, dvec3 C)
{
    dvec3 v0 = B - A;
    dvec3 v1 = C - A;
    dvec3 v2 = P - A;

    double d00 = dot(v0, v0);
    double d01 = dot(v0, v1);
    double d11 = dot(v1, v1);
    double d20 = dot(v2, v0);
    double d21 = dot(v2, v1);

    double denom = d00 * d11 - d01 * d01;
    denom = max(denom, 1e-16);

    double v = (d11 * d20 - d01 * d21) / denom;
    double w = (d00 * d21 - d01 * d20) / denom;
    double u = 1.0 - v - w;

    return dvec3(u, v, w);
}

float pointInTriangleBary(dvec3 P, dvec3 A, dvec3 B, dvec3 C)
{
    dvec3 bary = getBarycentric(P, A, B, C);
    double eps = 1e-6;

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

          dvec3 center = dvec3(
              neigh_selected_vertices[offset + 1],
              neigh_selected_vertices[offset + 2],
              neigh_selected_vertices[offset + 3]
          );

          int base = offset + 4;

          for (int k = 0; k < num_neigh; k++)
          {
              int k_next = (k + 1) % num_neigh;

              dvec3 p1 = center;

              dvec3 p2 = dvec3(
                  neigh_selected_vertices[base + k * 3 + 0],
                  neigh_selected_vertices[base + k * 3 + 1],
                  neigh_selected_vertices[base + k * 3 + 2]
              );

              dvec3 p3 = dvec3(
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

mat2 expSPD(mat2 M)
{
    float a = M[0][0];
    float b = M[0][1];
    float c = M[1][1];

    float t = 0.5 * (a + c);
    float d = sqrt(max(0.0, 0.25 * (a - c) * (a - c) + b * b));

    float l1 = t + d;
    float l2 = t - d;

    vec2 v1;
    if (abs(b) > 1e-8)
        v1 = normalize(vec2(b, l1 - a));
    else
        v1 = vec2(1.0, 0.0);

    vec2 v2 = vec2(-v1.y, v1.x);

    mat2 U = mat2(v1, v2);

    float e1 = exp(l1);
    float e2 = exp(l2);

    mat2 D = mat2(
        e1, 0.0,
        0.0, e2
    );

    return U * D * transpose(U);
}

mat2 computeDistorsionMatrix(dvec3 S0, dvec3 S1, dvec3 S2, dvec3 barycentric)
{
  dmat2 m0 = dmat2(dvec2(S0.x, S0.y), dvec2(S0.y, S0.z)); 
  dmat2 m1 = dmat2(dvec2(S1.x, S1.y), dvec2(S1.y, S1.z));
  dmat2 m2 = dmat2(dvec2(S2.x, S2.y), dvec2(S2.y, S2.z));

  dmat2 L = barycentric.x * m0 + barycentric.y * m1 + barycentric.z * m2;

  return expSPD(mat2(L));
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

  // vec3 edge_ref1 = (vec4(edge_ref_ssbo[id_vertices.x * 3], edge_ref_ssbo[id_vertices.x * 3 + 1], edge_ref_ssbo[id_vertices.x * 3 + 2],1.)).xyz;
  // vec3 edge_ref2 = (vec4(edge_ref_ssbo[id_vertices.y * 3], edge_ref_ssbo[id_vertices.y * 3 + 1], edge_ref_ssbo[id_vertices.y * 3 + 2],1.)).xyz;
  // vec3 edge_ref3 = (vec4(edge_ref_ssbo[id_vertices.z * 3], edge_ref_ssbo[id_vertices.z * 3 + 1], edge_ref_ssbo[id_vertices.z * 3 + 2],1.)).xyz;

  // vec2 u1 = getTexCoord(frag_position, p1,p2,p3) * u_scale_tex_coords;
  // vec2 u2 = getTexCoord(frag_position, p2,p3,p1) * u_scale_tex_coords;
  // vec2 u3 = getTexCoord(frag_position, p3,p1,p2) * u_scale_tex_coords;

  vec2 u1 = getTexCoordFromVertexPlane(frag_position, p1, n1) * u_scale_tex_coords;
  vec2 u2 = getTexCoordFromVertexPlane(frag_position, p2, n2) * u_scale_tex_coords;
  vec2 u3 = getTexCoordFromVertexPlane(frag_position, p3, n3) * u_scale_tex_coords;

  dvec3 bary = getBarycentric(dvec3(frag_position), p1, p2, p3);

  double w1 = bary.x;
  double w2 = bary.y;
  double w3 = bary.z;

  vec2 r1 = hash12(int(id_vertices.x));
  vec2 r2 = hash12(int(id_vertices.y));
  vec2 r3 = hash12(int(id_vertices.z));

  dvec4 T0 = dvec4(triangles_distorsion[id_triangle * 12], triangles_distorsion[id_triangle * 12 + 1], triangles_distorsion[id_triangle * 12 + 2], triangles_distorsion[id_triangle * 12 + 3]);
  dvec4 T1 = dvec4(triangles_distorsion[id_triangle * 12 + 4], triangles_distorsion[id_triangle * 12 + 5], triangles_distorsion[id_triangle * 12 + 6], triangles_distorsion[id_triangle * 12 + 7]);
  dvec4 T2 = dvec4(triangles_distorsion[id_triangle * 12 + 8], triangles_distorsion[id_triangle * 12 + 9], triangles_distorsion[id_triangle * 12 + 10], triangles_distorsion[id_triangle * 12 + 11]);

  mat2 S = computeDistorsionMatrix(T0.xyz, T1.xyz, T2.xyz, bary);

  vec3 arap_energy = vec3(T0.w, T1.w, T2.w) * u_scale_distorsion;
  // float angle_distorsion = abs((distorsions.x - distorsions.z)) * u_scale_distorsion;
  // float area_distorsion = abs(1. - distorsions.x * distorsions.z) * u_scale_distorsion;

  vec3 c1;
  vec3 c2;
  vec3 c3;
  if(u_compense_distorsions)
  {
    c1 = texture(u_exemplar_texture, S * u1.xy + r1).xyz;
    c2 = texture(u_exemplar_texture, S * u2.xy + r2).xyz;
    c3 = texture(u_exemplar_texture, S * u3.xy + r3).xyz;
  }
  else
  {
    c1 = texture(u_exemplar_texture, u1.xy + r1).xyz;
    c2 = texture(u_exemplar_texture, u2.xy + r2).xyz;
    c3 = texture(u_exemplar_texture, u3.xy + r3).xyz;
  }
  vec3 albedo = vec3(w1 * c1 + w2 * c2 + w3 * c3);
  vec4 result = vec4(albedo * lambert_term,1.);
  // if(u_visu_angle_distorsion)
  //   f_color = vec4(angle_distorsion,0,0,1);
  // else if(u_visu_area_distorsion)
  //   f_color = vec4(area_distorsion,0,0,1);
  // else if(u_visu_arap_energy)
  //   f_color = vec4(arap_energy, 1);
  // else
  f_color = vec4(result);

  f_color = f_color * addColorForSelectedOneRing(vec4(1.,0.,0.,1.));

}