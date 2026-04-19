#include "sgtp_camera.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <gst/video/video.h>

#if defined(_WIN32)
#  include <windows.h>
#endif

#ifdef __APPLE__
#  include <TargetConditionals.h>
#  if TARGET_OS_IOS
#    include "gst_ios_init.h"
#  endif
#endif

// ---------------------------------------------------------------------------
// Platform source element names
// ---------------------------------------------------------------------------

#if defined(_WIN32)
#  define SGTP_VIDEO_SRC  "mfvideosrc"
#  define SGTP_AUDIO_SRC  "wasapisrc"
#  define SGTP_DEV_PROP   "device-index"   // integer index
#  define SGTP_AUDIO_ENC  "avenc_aac"      // from gst-libav
#elif defined(__ANDROID__)
#  define SGTP_VIDEO_SRC  "ahcsrc"
#  define SGTP_AUDIO_SRC  "openslessrc"
#  define SGTP_DEV_PROP   "camera"         // 0=back, 1=front
#  define SGTP_AUDIO_ENC  "voaacenc"       // Android HW encoder
#elif defined(IOS)
#  define SGTP_VIDEO_SRC  "avfvideosrc"
#  define SGTP_AUDIO_SRC  "osxaudiosrc"
#  define SGTP_DEV_PROP   "device-index"
#  define SGTP_AUDIO_ENC  "voaacenc"       // iOS HW encoder
#elif defined(__APPLE__)
#  define SGTP_VIDEO_SRC  "avfvideosrc"
#  define SGTP_AUDIO_SRC  "osxaudiosrc"
#  define SGTP_DEV_PROP   "device-index"
#  define SGTP_AUDIO_ENC  "avenc_aac"      // from gst-libav
#else  // Linux
#  define SGTP_VIDEO_SRC  "v4l2src"
#  define SGTP_AUDIO_SRC  "pulsesrc"
#  define SGTP_DEV_PROP   "device"         // string path /dev/videoN
#  define SGTP_AUDIO_ENC  "avenc_aac"      // from gst-libav
#endif

// ---------------------------------------------------------------------------
// Internal state
// ---------------------------------------------------------------------------

typedef struct {
    // --- Preview pipeline ---
    GstElement *pipeline;
    GstElement *preview_sink;  // appsink

    // --- Callbacks ---
    SgtpFrameCallback frame_cb;
    SgtpErrorCallback error_cb;

    // --- GLib main loop (runs GStreamer bus + signals) ---
    GMainLoop  *loop;
    GThread    *loop_thread;

    // --- Recording state ---
    gboolean     is_recording;
    GstClockTime record_start_time;

    // --- Device ---
    char device_id[256];    // empty = default
    int  preview_width;
    int  preview_height;
} SgtpCtx;

static SgtpCtx *g_ctx = NULL;

#if defined(_WIN32)
static void ensure_gstreamer_windows_env(void) {
    HMODULE module = NULL;
    char module_path[MAX_PATH] = {0};
    char module_dir[MAX_PATH] = {0};
    char current_path[32767] = {0};
    char merged_path[32767] = {0};
    char scanner_path[MAX_PATH] = {0};

    if (!GetModuleHandleExA(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
            GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            (LPCSTR)&ensure_gstreamer_windows_env,
            &module)) {
        return;
    }
    if (GetModuleFileNameA(module, module_path, MAX_PATH) == 0) {
        return;
    }

    strncpy(module_dir, module_path, sizeof(module_dir) - 1);
    for (int i = (int)strlen(module_dir) - 1; i >= 0; --i) {
        if (module_dir[i] == '\\' || module_dir[i] == '/') {
            module_dir[i] = '\0';
            break;
        }
    }

    _putenv_s("GST_PLUGIN_PATH_1_0", module_dir);
    _putenv_s("GST_PLUGIN_SYSTEM_PATH_1_0", module_dir);

    snprintf(scanner_path, sizeof(scanner_path),
             "%s\\gst-plugin-scanner.exe", module_dir);
    if (GetFileAttributesA(scanner_path) != INVALID_FILE_ATTRIBUTES) {
        _putenv_s("GST_PLUGIN_SCANNER", scanner_path);
    }

    DWORD got = GetEnvironmentVariableA("PATH", current_path, (DWORD)sizeof(current_path));
    if (got == 0 || got >= sizeof(current_path)) {
        _putenv_s("PATH", module_dir);
        return;
    }

    snprintf(merged_path, sizeof(merged_path), "%s;%s", module_dir, current_path);
    _putenv_s("PATH", merged_path);
}
#endif

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static void report_error(const char *msg) {
    if (g_ctx && g_ctx->error_cb) {
        g_ctx->error_cb(msg);
    } else {
        fprintf(stderr, "[sgtp_camera] %s\n", msg);
    }
}

