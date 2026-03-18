
#define PI 3.141592653

uniform vec4 u_ambiant_color;
uniform vec3 u_light_position;
uniform sampler2D u_exemplar_texture;
uniform mat4 u_model_view_matrix;
uniform float u_scale_tex_coords;
uniform float u_scale_distorsion;
uniform bool u_visu_rotation_distorsion;
uniform bool u_visu_stretch_distorsion;

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


// mat3 polarDecomposition(mat3 F)
// {
//     mat3 R = F;

//     for(int i = 0; i < 5; i++)
//     {
//         // to avoid inversion cost, see paper Stable and Efficient Computation of Generalized Polar Decompositions by Benner et al.
//         mat3 R_invT = inverse(transpose(R));
//         R = 0.5 * (R + R_invT);
//     }

//     return R;
// }

// GLSL function to compute eigenvalues of a symmetric 3x3 matrix using Jacobi iteration
vec3 jacobiEigenvalues(mat3 A) {
    const int MAX_ITER = 10;
    const float EPSILON = 1e-5;

    mat3 D = A; // Working copy
    for (int iter = 0; iter < MAX_ITER; iter++) {
        // Find largest off-diagonal element
        float a01 = D[0][1];
        float a02 = D[0][2];
        float a12 = D[1][2];

        float abs01 = abs(a01);
        float abs02 = abs(a02);
        float abs12 = abs(a12);

        // Pick the largest
        int p, q;
        if (abs01 > abs02 && abs01 > abs12) { p = 0; q = 1; }
        else if (abs02 > abs12) { p = 0; q = 2; }
        else { p = 1; q = 2; }

        // If off-diagonal is small, we're done
        if (abs(D[p][q]) < EPSILON) break;

        // Compute rotation
        float phi = 0.5 * atan(2.0 * D[p][q], D[q][q] - D[p][p]);
        float c = cos(phi);
        float s = sin(phi);

        // Apply rotation to matrix
        for (int k = 0; k < 3; k++) {
            float Dpk = D[p][k];
            float Dqk = D[q][k];
            D[p][k] = c*Dpk - s*Dqk;
            D[q][k] = s*Dpk + c*Dqk;
        }
        for (int k = 0; k < 3; k++) {
            float Dkp = D[k][p];
            float Dkq = D[k][q];
            D[k][p] = c*Dkp - s*Dkq;
            D[k][q] = s*Dkp + c*Dkq;
        }
    }

    // Diagonal now approximates eigenvalues
    return vec3(D[0][0], D[1][1], D[2][2]);
}

vec3 eigenvector(mat3 A, float lambda) {
    mat3 B = A - lambda * mat3(1.0);
    vec3 v;

    v = cross(B[0], B[1]);
    if (length(v) < 1e-6) v = cross(B[0], B[2]);
    if (length(v) < 1e-6) v = cross(B[1], B[2]);
    return normalize(v);
}

void polarDecomposition(mat3 A, out mat3 R, out mat3 S)
{
  mat3 AA_T = A * transpose(A);

  vec3 eigenvalues = jacobiEigenvalues(AA_T);
  mat3 U = mat3(eigenvector(AA_T, eigenvalues.x), eigenvector(AA_T, eigenvalues.y), eigenvector(AA_T, eigenvalues.z));
  mat3 U_t = transpose(U);

  vec3 eigenvalues_squared = sqrt(eigenvalues);
  mat3 sigma = mat3(vec3(eigenvalues_squared.x, 0., 0.), 
                    vec3(0., eigenvalues_squared.y, 0.),
                    vec3(0.,0.,eigenvalues_squared.z));
  
  R = U * sigma * U_t;
  S = transpose(R) * A;
}

void computeStretchAndRotation(vec3 x0, vec3 x1, vec3 x2, vec2 uv0, vec2 uv1, vec2 uv2, out mat3 R, out mat3 S)
{
  vec3 x_01 = x1 - x0;
  vec3 x_02 = x2 - x0;
  vec3 x_n = cross(x_01,x_02);
  mat3 P = mat3(x_01, x_02, x_n);

  vec3 u_01 = vec3(uv1,0) - vec3(uv0,0);
  vec3 u_02 = vec3(uv2,0) - vec3(uv0,0);
  vec3 u_n = vec3(0,0,1);
  mat3 U = mat3(u_01, u_02, u_n);

  mat3 F = P * inverse(U);

  polarDecomposition(F, R, S);
}

// https://nulldog.com/calculate-angle-from-rotation-matrix-formulas-examples
// Give rotation magnitude but not the direction of the rotation axis
float rotationAngle(mat3 R)
{
    float traceR = R[0][0] + R[1][1] + R[2][2];
    float cos_theta = (traceR - 1.0) * 0.5;
    cos_theta = clamp(cos_theta, -1.0, 1.0);
    return acos(cos_theta);
}

vec3 stretchFactors(mat3 S)
{
    return vec3(
        length(S[0]),
        length(S[1]),
        length(S[2])
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

  dvec3 bary = getBarycentric(dvec3(frag_position), p1, p2, p3);

  double w1 = bary.x;
  double w2 = bary.y;
  double w3 = bary.z;

  vec2 r1 = hash12(int(id_vertices.x));
  vec2 r2 = hash12(int(id_vertices.y));
  vec2 r3 = hash12(int(id_vertices.z));

  vec3 c1 = texture(u_exemplar_texture, u1.xy + r1).xyz;
  vec3 c2 = texture(u_exemplar_texture, u2.xy + r2).xyz;
  vec3 c3 = texture(u_exemplar_texture, u3.xy + r3).xyz;

  mat3 R;
  mat3 S;
  computeStretchAndRotation(p1,p2,p3,u1,u2,u3,R,S);

  vec3 albedo = vec3(w1 * c1 + w2 * c2 + w3 * c3);
  vec4 result = vec4(albedo * lambert_term,1.);
  
  if(u_visu_rotation_distorsion)
  {
    // rotationAngle(R) [0:PI]
    float theta = rotationAngle(R) / PI;
    // f_color = vec4(rotationAngle(R) * u_scale_distorsion,0.,0.,1.);
    f_color = vec4(vec3(theta,0.,0.) * u_scale_distorsion, 1.);
  }
  else if(u_visu_stretch_distorsion)
    f_color = vec4(stretchFactors(S) * u_scale_distorsion, 1.);
  else
    f_color = result;
}