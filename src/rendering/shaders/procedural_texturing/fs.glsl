
#define PI 3.141592653

// Environment
uniform vec4 u_ambiant_color;
uniform vec3 u_light_position;

// Camera
uniform mat4 u_view_matrix;
uniform vec2 u_minmax_energy;

// Texture options
uniform float u_scale_tex_coords;
uniform bool u_compensate_distorsions;
uniform float u_micro_priority;
uniform int u_blending_mode;
uniform bool u_override_param;

// Visualization options
uniform uint u_visu_option;
uniform uint u_visu_sample;
uniform bool u_visu_albedo_one_patch;

// Texture exemple
uniform sampler2D u_exemplar_texture;
uniform sampler2D u_exemplar_texture_priority;
uniform sampler2D u_exemplar_texture_normal;
uniform sampler2D u_exemplar_texture_roughness;

// input
in vec3 frag_position;
in vec3 edge_ref;
in vec3 v_frag_position;
in float scaling_field;
in vec3 rotation_field;
in vec3 vertex_normal;

// output
out vec4 f_color;

// Texture Buffer Object
uniform usamplerBuffer u_info_triangles;
uniform samplerBuffer u_info_vertices;
uniform samplerBuffer u_vertices_normal;
uniform usamplerBuffer u_triangle_uvs;
uniform samplerBuffer u_distorsions;
uniform samplerBuffer u_scaling_tile;
uniform samplerBuffer u_rotation_tile;
uniform samplerBuffer u_dir_ref_tile;
uniform samplerBuffer u_normal_samples;

// Mix Max (Thank you Romimap <3)
struct gaussian_distribution {
  float mean;
  float variance;
};

// Rough but good enough approximation for the CDF of a centered and normalized Gaussian distribution
float CDF(float x) {
  return 0.5 + 0.5 * tanh(0.85 * x);
}

float PDF(float x) {
  return exp(-(x * x * 0.5)) / sqrt(2.0 * PI);
}

//See equation (13) in the paper.
float proba_a_over_b(gaussian_distribution A, gaussian_distribution B) {
  float w = max(sqrt(A.variance + B.variance), 0.0001);

  return 1.0 - CDF((A.mean - B.mean) / w);
}

//See equation (15) and (16) in the paper.
gaussian_distribution distribution_max_ab(gaussian_distribution A, gaussian_distribution B) {
  gaussian_distribution G;

  float w = max(sqrt(A.variance + B.variance), 0.001);
  G.mean = A.mean * CDF((A.mean - B.mean) / w)
      + B.mean * CDF((B.mean - A.mean) / w)
      + w * PDF((A.mean - B.mean) / w);

  G.variance = (A.variance + A.mean * A.mean) * CDF((A.mean - B.mean) / w)
      + (B.variance + B.mean * B.mean) * CDF((B.mean - A.mean) / w)
      + (A.mean + B.mean) * w * PDF((A.mean - B.mean) / w)
      - (G.mean * G.mean);
  return G;
}

struct mixmaxdata {
  vec3 color; // Mean value of the texture over the footprint
  gaussian_distribution priorities; // Gaussian distribution of the priorities over the footprint
  vec3 normal;
  float roughness;
};

mixmaxdata make_mixmaxdata(vec2 uv, sampler2D color, sampler2D priority, sampler2D normal, sampler2D roughness, float base) {
  float B = texture(priority, uv).r; //mean of the priorities
  float M = texture(priority, uv).g; //mean of the priorities squared (see LEAN-mapping)

  mixmaxdata m;
  m.color = texture(color, uv).rgb;
  m.normal = texture(normal, uv).rgb;
  m.roughness = texture(roughness, uv).r;
  m.priorities.mean = B;
  m.priorities.variance = M - B * B + base;
  return m;
}

void bias(inout mixmaxdata M, float v) {
  M.priorities.mean += v;
}

mixmaxdata compute_mixmax(mixmaxdata A, mixmaxdata B)
{
  mixmaxdata result;
  float t = proba_a_over_b(A.priorities, B.priorities);
  result.color = mix(A.color, B.color, t);
  result.normal = mix(A.normal, B.normal, t);
  result.roughness = mix(A.roughness, B.roughness, t);
  result.priorities = distribution_max_ab(A.priorities, B.priorities);
  return result;
}

