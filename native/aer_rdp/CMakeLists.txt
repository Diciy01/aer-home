# aer_rdp: thin C layer over FreeRDP 3 for the built-in AER Remote viewer.
cmake_minimum_required(VERSION 3.16)
project(aer_rdp C)

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
else()
  find_package(PkgConfig REQUIRED)
  pkg_check_modules(FREERDP REQUIRED IMPORTED_TARGET freerdp3>=3.5 freerdp-client3>=3.5 winpr3>=3.5)
  target_link_libraries(aer_rdp PRIVATE PkgConfig::FREERDP)
  target_compile_options(aer_rdp PRIVATE -Wall -Wextra -Werror=implicit-function-declaration)
endif()

if(PROJECT_IS_TOP_LEVEL)
  install(TARGETS aer_rdp LIBRARY DESTINATION lib RUNTIME DESTINATION bin)
endif()
