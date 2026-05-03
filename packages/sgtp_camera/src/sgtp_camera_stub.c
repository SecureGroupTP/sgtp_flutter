#include "sgtp_camera.h"

static const char* kStubMessage =
    "sgtp_camera: GStreamer runtime is missing; feature disabled";

SGTP_CAM_EXPORT void sgtp_camera_init(void) {}

SGTP_CAM_EXPORT void sgtp_camera_deinit(void) {}

SGTP_CAM_EXPORT int32_t sgtp_camera_enumerate(
    SgtpDeviceInfo* devices,
    int32_t max_devices
) {
  (void)devices;
  (void)max_devices;
  return 0;
}

SGTP_CAM_EXPORT int32_t sgtp_camera_open(
    const char* device_id,
    int32_t preview_width,
    int32_t preview_height,
    SgtpFrameCallback on_frame,
    SgtpErrorCallback on_error
) {
  (void)device_id;
  (void)preview_width;
  (void)preview_height;
  (void)on_frame;
  if (on_error) on_error(kStubMessage);
  return -1;
}

SGTP_CAM_EXPORT void sgtp_camera_close(void) {}

SGTP_CAM_EXPORT int32_t sgtp_camera_start_recording(
    const char* output_path,
    int32_t target_size,
    int32_t video_kbps,
    int32_t audio_kbps
) {
  (void)output_path;
  (void)target_size;
  (void)video_kbps;
  (void)audio_kbps;
  return -1;
}

SGTP_CAM_EXPORT int64_t sgtp_camera_stop_recording(void) {
  return 0;
}

SGTP_CAM_EXPORT int32_t sgtp_camera_is_recording(void) {
  return 0;
}
