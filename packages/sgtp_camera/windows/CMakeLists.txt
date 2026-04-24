cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "sgtp_camera")
project(${PROJECT_NAME} LANGUAGES C)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src"
                 "${CMAKE_CURRENT_BINARY_DIR}/shared")

set(_sgtp_camera_windows_bundled_libraries
  $<TARGET_FILE:sgtp_camera>
)

foreach(_bundled_file IN LISTS SGTP_CAMERA_WINDOWS_BUNDLED_FILES)
  file(TO_CMAKE_PATH "${_bundled_file}" _bundled_file_normalized)
  list(APPEND _sgtp_camera_windows_bundled_libraries
    "${_bundled_file_normalized}"
  )
endforeach()

# Tell Flutter to bundle the built DLL next to the executable.
set(sgtp_camera_bundled_libraries
  ${_sgtp_camera_windows_bundled_libraries}
  PARENT_SCOPE
)
