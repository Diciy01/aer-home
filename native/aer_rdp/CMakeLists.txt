# aer_rdp: thin C layer over FreeRDP 3 for the built-in AER Remote viewer.
cmake_minimum_required(VERSION 3.16)
project(aer_rdp C)

if(MSVC)
  cmake_policy(GET CMP0091 AER_CRT_POLICY)
  if(NOT AER_CRT_POLICY STREQUAL "NEW" OR NOT CMAKE_MSVC_RUNTIME_LIBRARY_DEFAULT)
    message(FATAL_ERROR "Enable CMP0091 NEW before the top-level project(): aer_rdp requires an explicit CRT")
  endif()
  # Old Flutter caches can retain /MDd from CMP0091 OLD. Override only
  # CRT flags in this C subdirectory; leave cache/runner/plugins intact.
  foreach(AER_FLAGS CMAKE_C_FLAGS CMAKE_C_FLAGS_DEBUG CMAKE_C_FLAGS_RELEASE
                    CMAKE_C_FLAGS_PROFILE CMAKE_C_FLAGS_RELWITHDEBINFO CMAKE_C_FLAGS_MINSIZEREL)
    string(REGEX REPLACE "(^| )[/-]M[DT]d?( |$)" "\\1\\2" ${AER_FLAGS} "${${AER_FLAGS}}")
  endforeach()
endif()

add_library(aer_rdp SHARED aer_rdp.c)
set_target_properties(aer_rdp PROPERTIES C_STANDARD 11 C_VISIBILITY_PRESET hidden)

if(WIN32)
  # Windows (M10): FreeRDP's own CMake packages, e.g. vcpkg
  # freerdp[client]:x64-windows; CMAKE_PREFIX_PATH points at the prefix.
  find_package(WinPR 3.5 CONFIG REQUIRED)
  find_package(FreeRDP 3.5 CONFIG REQUIRED)
  find_package(FreeRDP-Client 3.5 CONFIG REQUIRED)
  target_link_libraries(aer_rdp PRIVATE freerdp-client freerdp winpr)
  # Release FreeRDP and CRT in every Flutter mode (Debug/Profile too): one
  # set of DLLs next to the exe, no debug/release CRT mix across the API.
  set_target_properties(freerdp-client freerdp winpr PROPERTIES
    MAP_IMPORTED_CONFIG_DEBUG Release MAP_IMPORTED_CONFIG_PROFILE Release)
  set_target_properties(aer_rdp PROPERTIES MSVC_RUNTIME_LIBRARY MultiThreadedDLL)
  target_compile_definitions(aer_rdp PRIVATE _CRT_SECURE_NO_WARNINGS)
  target_compile_options(aer_rdp PRIVATE /W3 /we4013) # C4013: undeclared function
  if(MSVC)
    get_filename_component(AER_MSVC_BIN "${CMAKE_LINKER}" DIRECTORY)
    find_program(AER_DUMPBIN NAMES dumpbin HINTS "${AER_MSVC_BIN}" REQUIRED)
    add_custom_command(TARGET aer_rdp POST_BUILD
      COMMAND "${CMAKE_COMMAND}" "-DAER_DUMPBIN=${AER_DUMPBIN}"
        "-DAER_DLL=$<TARGET_FILE:aer_rdp>" -P "${CMAKE_CURRENT_SOURCE_DIR}/check_crt.cmake"
      VERBATIM)
  endif()
else()
  find_package(PkgConfig REQUIRED)
  pkg_check_modules(FREERDP REQUIRED IMPORTED_TARGET freerdp3>=3.5 freerdp-client3>=3.5 winpr3>=3.5)
  target_link_libraries(aer_rdp PRIVATE PkgConfig::FREERDP)
  target_compile_options(aer_rdp PRIVATE -Wall -Wextra -Werror=implicit-function-declaration)
endif()

option(AER_RDP_BUILD_TESTS "Build isolated native allocator regression" OFF)
if(AER_RDP_BUILD_TESTS AND WIN32)
  enable_testing()
  add_executable(aer_rdp_clipboard_alloc_test tests/clipboard_alloc_test.c)
  target_link_libraries(aer_rdp_clipboard_alloc_test PRIVATE freerdp-client freerdp winpr)
  target_compile_definitions(aer_rdp_clipboard_alloc_test PRIVATE _CRT_SECURE_NO_WARNINGS)
  # Deliberate Debug CRT/Release WinPR boundary. The test must remain safe
  # even when allocators differ; the shipping bridge uses Release CRT.
  set_target_properties(aer_rdp_clipboard_alloc_test PROPERTIES MSVC_RUNTIME_LIBRARY MultiThreadedDebugDLL)
  add_test(NAME clipboard_allocator COMMAND aer_rdp_clipboard_alloc_test)
endif()

if(PROJECT_IS_TOP_LEVEL)
  install(TARGETS aer_rdp LIBRARY DESTINATION lib RUNTIME DESTINATION bin)
endif()