mixmaxdata mixMax(vec2 uvA, vec2 uvB, vec2 uvC, vec3 bary, sampler2D albedo, sampler2D priority, sampler2D normal, sampler2D roughness, float micro_priority)
{
  mixmaxdata A = make_mixmaxdata(uvA, albedo, priority, normal, roughness, micro_priority);
  mixmaxdata B = make_mixmaxdata(uvB, albedo, priority, normal, roughness, micro_priority);
  mixmaxdata C = make_mixmaxdata(uvC, albedo, priority, normal, roughness, micro_priority);

  bias(A, bary.x);
  bias(B, bary.y);
  bias(C, bary.z);

  return compute_mixmax(compute_mixmax(A, B), C);
}

// Utils functions

mat3 compute_TBN(vec3 N, vec3 v)
{
  vec3 T = normalize(cross(N, v));
  vec3 B = cross(N, T);
  return mat3(T, B, N);
}

vec2 getTexCoordFromVertexPlane(vec3 P, vec3 A, vec3 N, vec3 v)
{
  vec3 projPoint = P - dot(P - A, N) * N;

  mat3 TBN = compute_TBN(N, v);

  vec3 AP = projPoint - A;
  return vec2(dot(AP, TBN[0]), dot(AP, TBN[1]));
}

vec2 hash12(int n) {
  float x = fract(sin(float(n) * 12.9898) * 43758.5453);
  float y = fract(sin(float(n) * 78.233) * 43758.5453);
  return vec2(x, y);
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

  if (bary.x >= -eps && bary.y >= -eps && bary.z >= -eps)
    return 1.0;
  return 0.0;
}

vec3 idColor(uint id)
{
  return fract(
    sin(vec3(id, id + 31u, id + 67u)) *
      43758.5453
  );
}

// Texture coordinated
const int MAX_DISTORSION_SLOTS_PER_VERTEX = 8;

struct TriangleUVs
{
  uint samples[3];
  vec2 uvs[9];
  float distance_to_boundary[9];
};

TriangleUVs loadTriangleUVs(int id_triangle)
{
  TriangleUVs t;

  int base = id_triangle * 30;

  t.samples[0] = texelFetch(u_triangle_uvs, base + 0).r;
  t.samples[1] = texelFetch(u_triangle_uvs, base + 1).r;
  t.samples[2] = texelFetch(u_triangle_uvs, base + 2).r;

  int offset = base + 3;

  for (int i = 0; i < 3; ++i)
  {
    for (int j = 0; j < 3; ++j)
    {
      t.uvs[i * 3 + j].x = uintBitsToFloat(texelFetch(u_triangle_uvs, offset++).r);

      t.uvs[i * 3 + j].y = uintBitsToFloat(texelFetch(u_triangle_uvs, offset++).r);
    }
  }

  for (int i = 0; i < 3; ++i)
  {
    for (int j = 0; j < 3; ++j)
    {
      t.distance_to_boundary[i * 3 + j] = uintBitsToFloat(texelFetch(u_triangle_uvs, offset++).r);
    }
  }

  return t;
}

// Texture distorsions
vec2 findUV(int id_vertex, uint sample_id)
{
  for (int i = 0; i < MAX_DISTORSION_SLOTS_PER_VERTEX; ++i)
  {
    vec4 slot = texelFetch(u_distorsions, id_vertex * MAX_DISTORSION_SLOTS_PER_VERTEX + i);
    if (uint(slot.z) == sample_id)
      return slot.xy;
  }
  return vec2(0.0);
}

vec2 loadDistordedUV(TriangleUVs triangleUVs, int p, ivec3 id_vertices, vec3 bary)
{
  uint sample_id = triangleUVs.samples[p];
  vec2 uv0 = findUV(id_vertices.x, sample_id);
  vec2 uv1 = findUV(id_vertices.y, sample_id);
  vec2 uv2 = findUV(id_vertices.z, sample_id);
  return bary.x * uv0 + bary.y * uv1 + bary.z * uv2;
}

