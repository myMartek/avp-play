# Cross-compile the guest DLL from macOS with an extracted llvm-mingw bundle.
# Pass -DLLVM_MINGW_ROOT=/absolute/path/to/llvm-mingw-... when configuring.
set(LLVM_MINGW_ROOT "" CACHE PATH "Root of the extracted llvm-mingw toolchain")
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES LLVM_MINGW_ROOT)
if(NOT LLVM_MINGW_ROOT)
    message(FATAL_ERROR "Set LLVM_MINGW_ROOT to an extracted llvm-mingw macOS bundle.")
endif()

set(_llvm_mingw_bin "${LLVM_MINGW_ROOT}/bin")
set(_llvm_mingw_triple "x86_64-w64-mingw32")
foreach(_tool clang clang++)
    if(NOT EXISTS "${_llvm_mingw_bin}/${_llvm_mingw_triple}-${_tool}")
        message(FATAL_ERROR "Missing llvm-mingw compiler: ${_llvm_mingw_bin}/${_llvm_mingw_triple}-${_tool}")
    endif()
endforeach()
if(NOT EXISTS "${_llvm_mingw_bin}/llvm-rc")
    message(FATAL_ERROR "Missing llvm-rc in ${_llvm_mingw_bin}")
endif()

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR AMD64)
set(CMAKE_C_COMPILER "${_llvm_mingw_bin}/${_llvm_mingw_triple}-clang")
set(CMAKE_CXX_COMPILER "${_llvm_mingw_bin}/${_llvm_mingw_triple}-clang++")
set(CMAKE_RC_COMPILER "${_llvm_mingw_bin}/llvm-rc")
set(CMAKE_AR "${_llvm_mingw_bin}/${_llvm_mingw_triple}-llvm-ar")
set(CMAKE_RANLIB "${_llvm_mingw_bin}/${_llvm_mingw_triple}-llvm-ranlib")

# Keep host tools (such as Python and Git) discoverable while all target
# headers, libraries, and packages come from the MinGW sysroot.
set(CMAKE_FIND_ROOT_PATH "${LLVM_MINGW_ROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
