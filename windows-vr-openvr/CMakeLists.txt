cmake_minimum_required(VERSION 3.25)
project(WindowsVROpenCompositeBundle LANGUAGES C CXX)

# This is packaging orchestration only. It consumes upstream OpenComposite as
# a pinned source dependency and never implements OpenVR interface vtables here.
set(OPENCOMPOSITE_COMMIT "cff07db75c4823afe93ed7027b03d5f7bc86f164")
set(OPENCOMPOSITE_STAGE_ROOT "${CMAKE_BINARY_DIR}/stage" CACHE PATH
    "Shared package stage root for WindowsVR guest artifacts")
set(OPENCOMPOSITE_SOURCE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../third-party/opencomposite" CACHE PATH
    "Existing pinned OpenComposite checkout used by local-source builds")
set(OPENCOMPOSITE_FETCH_SOURCE_ROOT "${CMAKE_BINARY_DIR}/_deps/opencomposite-src")
set(OPENCOMPOSITE_OVERLAY_SOURCE_ROOT "${CMAKE_BINARY_DIR}/_deps/opencomposite-cross-src")
option(WINDOWS_VR_BUILD_ARM64EC "Also package an ARM64EC OpenComposite guest" OFF)
option(WINDOWS_VR_USE_LLVM_MINGW "Cross-build the x64 guest package from macOS with llvm-mingw" OFF)
set(LLVM_MINGW_ROOT "" CACHE PATH "Root of the extracted llvm-mingw macOS bundle")

