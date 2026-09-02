cmake_minimum_required(VERSION 3.14)

project(firebase_core_plugin LANGUAGES CXX)

set(PLUGIN_NAME "firebase_core_plugin")

add_library(${PLUGIN_NAME} STATIC
  "include/firebase_core/firebase_core_plugin_c_api.h"
  "firebase_core_stub.cpp"
)

apply_standard_settings(${PLUGIN_NAME})

target_compile_definitions(${PLUGIN_NAME} PUBLIC FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

target_link_libraries(${PLUGIN_NAME} PUBLIC flutter flutter_wrapper_plugin)

set(firebase_core_bundled_libraries "" PARENT_SCOPE)
