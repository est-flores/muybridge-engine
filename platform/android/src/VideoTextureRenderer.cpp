#include "VideoTextureRenderer.h"

namespace muybridge {
namespace android {

// Vertex shader - simple fullscreen quad
const char *kVideoVertexShader = R"(#version 300 es
layout(location = 0) in vec4 aPosition;
layout(location = 1) in vec2 aTexCoord;

uniform mat4 uTransform;

out vec2 vTexCoord;

void main() {
    gl_Position = aPosition;
    vTexCoord = (uTransform * vec4(aTexCoord, 0.0, 1.0)).xy;
}
)";

// Fragment shader - sample from external OES texture
const char *kVideoFragmentShader = R"(#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require

precision mediump float;

uniform samplerExternalOES uTexture;

in vec2 vTexCoord;
out vec4 fragColor;

void main() {
    fragColor = texture(uTexture, vTexCoord);
}
)";

// Fullscreen quad vertices
static const float kQuadVertices[] = {
    // Position      // TexCoord
    -1.0f, -1.0f, 0.0f, 0.0f, 1.0f, -1.0f, 1.0f, 0.0f,
    -1.0f, 1.0f,  0.0f, 1.0f, 1.0f, 1.0f,  1.0f, 1.0f,
};

VideoTextureRenderer::VideoTextureRenderer() = default;

VideoTextureRenderer::~VideoTextureRenderer() { release(); }

bool VideoTextureRenderer::initialize() {
  if (initialized_) {
    return true;
  }

  MUY_LOGI("Initializing VideoTextureRenderer");

  // Create external texture
  glGenTextures(1, &textureId_);
  glBindTexture(GL_TEXTURE_EXTERNAL_OES, textureId_);
  glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

  MUY_LOGI("External texture created: %u", textureId_);

  // Compile shaders
  if (!compileShaders()) {
    MUY_LOGE("Failed to compile shaders");
    return false;
  }

  // Create VAO and VBO
  glGenVertexArrays(1, &vao_);
  glGenBuffers(1, &vbo_);

  glBindVertexArray(vao_);
  glBindBuffer(GL_ARRAY_BUFFER, vbo_);
  glBufferData(GL_ARRAY_BUFFER, sizeof(kQuadVertices), kQuadVertices,
               GL_STATIC_DRAW);

  // Position attribute
  glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), nullptr);
  glEnableVertexAttribArray(0);

  // TexCoord attribute
  glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float),
                        reinterpret_cast<void *>(2 * sizeof(float)));
  glEnableVertexAttribArray(1);

  glBindVertexArray(0);

  initialized_ = true;
  MUY_TTFF_MILESTONE("renderer_initialized");
  return true;
}

bool VideoTextureRenderer::compileShaders() {
  GLuint vertexShader = compileShader(GL_VERTEX_SHADER, kVideoVertexShader);
  if (!vertexShader)
    return false;

  GLuint fragmentShader =
      compileShader(GL_FRAGMENT_SHADER, kVideoFragmentShader);
  if (!fragmentShader) {
    glDeleteShader(vertexShader);
    return false;
  }

  program_ = glCreateProgram();
  glAttachShader(program_, vertexShader);
  glAttachShader(program_, fragmentShader);
  glLinkProgram(program_);

  glDeleteShader(vertexShader);
  glDeleteShader(fragmentShader);

  GLint linked = 0;
  glGetProgramiv(program_, GL_LINK_STATUS, &linked);
  if (!linked) {
    char log[512];
    glGetProgramInfoLog(program_, sizeof(log), nullptr, log);
    MUY_LOGE("Program link failed: %s", log);
    glDeleteProgram(program_);
    program_ = 0;
    return false;
  }

  uTextureLoc_ = glGetUniformLocation(program_, "uTexture");
  uTransformLoc_ = glGetUniformLocation(program_, "uTransform");

  MUY_LOGI("Shaders compiled successfully");
  return true;
}

GLuint VideoTextureRenderer::compileShader(GLenum type, const char *source) {
  GLuint shader = glCreateShader(type);
  glShaderSource(shader, 1, &source, nullptr);
  glCompileShader(shader);

  GLint compiled = 0;
  glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
  if (!compiled) {
    char log[512];
    glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
    MUY_LOGE("Shader compile failed: %s", log);
    glDeleteShader(shader);
    return 0;
  }

  return shader;
}

void VideoTextureRenderer::setViewport(int width, int height) {
  viewportWidth_ = width;
  viewportHeight_ = height;
  MUY_LOGD("Viewport set: %dx%d", width, height);
}

void VideoTextureRenderer::render(const float *transformMatrix) {
  if (!initialized_)
    return;

  glViewport(0, 0, viewportWidth_, viewportHeight_);
  glClear(GL_COLOR_BUFFER_BIT);

  glUseProgram(program_);

  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_EXTERNAL_OES, textureId_);
  glUniform1i(uTextureLoc_, 0);

  if (transformMatrix) {
    glUniformMatrix4fv(uTransformLoc_, 1, GL_FALSE, transformMatrix);
  }

  glBindVertexArray(vao_);
  glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
  glBindVertexArray(0);
}

void VideoTextureRenderer::release() {
  if (!initialized_)
    return;

  if (vao_) {
    glDeleteVertexArrays(1, &vao_);
    vao_ = 0;
  }

  if (vbo_) {
    glDeleteBuffers(1, &vbo_);
    vbo_ = 0;
  }

  if (program_) {
    glDeleteProgram(program_);
    program_ = 0;
  }

  if (textureId_) {
    glDeleteTextures(1, &textureId_);
    textureId_ = 0;
  }

  initialized_ = false;
  MUY_LOGI("Renderer released");
}

} // namespace android
} // namespace muybridge