if(WINDOWS_VR_USE_LLVM_MINGW)
    if(NOT CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
        message(FATAL_ERROR "WINDOWS_VR_USE_LLVM_MINGW is the macOS-hosted cross-build path.")
    endif()
    if(WINDOWS_VR_BUILD_ARM64EC)
        message(FATAL_ERROR "The llvm-mingw package path currently stages x64 only; ARM64EC remains a separate Visual Studio build.")
    endif()
    set(LLVM_MINGW_TOOLCHAIN_FILE
        "${CMAKE_CURRENT_SOURCE_DIR}/../windows-vr-openxr/cmake/toolchains/llvm-mingw-x64.cmake")
    if(NOT EXISTS "${LLVM_MINGW_TOOLCHAIN_FILE}")
        message(FATAL_ERROR "Missing llvm-mingw toolchain file: ${LLVM_MINGW_TOOLCHAIN_FILE}")
    endif()
    if(NOT LLVM_MINGW_ROOT OR NOT EXISTS "${LLVM_MINGW_ROOT}/bin/x86_64-w64-mingw32-clang++")
        message(FATAL_ERROR "Set LLVM_MINGW_ROOT to the extracted macOS llvm-mingw bundle.")
    endif()
    if(NOT EXISTS "${OPENCOMPOSITE_SOURCE_ROOT}/CMakeLists.txt")
        message(FATAL_ERROR "Initialize the pinned OpenComposite checkout at OPENCOMPOSITE_SOURCE_ROOT before using the cross-build path.")
    endif()
    execute_process(
        COMMAND git -C "${OPENCOMPOSITE_SOURCE_ROOT}" rev-parse HEAD
        RESULT_VARIABLE OPENCOMPOSITE_GIT_RESULT
        OUTPUT_VARIABLE OPENCOMPOSITE_SOURCE_COMMIT
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )
    if(NOT OPENCOMPOSITE_GIT_RESULT EQUAL 0 OR NOT OPENCOMPOSITE_SOURCE_COMMIT STREQUAL OPENCOMPOSITE_COMMIT)
        message(FATAL_ERROR "OPENCOMPOSITE_SOURCE_ROOT must be at pinned commit ${OPENCOMPOSITE_COMMIT} for cross-builds.")
    endif()
    foreach(_required_file
        "${OPENCOMPOSITE_SOURCE_ROOT}/libs/glm/CMakeLists.txt"
        "${OPENCOMPOSITE_SOURCE_ROOT}/libs/openxr-sdk/CMakeLists.txt")
        if(NOT EXISTS "${_required_file}")
            message(FATAL_ERROR "Missing OpenComposite dependency ${_required_file}; initialize the pinned source submodules first.")
        endif()
    endforeach()
    find_package(Git REQUIRED)
    set(OPENCOMPOSITE_D3D11_OVERLAY
        "${CMAKE_CURRENT_SOURCE_DIR}/patches/0001-d3d11-only-openxr-build.patch")
    if(NOT EXISTS "${OPENCOMPOSITE_D3D11_OVERLAY}")
        message(FATAL_ERROR "Missing project-owned OpenComposite overlay patch: ${OPENCOMPOSITE_D3D11_OVERLAY}")
    endif()
    set(OPENCOMPOSITE_CROSS_CMAKE_ARGS
        "-DCMAKE_TOOLCHAIN_FILE=${LLVM_MINGW_TOOLCHAIN_FILE}"
        "-DLLVM_MINGW_ROOT=${LLVM_MINGW_ROOT}"
    )
else()
    if(NOT WIN32 OR NOT MSVC)
        message(FATAL_ERROR "Use MSVC on Windows, or enable WINDOWS_VR_USE_LLVM_MINGW with an extracted macOS bundle.")
    endif()
    set(OPENCOMPOSITE_CROSS_CMAKE_ARGS)
endif()

include(ExternalProject)

set(OPENCOMPOSITE_REPOSITORY "https://gitlab.com/znixian/OpenOVR.git")

function(add_opencomposite_variant variant platform)
    set(_generator_platform_args)
    if(NOT WINDOWS_VR_USE_LLVM_MINGW)
        list(APPEND _generator_platform_args CMAKE_GENERATOR_PLATFORM "${platform}")
    endif()

    if(WINDOWS_VR_USE_LLVM_MINGW)
        ExternalProject_Add("OpenComposite_${variant}"
            SOURCE_DIR "${OPENCOMPOSITE_OVERLAY_SOURCE_ROOT}"
            BINARY_DIR "${CMAKE_BINARY_DIR}/build/${variant}"
            CMAKE_GENERATOR "${CMAKE_GENERATOR}"
            ${_generator_platform_args}
            DOWNLOAD_COMMAND "${CMAKE_COMMAND}" -E copy_directory "${OPENCOMPOSITE_SOURCE_ROOT}" <SOURCE_DIR>
            UPDATE_COMMAND ""
            PATCH_COMMAND "${GIT_EXECUTABLE}" -C <SOURCE_DIR> apply --whitespace=nowarn "${OPENCOMPOSITE_D3D11_OVERLAY}"
            CMAKE_ARGS
                "-DCMAKE_INSTALL_PREFIX=${OPENCOMPOSITE_STAGE_ROOT}/WindowsVR/Guest/${variant}"
                "-DERROR_ON_WARNING=OFF"
                "-DOC_BACKTRACE=OFF"
                "-DWINDOWS_VR_D3D11_ONLY=ON"
                ${OPENCOMPOSITE_CROSS_CMAKE_ARGS}
            BUILD_COMMAND "${CMAKE_COMMAND}" --build <BINARY_DIR> --config Release
            INSTALL_COMMAND "${CMAKE_COMMAND}" --install <BINARY_DIR> --config Release
            USES_TERMINAL_CONFIGURE TRUE
            USES_TERMINAL_BUILD TRUE
            USES_TERMINAL_INSTALL TRUE
        )
    else()
    ExternalProject_Add("OpenComposite_${variant}"
        GIT_REPOSITORY "${OPENCOMPOSITE_REPOSITORY}"
        GIT_TAG "${OPENCOMPOSITE_COMMIT}"
        GIT_SHALLOW FALSE
        GIT_SUBMODULES_RECURSE TRUE
        SOURCE_DIR "${OPENCOMPOSITE_FETCH_SOURCE_ROOT}/${variant}"
        BINARY_DIR "${CMAKE_BINARY_DIR}/build/${variant}"
        CMAKE_GENERATOR "${CMAKE_GENERATOR}"
        ${_generator_platform_args}
        CMAKE_ARGS
            "-DCMAKE_INSTALL_PREFIX=${OPENCOMPOSITE_STAGE_ROOT}/WindowsVR/Guest/${variant}"
            "-DERROR_ON_WARNING=ON"
            "-DOC_BACKTRACE=OFF"
        BUILD_COMMAND "${CMAKE_COMMAND}" --build <BINARY_DIR> --config Release
        INSTALL_COMMAND "${CMAKE_COMMAND}" --install <BINARY_DIR> --config Release
        UPDATE_DISCONNECTED TRUE
        USES_TERMINAL_CONFIGURE TRUE
        USES_TERMINAL_BUILD TRUE
        USES_TERMINAL_INSTALL TRUE
    )
    endif()
endfunction()

# OpenComposite's 64-bit output name is vrclient_x64.dll for both targets.
# Keep the architecture-specific roots separate; the Wine launcher chooses one
# root from the guest executable's PE Machine field before creating the guest.
add_opencomposite_variant(x64 x64)
set(OPENCOMPOSITE_PACKAGE_DEPENDENCIES OpenComposite_x64)
if(WINDOWS_VR_BUILD_ARM64EC)
    add_opencomposite_variant(arm64ec ARM64EC)
    list(APPEND OPENCOMPOSITE_PACKAGE_DEPENDENCIES OpenComposite_arm64ec)
endif()

add_custom_target(package_opencomposite
    DEPENDS ${OPENCOMPOSITE_PACKAGE_DEPENDENCIES}
    COMMENT "Stage pinned OpenComposite guest runtime trees"
)
