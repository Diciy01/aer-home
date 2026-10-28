# aer_rdp: thin C layer over FreeRDP 3 for the built-in AER Remote viewer.
cmake_minimum_required(VERSION 3.16)
project(aer_rdp C)

find_package(PkgConfig REQUIRED)
pkg_check_modules(FREERDP REQUIRED IMPORTED_TARGET freerdp3>=3.5 freerdp-client3>=3.5 winpr3>=3.5)

add_library(aer_rdp SHARED aer_rdp.c)
target_link_libraries(aer_rdp PRIVATE PkgConfig::FREERDP)
set_target_properties(aer_rdp PROPERTIES C_STANDARD 11 C_VISIBILITY_PRESET hidden)
target_compile_options(aer_rdp PRIVATE -Wall -Wextra -Werror=implicit-function-declaration)
if(PROJECT_IS_TOP_LEVEL)
  install(TARGETS aer_rdp LIBRARY DESTINATION lib)
endif()
