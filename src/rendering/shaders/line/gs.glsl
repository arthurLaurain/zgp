layout(lines) in;
layout(triangle_strip, max_vertices = 4) out;

uniform vec2 u_viewport_size; // Viewport width and height in pixels
uniform float u_line_width;   // Desired line width in pixels

void main() {
  vec4 p0 = gl_in[0].gl_Position;
  vec4 p1 = gl_in[1].gl_Position;

  // Convert clip-space positions to NDC
  vec2 ndc0 = p0.xy / p0.w;
  vec2 ndc1 = p1.xy / p1.w;

  // Convert NDC to screen-space pixel coordinates
  vec2 screen0 = ndc0 * (u_viewport_size * 0.5);
  vec2 screen1 = ndc1 * (u_viewport_size * 0.5);

  // Compute line direction and perpendicular normal in screen pixels
  vec2 dir = normalize(screen1 - screen0);
  vec2 normal = vec2(-dir.y, dir.x);

  // Screen-space half-width offset in NDC coordinates
  vec2 offset = (normal * (u_line_width * 0.5)) / (u_viewport_size * 0.5);

  // Emit 4 vertices for the screen-aligned quad
  gl_Position = vec4((ndc0 + offset) * p0.w, p0.z, p0.w);
  EmitVertex();

  gl_Position = vec4((ndc0 - offset) * p0.w, p0.z, p0.w);
  EmitVertex();

  gl_Position = vec4((ndc1 + offset) * p1.w, p1.z, p1.w);
  EmitVertex();

  gl_Position = vec4((ndc1 - offset) * p1.w, p1.z, p1.w);
  EmitVertex();

  EndPrimitive();
}