// GLib thread: runs the GStreamer main loop.
static gpointer loop_thread_func(gpointer data) {
    g_main_loop_run((GMainLoop *)data);
    return NULL;
}

// Bus watch: forward errors to the error callback.
static gboolean bus_watch(GstBus *bus, GstMessage *msg, gpointer user_data) {
    (void)bus; (void)user_data;
    if (GST_MESSAGE_TYPE(msg) == GST_MESSAGE_ERROR) {
        GError *err = NULL;
        gchar  *dbg = NULL;
        gst_message_parse_error(msg, &err, &dbg);
        char buf[512];
        snprintf(buf, sizeof(buf), "GStreamer error: %s (%s)",
                 err ? err->message : "?", dbg ? dbg : "");
        report_error(buf);
        g_clear_error(&err);
        g_free(dbg);
    }
    return TRUE;
}

// appsink new-sample callback: convert to RGBA and forward to Dart.
static GstFlowReturn on_new_sample(GstAppSink *sink, gpointer user_data) {
    (void)user_data;
    if (!g_ctx || !g_ctx->frame_cb) return GST_FLOW_OK;

    GstSample *sample = gst_app_sink_pull_sample(sink);
    if (!sample) return GST_FLOW_OK;

    GstBuffer *buf  = gst_sample_get_buffer(sample);
    GstCaps   *caps = gst_sample_get_caps(sample);

    if (!buf || !caps) { gst_sample_unref(sample); return GST_FLOW_OK; }

    GstVideoInfo info;
    if (!gst_video_info_from_caps(&info, caps)) {
        gst_sample_unref(sample);
        return GST_FLOW_OK;
    }

    GstMapInfo map;
    if (!gst_buffer_map(buf, &map, GST_MAP_READ)) {
        gst_sample_unref(sample);
        return GST_FLOW_OK;
    }

    int64_t pts_ms = (GST_BUFFER_PTS(buf) != GST_CLOCK_TIME_NONE)
        ? (int64_t)(GST_BUFFER_PTS(buf) / GST_MSECOND)
        : 0;

    g_ctx->frame_cb(
        (uint8_t *)map.data,
        (int32_t)GST_VIDEO_INFO_WIDTH(&info),
        (int32_t)GST_VIDEO_INFO_HEIGHT(&info),
        pts_ms
    );

    gst_buffer_unmap(buf, &map);
    gst_sample_unref(sample);
    return GST_FLOW_OK;
}

// ---------------------------------------------------------------------------
// Pipeline builder
// ---------------------------------------------------------------------------

