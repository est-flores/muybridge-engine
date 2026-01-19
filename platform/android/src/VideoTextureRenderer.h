#ifndef MUYBRIDGE_VIDEO_TEXTURE_RENDERER_H
#define MUYBRIDGE_VIDEO_TEXTURE_RENDERER_H

/**
 * @file VideoTextureRenderer.h
 * @brief OpenGL ES renderer for external video textures.
 */

#include "muybridge/AVSync.h"
#include "muybridge/Clock.h"
#include "muybridge/Log.h"

#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <GLES3/gl3.h>

#include <atomic>
#include <mutex>

namespace muybridge {
namespace android {

/**
 * @class VideoTextureRenderer
 * @brief Renders video frames from external OES texture.
 */
class VideoTextureRenderer {
public:
  VideoTextureRenderer();
  ~VideoTextureRenderer();

  /**
   * @brief Initialize OpenGL resources.
   * @return true on success
   */
  bool initialize();

  /**
   * @brief Set viewport dimensions.
   */
  void setViewport(int width, int height);

  /**
   * @brief Get the texture ID for SurfaceTexture.
   */
  GLuint getTextureId() const { return textureId_; }

  /**
   * @brief Render current texture to screen.
   * @param transformMatrix 4x4 texture transform from SurfaceTexture
   */
  void render(const float *transformMatrix);

  /**
   * @brief Release OpenGL resources.
   */
  void release();

private:
  bool compileShaders();
  GLuint compileShader(GLenum type, const char *source);

  // OpenGL objects
  GLuint program_ = 0;
  GLuint textureId_ = 0;
  GLuint vao_ = 0;
  GLuint vbo_ = 0;

  // Uniform locations
  GLint uTextureLoc_ = -1;
  GLint uTransformLoc_ = -1;

  // Viewport
  int viewportWidth_ = 0;
  int viewportHeight_ = 0;

  bool initialized_ = false;
};

// Shader sources
extern const char *kVideoVertexShader;
extern const char *kVideoFragmentShader;

} // namespace android
} // namespace muybridge

#endif // MUYBRIDGE_VIDEO_TEXTURE_RENDERER_H
