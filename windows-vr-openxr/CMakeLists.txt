cmake_minimum_required(VERSION 3.25)
project(WindowsVROpenXRRuntime LANGUAGES CXX)

if(NOT WIN32)
    message(FATAL_ERROR "The guest OpenXR runtime DLL must target Windows.")
endif()
if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(FATAL_ERROR "This package stage is x64-only; ARM64EC uses a separate guest root.")
endif()
if(CMAKE_GENERATOR_PLATFORM AND NOT CMAKE_GENERATOR_PLATFORM STREQUAL "x64")
    message(FATAL_ERROR "This package stage is x64-only; use the x64 generator platform. ARM64EC gets a separate guest root later.")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(OPENXR_SDK_SOURCE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../third-party/openxr" CACHE PATH
    "Pinned Khronos OpenXR-SDK source tree containing include/openxr")
set(WINDOWS_VR_GUEST_STAGE "${CMAKE_BINARY_DIR}/stage/WindowsVR/Guest/x64" CACHE PATH
    "Guest package root shared with OpenComposite and stage_resources.py --guest-stage")

if(NOT EXISTS "${OPENXR_SDK_SOURCE_ROOT}/include/openxr/openxr.h")
    message(FATAL_ERROR "OpenXR headers are missing at ${OPENXR_SDK_SOURCE_ROOT}/include/openxr")
endif()

add_library(wvr_openxr SHARED src/WindowsVROpenXR.cpp)
target_include_directories(wvr_openxr PRIVATE
    "${OPENXR_SDK_SOURCE_ROOT}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
)
target_compile_definitions(wvr_openxr PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(wvr_openxr PRIVATE d3d11 dxgi)
# D3D12CreateDevice is resolved dynamically; D3D11-only packages remain loadable.
set_target_properties(wvr_openxr PROPERTIES
    PREFIX ""
    OUTPUT_NAME "wvr_openxr"
    RUNTIME_OUTPUT_DIRECTORY "${WINDOWS_VR_GUEST_STAGE}"
    LIBRARY_OUTPUT_DIRECTORY "${WINDOWS_VR_GUEST_STAGE}"
    WINDOWS_EXPORT_ALL_SYMBOLS OFF
    RUNTIME_OUTPUT_DIRECTORY_RELEASE "${WINDOWS_VR_GUEST_STAGE}"
    LIBRARY_OUTPUT_DIRECTORY_RELEASE "${WINDOWS_VR_GUEST_STAGE}"
    RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO "${WINDOWS_VR_GUEST_STAGE}"
    LIBRARY_OUTPUT_DIRECTORY_RELWITHDEBINFO "${WINDOWS_VR_GUEST_STAGE}"
    RUNTIME_OUTPUT_DIRECTORY_DEBUG "${WINDOWS_VR_GUEST_STAGE}"
    LIBRARY_OUTPUT_DIRECTORY_DEBUG "${WINDOWS_VR_GUEST_STAGE}"
)

if(MSVC)
    target_compile_options(wvr_openxr PRIVATE /W4 /permissive- /EHsc)
elseif(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    # The DXMT COM extension uses __declspec(uuid) and __uuidof. LLVM-MinGW's
    # clang++ supports these Microsoft extensions while targeting MinGW-w64.
    target_compile_options(wvr_openxr PRIVATE -Wall -Wextra -Wpedantic -fms-extensions)
endif()