// Returns a heap-allocated pipeline description string.
// Caller must g_free() it.
// output_path == NULL  → preview-only pipeline
// output_path != NULL  → preview + recording pipeline
static gchar* build_pipeline_desc(
    const char *device_id,
    int preview_w, int preview_h,
    const char *output_path,
    int target_size, int video_kbps, int audio_kbps)
{
    // Device selection string fragment
    char dev_frag[128] = "";
#if defined(_WIN32) || defined(__APPLE__) || defined(__ANDROID__)
    if (device_id && device_id[0] != '\0') {
        // On Windows/Apple/Android the property is an integer index.
        // On Linux it's a string path; handled in the else below.
        snprintf(dev_frag, sizeof(dev_frag), " " SGTP_DEV_PROP "=%s", device_id);
    }
#else
    if (device_id && device_id[0] != '\0') {
        snprintf(dev_frag, sizeof(dev_frag), " " SGTP_DEV_PROP "=%s", device_id);
    }
#endif

    if (output_path == NULL) {
        // ---- Preview only ----
        return g_strdup_printf(
            SGTP_VIDEO_SRC "%s name=vsrc "
            "! videoconvert "
            "! aspectratiocrop aspect-ratio=1/1 "
            "! videoscale "
            "! video/x-raw,format=RGBA,width=%d,height=%d "
            "! appsink name=preview_sink emit-signals=true sync=false "
            "  max-buffers=2 drop=true",
            dev_frag,
            preview_w, preview_h
        );
    } else {
        // Normalize path separators for GStreamer (forward slashes required)
        char norm_path[1024];
        strncpy(norm_path, output_path, sizeof(norm_path) - 1);
        norm_path[sizeof(norm_path) - 1] = '\0';
#ifdef _WIN32
        for (char *p = norm_path; *p; p++) { if (*p == '\\') *p = '/'; }
#endif

        // ---- Preview + Recording ----
        // Video: capture → tee
        //   branch A → aspectratiocrop → preview appsink
        //   branch B → aspectratiocrop → scale → encode → mux
        // Audio: capture → encode → mux → filesink
        return g_strdup_printf(
            SGTP_VIDEO_SRC "%s name=vsrc "
            "! videoconvert "
            "! tee name=t "

            // Preview branch (square crop)
            "t. ! queue leaky=downstream max-size-buffers=2 "
            "! aspectratiocrop aspect-ratio=1/1 "
            "! videoscale "
            "! video/x-raw,format=RGBA,width=%d,height=%d "
            "! appsink name=preview_sink emit-signals=true sync=false "
            "  max-buffers=2 drop=true "

            // Recording branch: crop square → scale → H.264 → mp4mux → filesink
            "t. ! queue leaky=downstream max-size-buffers=4 "
            "! aspectratiocrop aspect-ratio=1/1 "
            "! videoscale "
            "! video/x-raw,width=%d,height=%d "
            "! videoconvert "
            "! x264enc bitrate=%d tune=zerolatency key-int-max=30 "
            "! h264parse "
            "! mp4mux name=mux ! filesink location=\"%s\" "

            // Audio branch
            SGTP_AUDIO_SRC " "
            "! audioconvert "
            "! audioresample "
            "! audio/x-raw,rate=44100,channels=1 "
            "! " SGTP_AUDIO_ENC " bitrate=%d "
            "! mux.",

            dev_frag,
            preview_w, preview_h,
            target_size, target_size,
            video_kbps,
            norm_path,
            audio_kbps * 1000
        );
    }
}

// Stop and destroy the current pipeline (if any), leaving g_ctx intact.
static void destroy_pipeline(void) {
    if (!g_ctx || !g_ctx->pipeline) return;

    // Detach appsink callback so it doesn't fire during teardown
    if (g_ctx->preview_sink) {
        GstAppSinkCallbacks no_cbs = {0};
        gst_app_sink_set_callbacks(
            GST_APP_SINK(g_ctx->preview_sink), &no_cbs, NULL, NULL);
        g_ctx->preview_sink = NULL;
    }

    gst_element_set_state(g_ctx->pipeline, GST_STATE_NULL);
    gst_object_unref(g_ctx->pipeline);
    g_ctx->pipeline = NULL;
}

