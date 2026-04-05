cmake_minimum_required(VERSION 3.10)
set(PROJECT_NAME "sgtp_camera")
project(${PROJECT_NAME} LANGUAGES C)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src"
                 "${CMAKE_CURRENT_BINARY_DIR}/shared")

set(sgtp_camera_bundled_libraries
  $<TARGET_FILE:sgtp_camera>
  PARENT_SCOPE
)
