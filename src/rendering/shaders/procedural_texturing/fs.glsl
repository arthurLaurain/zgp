
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

struct SSBO_distorsion
{
  mat3 eigenvectors[3];
  vec4 eigenvalues[3];
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

vec2 getTexCoord(vec3 P, vec3 A, vec3 B, vec3 C)
{
  vec3 N = normalize(cross(B - A, C - A));
  vec3 T = normalize(B - A);
  vec3 BT = cross(N,T);

  vec3 AP = P - A;

  return vec2(dot(AP,T), dot(AP,BT));
  
}

bool pointOnTriangle(vec3 p, vec3 a, vec3 b, vec3 c)
{
    float scale = length(b - a) + length(c - a) + length(c - b);
    float eps = 1e-6 * scale;

    vec3 v0 = b - a;
    vec3 v1 = c - a;
    vec3 v2 = p - a;

    vec3 n = cross(v0, v1);
    float n_len = length(n);

    if(n_len < eps)
        return false;

    n /= n_len;


    float d00 = dot(v0, v0);
    float d01 = dot(v0, v1);
    float d11 = dot(v1, v1);
    float d20 = dot(v2, v0);
    float d21 = dot(v2, v1);

    float denom = d00 * d11 - d01 * d01;

    if(abs(denom) < eps)
        return false;

    float v = (d11 * d20 - d01 * d21) / denom;
    float w = (d00 * d21 - d01 * d20) / denom;
    float u = 1.0 - v - w;

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

vec4 mat3ToQuat(mat3 m)
{
    float trace = m[0][0] + m[1][1] + m[2][2];
    vec4 q;

    if (trace > 0.0) {
        float s = sqrt(trace + 1.0) * 2.0;
        q.w = 0.25 * s;
        q.x = (m[2][1] - m[1][2]) / s;
        q.y = (m[0][2] - m[2][0]) / s;
        q.z = (m[1][0] - m[0][1]) / s;
    } else if ((m[0][0] > m[1][1]) && (m[0][0] > m[2][2])) {
        float s = sqrt(1.0 + m[0][0] - m[1][1] - m[2][2]) * 2.0;
        q.w = (m[2][1] - m[1][2]) / s;
        q.x = 0.25 * s;
        q.y = (m[0][1] + m[1][0]) / s;
        q.z = (m[0][2] + m[2][0]) / s;
    } else if (m[1][1] > m[2][2]) {
        float s = sqrt(1.0 + m[1][1] - m[0][0] - m[2][2]) * 2.0;
        q.w = (m[0][2] - m[2][0]) / s;
        q.x = (m[0][1] + m[1][0]) / s;
        q.y = 0.25 * s;
        q.z = (m[1][2] + m[2][1]) / s;
    } else {
        float s = sqrt(1.0 + m[2][2] - m[0][0] - m[1][1]) * 2.0;
        q.w = (m[1][0] - m[0][1]) / s;
        q.x = (m[0][2] + m[2][0]) / s;
        q.y = (m[1][2] + m[2][1]) / s;
        q.z = 0.25 * s;
    }

    return normalize(q);
}

mat3 quatToMat3(vec4 q)
{
    float x = q.x, y = q.y, z = q.z, w = q.w;

    return mat3(
        1.0 - 2.0*(y*y + z*z), 2.0*(x*y - z*w),     2.0*(x*z + y*w),
        2.0*(x*y + z*w),     1.0 - 2.0*(x*x + z*z), 2.0*(y*z - x*w),
        2.0*(x*z - y*w),     2.0*(y*z + x*w),     1.0 - 2.0*(x*x + y*y)
    );
}

void computeInterpolationBetweenEigenElements(mat3 eigenvectors0, mat3 eigenvalues0,mat3 eigenvectors1, mat3 eigenvalues1,mat3 eigenvectors2, mat3 eigenvalues2,vec3 bary,out mat3 eigenvectors_S,out mat3 eigenvalues_S)
{
    vec4 q0 = mat3ToQuat(eigenvectors0);
    vec4 q1 = mat3ToQuat(eigenvectors1);
    vec4 q2 = mat3ToQuat(eigenvectors2);

    if (dot(q0, q1) < 0.0) q1 = -q1;
    if (dot(q0, q2) < 0.0) q2 = -q2;

    vec4 q = normalize(bary.x * q0 + bary.y * q1 + bary.z * q2);

    eigenvectors_S = quatToMat3(q);

    eigenvalues_S = mat3(
        eigenvalues0[0][0] * bary.x + eigenvalues1[0][0] * bary.y + eigenvalues2[0][0] * bary.z, 0, 0,
        0, eigenvalues0[1][1] * bary.x + eigenvalues1[1][1] * bary.y + eigenvalues2[1][1] * bary.z, 0,
        0, 0, eigenvalues0[2][2] * bary.x + eigenvalues1[2][2] * bary.y + eigenvalues2[2][2] * bary.z
    );
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

  SSBO_distorsion distorsion = distorsions[id_triangle];

  mat3 eigenvectors0 = distorsion.eigenvectors[0];
  mat3 eigenvectors1 = distorsion.eigenvectors[1];
  mat3 eigenvectors2 = distorsion.eigenvectors[2];

  mat3 eigenvalues0 = mat3(
    vec3(distorsion.eigenvalues[0].x, 0.0, 0.0),
    vec3(0.0, distorsion.eigenvalues[0].y, 0.0),
    vec3(0.0,0.0,distorsion.eigenvalues[0].z)
  );

  mat3 eigenvalues1 = mat3(
    vec3(distorsion.eigenvalues[1].x, 0.0, 0.0),
    vec3(0.0, distorsion.eigenvalues[1].y, 0.0),
    vec3(0.0,0.0,distorsion.eigenvalues[1].z)
  );

  mat3 eigenvalues2 = mat3(
    vec3(distorsion.eigenvalues[2].x, 0.0, 0.0),
    vec3(0.0, distorsion.eigenvalues[2].y, 0.0),
    vec3(0.0,0.0,distorsion.eigenvalues[2].z)
  );

  mat3 eigenvectors_S = mat3(0.);
  mat3 eigenvalues_S = mat3(0.);

  computeInterpolationBetweenEigenElements(eigenvectors0, eigenvalues0, eigenvectors1, eigenvalues1, eigenvectors2, eigenvalues2, bary, eigenvectors_S, eigenvalues_S);

  mat3 S = eigenvectors_S * eigenvalues_S * transpose(eigenvectors_S);

  if(u_compense_distorsions)
  {
    c1 = texture(u_exemplar_texture, u1.xy + r1).xyz;
    c2 = texture(u_exemplar_texture, u2.xy + r2).xyz;
    c3 = texture(u_exemplar_texture, u3.xy + r3).xyz;
  }
  else
  {
    c1 = texture(u_exemplar_texture, u1.xy + r1).xyz;
    c2 = texture(u_exemplar_texture, u2.xy + r2).xyz;
    c3 = texture(u_exemplar_texture, u3.xy + r3).xyz;
  }
  vec3 albedo = vec3(w1 * c1 + w2 * c2 + w3 * c3);
  vec4 result = vec4(albedo * lambert_term,1.);
  
  if(u_visu_arap_energy)
  {
    // float energy = w1 * distorsion.arap_energy.x + w2 * distorsion.arap_energy.y + w3 * distorsion.arap_energy.z;
    float energy = distorsion.arap_energy.x;
    f_color = vec4(energy * u_scale_distorsion, 0., 0., 1.);
  }
  else
    f_color = vec4(result);

  f_color = f_color * addColorForSelectedOneRing(vec4(1.,0.,0.,1.));



}