// Main
void main() {
  vec3 N = normalize(cross(dFdx(v_frag_position), dFdy(v_frag_position)));
  vec3 L = normalize(u_light_position - v_frag_position);
  float lambert_term = dot(N, L);

  int id_triangle = gl_PrimitiveID;
  ivec3 id_vertices = ivec3(texelFetch(u_info_triangles, id_triangle * 3).x, texelFetch(u_info_triangles, id_triangle * 3 + 1).x, texelFetch(u_info_triangles, id_triangle * 3 + 2).x);

  vec3 p1 = vec3(texelFetch(u_info_vertices, id_vertices.x * 3).x, texelFetch(u_info_vertices, id_vertices.x * 3 + 1).x, texelFetch(u_info_vertices, id_vertices.x * 3 + 2).x);
  vec3 p2 = vec3(texelFetch(u_info_vertices, id_vertices.y * 3).x, texelFetch(u_info_vertices, id_vertices.y * 3 + 1).x, texelFetch(u_info_vertices, id_vertices.y * 3 + 2).x);
  vec3 p3 = vec3(texelFetch(u_info_vertices, id_vertices.z * 3).x, texelFetch(u_info_vertices, id_vertices.z * 3 + 1).x, texelFetch(u_info_vertices, id_vertices.z * 3 + 2).x);

  vec3 n1 = vec3(texelFetch(u_vertices_normal, id_vertices.x * 3).x, texelFetch(u_vertices_normal, id_vertices.x * 3 + 1).x, texelFetch(u_vertices_normal, id_vertices.x * 3 + 2).x);
  vec3 n2 = vec3(texelFetch(u_vertices_normal, id_vertices.y * 3).x, texelFetch(u_vertices_normal, id_vertices.y * 3 + 1).x, texelFetch(u_vertices_normal, id_vertices.y * 3 + 2).x);
  vec3 n3 = vec3(texelFetch(u_vertices_normal, id_vertices.z * 3).x, texelFetch(u_vertices_normal, id_vertices.z * 3 + 1).x, texelFetch(u_vertices_normal, id_vertices.z * 3 + 2).x);

  vec3 bary = vec3(getBarycentric(vec3(frag_position), p1, p2, p3));

  vec2 u[3];
  float w[3];
  vec2 r[3];

  TriangleUVs triangleUVs = loadTriangleUVs(id_triangle);

    vec2 uv_sample[3];
    if (u_compensate_distorsions)
    {
      for (int i = 0; i < 3; i++)
      {
        uv_sample[i] = loadDistordedUV(triangleUVs, i, id_vertices, bary);
      }
    }
    else
    {
      for (int i = 0; i < 3; i++)
      {
        uv_sample[i] = bary.x * triangleUVs.uvs[i * 3 + 0] + bary.y * triangleUVs.uvs[i * 3 + 1] + bary.z * triangleUVs.uvs[i * 3 + 2];
      }
    }

    float distance_sample[3];
    distance_sample[0] = bary.x * triangleUVs.distance_to_boundary[0] + bary.y * triangleUVs.distance_to_boundary[1] + bary.z * triangleUVs.distance_to_boundary[2];
    distance_sample[1] = bary.x * triangleUVs.distance_to_boundary[3] + bary.y * triangleUVs.distance_to_boundary[4] + bary.z * triangleUVs.distance_to_boundary[5];
    distance_sample[2] = bary.x * triangleUVs.distance_to_boundary[6] + bary.y * triangleUVs.distance_to_boundary[7] + bary.z * triangleUVs.distance_to_boundary[8];

    float sum_distance = distance_sample[0] + distance_sample[1] + distance_sample[2];
    w[0] = distance_sample[0] / sum_distance;
    w[1] = distance_sample[1] / sum_distance;
    w[2] = distance_sample[2] / sum_distance;

    float scaling_per_sample[3];
    scaling_per_sample[0] = texelFetch(u_scaling_tile, int(triangleUVs.samples[0])).r;
    scaling_per_sample[1] = texelFetch(u_scaling_tile, int(triangleUVs.samples[1])).r;
    scaling_per_sample[2] = texelFetch(u_scaling_tile, int(triangleUVs.samples[2])).r;
    float fragment_scaling_value = u_scale_tex_coords + w[0] * scaling_per_sample[0] + w[1] * scaling_per_sample[1] + w[2] * scaling_per_sample[2];

    vec3 edge_ref_tile[3];
    edge_ref_tile[0] = texelFetch(u_dir_ref_tile, int(triangleUVs.samples[0])).rgb;
    edge_ref_tile[1] = texelFetch(u_dir_ref_tile, int(triangleUVs.samples[1])).rgb;
    edge_ref_tile[2] = texelFetch(u_dir_ref_tile, int(triangleUVs.samples[2])).rgb;

    vec3 rotation_per_sample[3];
    rotation_per_sample[0] = texelFetch(u_rotation_tile, int(triangleUVs.samples[0])).rgb;
    rotation_per_sample[1] = texelFetch(u_rotation_tile, int(triangleUVs.samples[1])).rgb;
    rotation_per_sample[2] = texelFetch(u_rotation_tile, int(triangleUVs.samples[2])).rgb;

    vec3 normal_per_sample[3];
    normal_per_sample[0] = texelFetch(u_normal_samples, int(triangleUVs.samples[0])).rgb;
    normal_per_sample[1] = texelFetch(u_normal_samples, int(triangleUVs.samples[1])).rgb;
    normal_per_sample[2] = texelFetch(u_normal_samples, int(triangleUVs.samples[2])).rgb;

    float angle_per_sample[3];
    angle_per_sample[0] = 0;
    angle_per_sample[1] = 0;
    angle_per_sample[2] = 0;

    vec3 interpolated_rotation = w[0] * rotation_per_sample[0]+ w[1] * rotation_per_sample[1]+ w[2] * rotation_per_sample[2];
    
    for (int i = 0; i < 3; i++)
    {
      if (length(interpolated_rotation) > 0.)
      {
        vec3 normal = normalize(normal_per_sample[i]);
        vec3 reference = normalize(edge_ref_tile[i] - dot(edge_ref_tile[i], normal) * normal);
        vec3 target = normalize(interpolated_rotation - dot(interpolated_rotation, normal) * normal);
        angle_per_sample[i] = atan(dot(normal, cross(reference, target)),dot(reference, target));
        
      }
    }

    for (int i = 0; i < 3; i++)
    {
        mat2 rotation_transform = inverse(rotate(angle_per_sample[i]));
        u[i] = rotation_transform * (uv_sample[i] * fragment_scaling_value);
    }

    r[0] = hash12(int(triangleUVs.samples[0]));
    r[1] = hash12(int(triangleUVs.samples[1]));
    r[2] = hash12(int(triangleUVs.samples[2]));
  


  vec2 uv[3];
  uv[0] = u[0] + r[0];
  uv[1] = u[1] + r[1];
  uv[2] = u[2] + r[2];

  vec3 c[3];
  c[0] = texture(u_exemplar_texture, uv[0]).xyz;
  c[1] = texture(u_exemplar_texture, uv[1]).xyz;
  c[2] = texture(u_exemplar_texture, uv[2]).xyz;

  vec3 albedo;

  if (!u_visu_albedo_one_patch)
    albedo = vec3(c[0] * w[0] + c[1] * w[1] + c[2] * w[2]);

  else
    albedo = c[u_visu_sample];

  //TODO fix perf with high texture scaling
  vec4 result;
  if (u_blending_mode == 1)
  {
    mixmaxdata M;
    M = mixMax(uv[0], uv[1], uv[2], vec3(w[0], w[1], w[2]), u_exemplar_texture, u_exemplar_texture_priority, u_exemplar_texture_normal, u_exemplar_texture_roughness, u_micro_priority);

    // Normal mapping
    vec3 normal = normalize(M.normal * 2. - 1.);
    mat3 TBN = compute_TBN(N, edge_ref);
    vec3 normalWS = normalize(TBN * normal);
    result = vec4(M.color * dot(normalWS, L), 1);
  }
  else
  {
    result = vec4(albedo * lambert_term, 1.);
  }

  switch (u_visu_option)
  {
    // TnB
    case 0:
    f_color = result;
    break;
    // Sample ID
    case 1:
    f_color = vec4(idColor(triangleUVs.samples[u_visu_sample]), 1);
    break;
    // UV
    case 2:
    f_color = vec4(uv[u_visu_sample], 0, 1);
    break;
    // Distance from border
    case 3:
    f_color = vec4(w[u_visu_sample], 0, 0, 1);
    break;
    // Tile reference direction
    case 4:
    f_color = vec4(edge_ref_tile[u_visu_sample], 1);
    break;
    // Tile scaling value
    case 5:
    f_color = vec4(scaling_per_sample[u_visu_sample], 0, 0, 1);
    break;
    // Tile rotation angle
    case 6:
    // f_color = vec4(rotation_value_a[u_visu_sample] / (2. * PI), 0, 0, 1);
    f_color = vec4(angle_per_sample[u_visu_sample] / (2. * PI), 0, 0, 1);
    break;
    // Sample Normal
    case 7:
    f_color = vec4(normal_per_sample[u_visu_sample], 1);
    break;
    // Fragment scaling value
    case 8:
    f_color = vec4(fragment_scaling_value);
    break;
    // Fragment normalized rotation angle
    case 9:
    f_color = vec4(interpolated_rotation, 1);
    break;

  }
}
