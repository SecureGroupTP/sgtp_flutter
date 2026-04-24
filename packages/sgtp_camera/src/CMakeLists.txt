cmake_minimum_required(VERSION 3.14)
project(sgtp_camera_library VERSION 0.1.0 LANGUAGES C)

set(SGTP_CAMERA_SOURCES)

# ---------------------------------------------------------------------------
# Find GStreamer
# ---------------------------------------------------------------------------

if(ANDROID OR __ANDROID__)
  # ---- Android: bundled GStreamer headers ----
  set(GST_ANDROID_ROOT "$ENV{SGTP_GST_ANDROID_ROOT}")
  if(NOT GST_ANDROID_ROOT)
    set(GST_ANDROID_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../third-party/gst-android")
  endif()
  set(ABI_SUFFIX "${ANDROID_ABI}")
  if("${ANDROID_ABI}" STREQUAL "armeabi-v7a")
    set(ABI_SUFFIX "armv7")
  elseif("${ANDROID_ABI}" STREQUAL "arm64-v8a")
    set(ABI_SUFFIX "arm64")
  endif()
  set(GST_ROOT "${GST_ANDROID_ROOT}/${ABI_SUFFIX}")
  if(EXISTS "${GST_ROOT}/include/gstreamer-1.0/gst/gst.h")
    set(SGTP_CAMERA_USE_GST_ANDROID ON)
    list(APPEND SGTP_CAMERA_SOURCES sgtp_camera.c)

    set(GST_INCLUDE_DIRS
      "${GST_ROOT}/include/gstreamer-1.0"
      "${GST_ROOT}/include/glib-2.0"
      "${GST_ROOT}/lib/glib-2.0/include"
    )
    link_directories("${GST_ROOT}/lib" "${GST_ROOT}/lib/gstreamer-1.0")

    set(ANDROID_PLUGINS
      coreelements adder app audioconvert audiorate audiotestsrc
      autodetect opensles ahc videoscale videoconvert videocrop
      videorate v4l2 x264 voaacenc matroska isomp4 aspectratiocrop
    )
    foreach(P ${ANDROID_PLUGINS})
      list(APPEND EXTRA_LINK_LIBS "gst${P}")
      string(APPEND PLUGINS_DECLARATION "\nGST_PLUGIN_STATIC_DECLARE(${P});")
      string(APPEND PLUGINS_REGISTRATION "\nGST_PLUGIN_STATIC_REGISTER(${P});")
    endforeach()
    configure_file(
      "${CMAKE_CURRENT_SOURCE_DIR}/gst_plugin_init_android.c.in"
      "${CMAKE_CURRENT_SOURCE_DIR}/gst_plugin_init_android.c"
    )
    list(APPEND EXTRA_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/gst_plugin_init_android.c")
    list(APPEND EXTRA_LINK_LIBS
      intl ffi iconv gmodule-2.0 pcre2-8
      gstbase-1.0 gstvideo-1.0 gstaudio-1.0 gstapp-1.0
      orc-0.4 gio-2.0 glib-2.0 gobject-2.0
      log z OpenSLES
    )
  else()
    message(WARNING
      "Android GStreamer bundle not found under ${GST_ROOT}. "
      "Building sgtp_camera Android stub (camera disabled on Android).")
    list(APPEND SGTP_CAMERA_SOURCES sgtp_camera_stub.c)
  endif()

elseif(WIN32)
  # ---- Windows: use GSTREAMER_1_0_ROOT_MSVC_X86_64 env var ----
  # The official GStreamer installer always sets this variable.
  list(APPEND SGTP_CAMERA_SOURCES sgtp_camera.c)
  set(GST_WIN_ROOT "$ENV{GSTREAMER_1_0_ROOT_MSVC_X86_64}")
  if(GST_WIN_ROOT)
    file(TO_CMAKE_PATH "${GST_WIN_ROOT}" GST_WIN_ROOT)
  endif()
  if(NOT GST_WIN_ROOT)
    # Common fallback paths
    foreach(_p
        "C:/gstreamer/1.0/msvc_x86_64"
        "C:/Program Files/gstreamer/1.0/msvc_x86_64"
        "C:/Program Files (x86)/gstreamer/1.0/msvc_x86_64")
      if(EXISTS "${_p}/include/gstreamer-1.0/gst/gst.h")
        set(GST_WIN_ROOT "${_p}")
        break()
      endif()
    endforeach()
  endif()

  if(NOT GST_WIN_ROOT OR NOT EXISTS "${GST_WIN_ROOT}")
    message(FATAL_ERROR
      "GStreamer not found. Install it from https://gstreamer.freedesktop.org/download/ "
      "(both Runtime and Development packages) or set GSTREAMER_1_0_ROOT_MSVC_X86_64.")
  endif()

  message(STATUS "GStreamer root: ${GST_WIN_ROOT}")

  set(GST_INCLUDE_DIRS
    "${GST_WIN_ROOT}/include/gstreamer-1.0"
    "${GST_WIN_ROOT}/include/glib-2.0"
    "${GST_WIN_ROOT}/lib/glib-2.0/include"
  )

  foreach(_lib
      gstreamer-1.0 gstbase-1.0 gstapp-1.0
      gstvideo-1.0  gstaudio-1.0
      glib-2.0 gobject-2.0 gmodule-2.0 gio-2.0)
    find_library(_found_${_lib} "${_lib}"
      PATHS "${GST_WIN_ROOT}/lib" NO_DEFAULT_PATH)
    if(_found_${_lib})
      list(APPEND GST_LIBRARIES "${_found_${_lib}}")
    else()
      message(WARNING "GStreamer: lib ${_lib} not found under ${GST_WIN_ROOT}/lib")
    endif()
  endforeach()

  file(GLOB SGTP_CAMERA_GST_RUNTIME_DLLS
    "${GST_WIN_ROOT}/bin/*.dll"
  )
  file(GLOB SGTP_CAMERA_GST_PLUGIN_DLLS
    "${GST_WIN_ROOT}/lib/gstreamer-1.0/*.dll"
  )

  set(SGTP_CAMERA_GST_PLUGIN_SCANNER
    "${GST_WIN_ROOT}/libexec/gstreamer-1.0/gst-plugin-scanner.exe"
  )
  if(EXISTS "${SGTP_CAMERA_GST_PLUGIN_SCANNER}")
    list(APPEND SGTP_CAMERA_WINDOWS_BUNDLED_FILES
      "${SGTP_CAMERA_GST_PLUGIN_SCANNER}"
    )
  endif()

  list(APPEND SGTP_CAMERA_WINDOWS_BUNDLED_FILES
    ${SGTP_CAMERA_GST_RUNTIME_DLLS}
    ${SGTP_CAMERA_GST_PLUGIN_DLLS}
  )

  list(REMOVE_DUPLICATES SGTP_CAMERA_WINDOWS_BUNDLED_FILES)
  list(FILTER SGTP_CAMERA_WINDOWS_BUNDLED_FILES INCLUDE REGEX ".+")
  set(_sgtp_camera_windows_bundled_files_normalized)
  foreach(_bundled_file IN LISTS SGTP_CAMERA_WINDOWS_BUNDLED_FILES)
    file(TO_CMAKE_PATH "${_bundled_file}" _bundled_file_normalized)
    list(APPEND _sgtp_camera_windows_bundled_files_normalized
      "${_bundled_file_normalized}"
    )
  endforeach()
  set(SGTP_CAMERA_WINDOWS_BUNDLED_FILES
    ${_sgtp_camera_windows_bundled_files_normalized}
    PARENT_SCOPE
  )

else()
  # ---- Linux / macOS / iOS: pkg-config ----
  list(APPEND SGTP_CAMERA_SOURCES sgtp_camera.c)
  find_package(PkgConfig REQUIRED)
  pkg_check_modules(GST REQUIRED
    gstreamer-1.0
    gstreamer-app-1.0
    gstreamer-video-1.0
    gstreamer-audio-1.0
  )
endif()

# ---------------------------------------------------------------------------
# iOS: additional init file
# ---------------------------------------------------------------------------
if(IOS)
  list(APPEND EXTRA_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/../ios/Classes/gst_ios_init.m")
  add_compile_definitions(IOS)
endif()

# ---------------------------------------------------------------------------
# Shared library
# ---------------------------------------------------------------------------
add_library(sgtp_camera SHARED
  ${SGTP_CAMERA_SOURCES}
  ${EXTRA_SOURCES}
)

target_compile_definitions(sgtp_camera PUBLIC DART_SHARED_LIB)

if(MSVC)
  target_compile_definitions(sgtp_camera PRIVATE _CRT_SECURE_NO_WARNINGS)
  target_compile_options(sgtp_camera PRIVATE /W3 /wd4013)
endif()

if(GST_INCLUDE_DIRS)
  target_include_directories(sgtp_camera PRIVATE ${GST_INCLUDE_DIRS})
endif()

if(ANDROID OR __ANDROID__)
  if(SGTP_CAMERA_USE_GST_ANDROID)
    target_link_libraries(sgtp_camera PRIVATE ${EXTRA_LINK_LIBS})
  endif()
elseif(WIN32)
  target_link_directories(sgtp_camera PRIVATE "${GST_WIN_ROOT}/lib")
  target_link_libraries(sgtp_camera PRIVATE ${GST_LIBRARIES})
else()
  # Linux / macOS / iOS
  target_link_directories(sgtp_camera PRIVATE ${GST_LIBRARY_DIRS})
  target_link_libraries(sgtp_camera PRIVATE ${GST_LIBRARIES})
endif()

set_target_properties(sgtp_camera PROPERTIES
  PUBLIC_HEADER sgtp_camera.h
  OUTPUT_NAME   "sgtp_camera"
)