// Build, configure and start a new pipeline.
// Returns 0 on success.
static int start_pipeline(
    const char *output_path,
    int target_size, int video_kbps, int audio_kbps)
{
    gchar *desc = build_pipeline_desc(
        g_ctx->device_id,
        g_ctx->preview_width, g_ctx->preview_height,
        output_path,
        target_size, video_kbps, audio_kbps);

    GError    *err = NULL;
    GstElement *pipeline = gst_parse_launch(desc, &err);
    g_free(desc);

    if (!pipeline || err) {
        char buf[512];
        snprintf(buf, sizeof(buf), "gst_parse_launch failed: %s",
                 err ? err->message : "unknown");
        report_error(buf);
        g_clear_error(&err);
        if (pipeline) gst_object_unref(pipeline);
        return -1;
    }

    g_ctx->pipeline = pipeline;

    // Connect bus watch
    GstBus *bus = gst_element_get_bus(pipeline);
    gst_bus_add_watch(bus, bus_watch, NULL);
    gst_object_unref(bus);

    // Connect appsink
    GstElement *sink = gst_bin_get_by_name(GST_BIN(pipeline), "preview_sink");
    if (sink) {
        GstAppSinkCallbacks cbs = {
            .new_sample = on_new_sample,
        };
        gst_app_sink_set_callbacks(GST_APP_SINK(sink), &cbs, NULL, NULL);
        g_ctx->preview_sink = sink;
        gst_object_unref(sink);  // bin still holds a ref
    }

    GstStateChangeReturn ret = gst_element_set_state(pipeline, GST_STATE_PLAYING);
    if (ret == GST_STATE_CHANGE_FAILURE) {
        report_error("Failed to set pipeline to PLAYING");
        destroy_pipeline();
        return -1;
    }

    return 0;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

SGTP_CAM_EXPORT void sgtp_camera_init(void) {
#if defined(__APPLE__) && TARGET_OS_IOS
    gst_ios_init();
#endif
#if defined(_WIN32)
    ensure_gstreamer_windows_env();
#endif
    gst_init(NULL, NULL);

    g_ctx = (SgtpCtx *)calloc(1, sizeof(SgtpCtx));

    g_ctx->loop = g_main_loop_new(NULL, FALSE);
    g_ctx->loop_thread = g_thread_new("sgtp_gst_loop", loop_thread_func, g_ctx->loop);
}

SGTP_CAM_EXPORT void sgtp_camera_deinit(void) {
    if (!g_ctx) return;

    if (g_ctx->is_recording) {
        sgtp_camera_stop_recording();
    }
    sgtp_camera_close();

    if (g_ctx->loop) {
        g_main_loop_quit(g_ctx->loop);
        g_thread_join(g_ctx->loop_thread);
        g_main_loop_unref(g_ctx->loop);
    }

    free(g_ctx);
    g_ctx = NULL;
}

SGTP_CAM_EXPORT int32_t sgtp_camera_enumerate(
    SgtpDeviceInfo *devices, int32_t max_devices)
{
    GstDeviceMonitor *monitor = gst_device_monitor_new();
    gst_device_monitor_add_filter(monitor, "Video/Source", NULL);

    GList *list = gst_device_monitor_get_devices(monitor);
    int32_t count = 0;

    for (GList *l = list; l != NULL && count < max_devices; l = l->next) {
        GstDevice *dev = GST_DEVICE(l->data);

        gchar *display = gst_device_get_display_name(dev);

        char id_buf[256] = "";
#if defined(__linux__) && !defined(__ANDROID__)
        // Linux/v4l2src: use device path (e.g. /dev/video0)
        GstStructure *props = gst_device_get_properties(dev);
        const gchar *dev_path = props ? gst_structure_get_string(props, "device.path") : NULL;
        if (dev_path && dev_path[0]) {
            strncpy(id_buf, dev_path, 255);
        } else {
            snprintf(id_buf, sizeof(id_buf), "%d", count);
        }
        if (props) gst_structure_free(props);
#else
        // Windows (ksvideosrc device-index=N) / macOS / Android / iOS:
        // use the enumeration order as the integer device index.
        snprintf(id_buf, sizeof(id_buf), "%d", count);
#endif

        if (devices) {
            strncpy(devices[count].display_name,
                    display ? display : "", 255);
            strncpy(devices[count].id, id_buf, 255);
        }

        g_free(display);
        gst_object_unref(dev);
        count++;
    }

    g_list_free(list);
    gst_object_unref(monitor);
    return count;
}

SGTP_CAM_EXPORT int32_t sgtp_camera_open(
    const char        *device_id,
    int32_t            preview_width,
    int32_t            preview_height,
    SgtpFrameCallback  on_frame,
    SgtpErrorCallback  on_error)
{
    if (!g_ctx) return -1;
    if (g_ctx->pipeline) return -1;  // already open

    g_ctx->frame_cb = on_frame;
    g_ctx->error_cb = on_error;
    g_ctx->preview_width  = preview_width  > 0 ? preview_width  : 480;
    g_ctx->preview_height = preview_height > 0 ? preview_height : 480;

    if (device_id && device_id[0] != '\0') {
        strncpy(g_ctx->device_id, device_id, 255);
    } else {
        g_ctx->device_id[0] = '\0';
    }

    return start_pipeline(NULL, 480, 1000, 64);
}

SGTP_CAM_EXPORT void sgtp_camera_close(void) {
    if (!g_ctx) return;
    destroy_pipeline();
    g_ctx->frame_cb = NULL;
    g_ctx->error_cb = NULL;
    g_ctx->is_recording = FALSE;
}

SGTP_CAM_EXPORT int32_t sgtp_camera_start_recording(
    const char *output_path,
    int32_t     target_size,
    int32_t     video_kbps,
    int32_t     audio_kbps)
{
    if (!g_ctx || !output_path) return -1;
    if (g_ctx->is_recording) return -1;

    // Stop preview-only pipeline, rebuild with recording branch.
    destroy_pipeline();

    if (target_size <= 0) target_size = 480;
    if (video_kbps  <= 0) video_kbps  = 1000;
    if (audio_kbps  <= 0) audio_kbps  = 64;

    int rc = start_pipeline(output_path, target_size, video_kbps, audio_kbps);
    if (rc != 0) {
        // Fall back to preview-only so the camera is still usable.
        start_pipeline(NULL, 480, 1000, 64);
        return rc;
    }

    g_ctx->is_recording = TRUE;
    g_ctx->record_start_time = gst_clock_get_time(
        gst_element_get_clock(g_ctx->pipeline));

    return 0;
}

SGTP_CAM_EXPORT int64_t sgtp_camera_stop_recording(void) {
    if (!g_ctx || !g_ctx->is_recording) return 0;

    // Calculate duration before sending EOS.
    int64_t duration_ms = 0;
    if (g_ctx->pipeline) {
        GstClock *clk = gst_element_get_clock(g_ctx->pipeline);
        if (clk) {
            GstClockTime now = gst_clock_get_time(clk);
            if (now > g_ctx->record_start_time) {
                duration_ms = (int64_t)(
                    (now - g_ctx->record_start_time) / GST_MSECOND);
            }
            gst_object_unref(clk);
        }
    }

    // Send EOS so mp4mux finalises the file properly.
    if (g_ctx->pipeline) {
        gst_element_send_event(g_ctx->pipeline, gst_event_new_eos());

        // Wait up to 5 s for EOS to propagate.
        GstBus *bus = gst_element_get_bus(g_ctx->pipeline);
        GstMessage *msg = gst_bus_timed_pop_filtered(
            bus,
            5 * GST_SECOND,
            GST_MESSAGE_EOS | GST_MESSAGE_ERROR);
        if (msg) gst_message_unref(msg);
        gst_object_unref(bus);
    }

    g_ctx->is_recording = FALSE;

    // Rebuild preview-only pipeline.
    destroy_pipeline();
    start_pipeline(NULL, 480, 1000, 64);

    return duration_ms;
}

SGTP_CAM_EXPORT int32_t sgtp_camera_is_recording(void) {
    return (g_ctx && g_ctx->is_recording) ? 1 : 0;
}
