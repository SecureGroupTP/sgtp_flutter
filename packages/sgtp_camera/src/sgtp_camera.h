#pragma once
#include <stdint.h>

#ifdef _WIN32
#  define SGTP_CAM_EXPORT __declspec(dllexport)
#else
#  define SGTP_CAM_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

// Called from a GStreamer streaming thread when a new preview frame arrives.
// rgba_data points to width*height*4 bytes (RGBA). The buffer is valid only
// for the duration of the call — copy if needed.
typedef void (*SgtpFrameCallback)(
    uint8_t* rgba_data,
    int32_t  width,
    int32_t  height,
    int64_t  pts_ms
);

// Called on any pipeline error.
typedef void (*SgtpErrorCallback)(const char* message);

typedef struct {
    char id[256];            // device identifier passed back to sgtp_camera_open
    char display_name[256];  // human-readable name for UI
} SgtpDeviceInfo;

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

// Must be called once before anything else.
SGTP_CAM_EXPORT void sgtp_camera_init(void);
SGTP_CAM_EXPORT void sgtp_camera_deinit(void);

// ---------------------------------------------------------------------------
// Device enumeration
// ---------------------------------------------------------------------------

// Fills |devices| with up to |max_devices| entries.
// Returns the total number of video capture devices found.
SGTP_CAM_EXPORT int32_t sgtp_camera_enumerate(
    SgtpDeviceInfo* devices,
    int32_t         max_devices
);

// ---------------------------------------------------------------------------
// Preview
// ---------------------------------------------------------------------------

// Open the camera and start delivering RGBA preview frames via |on_frame|.
// |device_id|: value from SgtpDeviceInfo.id, or NULL for the system default.
// |preview_width|/|preview_height|: desired frame size for the callback.
// Returns 0 on success, non-zero on failure.
SGTP_CAM_EXPORT int32_t sgtp_camera_open(
    const char*       device_id,
    int32_t           preview_width,
    int32_t           preview_height,
    SgtpFrameCallback on_frame,
    SgtpErrorCallback on_error
);

// Stop preview and release the camera device.
SGTP_CAM_EXPORT void sgtp_camera_close(void);

// ---------------------------------------------------------------------------
// Recording
// ---------------------------------------------------------------------------

// Start recording to |output_path| (must be a writable MP4 path).
// The output is square H.264+AAC, |target_size|x|target_size| pixels.
// Returns 0 on success. May only be called while the camera is open.
SGTP_CAM_EXPORT int32_t sgtp_camera_start_recording(
    const char* output_path,
    int32_t     target_size,   // e.g. 480
    int32_t     video_kbps,    // e.g. 1000
    int32_t     audio_kbps     // e.g. 64
);

// Stop the current recording and finalise the MP4 file.
// Returns the recorded duration in milliseconds.
SGTP_CAM_EXPORT int64_t sgtp_camera_stop_recording(void);

// Returns 1 if currently recording, 0 otherwise.
SGTP_CAM_EXPORT int32_t sgtp_camera_is_recording(void);

#ifdef __cplusplus
}
#endif
