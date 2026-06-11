cmake_minimum_required(VERSION 3.16)
project(kano-cpp-infra VERSION 1.0.0 LANGUAGES C CXX)

include(GNUInstallDirs)
include(CMakePackageConfigHelpers)
include(FetchContent)

set(KANO_JSONCPP_SOURCE_MODE "fetch" CACHE STRING "jsoncpp source mode: fetch|system")
set_property(CACHE KANO_JSONCPP_SOURCE_MODE PROPERTY STRINGS fetch system)

if(KANO_JSONCPP_SOURCE_MODE STREQUAL "fetch")
    set(JSONCPP_WITH_TESTS OFF CACHE BOOL "" FORCE)
    set(JSONCPP_WITH_POST_BUILD_UNITTEST OFF CACHE BOOL "" FORCE)
    set(JSONCPP_WITH_WARNING_AS_ERROR OFF CACHE BOOL "" FORCE)
    set(JSONCPP_WITH_PKGCONFIG_SUPPORT OFF CACHE BOOL "" FORCE)
    FetchContent_Declare(
        jsoncpp
        GIT_REPOSITORY https://github.com/open-source-parsers/jsoncpp.git
        GIT_TAG 1.9.6
        GIT_SHALLOW TRUE
        GIT_PROGRESS TRUE
    )
    FetchContent_MakeAvailable(jsoncpp)
elseif(KANO_JSONCPP_SOURCE_MODE STREQUAL "system")
    find_package(jsoncpp CONFIG REQUIRED)
else()
    message(FATAL_ERROR "Unsupported KANO_JSONCPP_SOURCE_MODE: ${KANO_JSONCPP_SOURCE_MODE} (expected fetch|system)")
endif()

if(TARGET JsonCpp::JsonCpp)
    set(_jsoncpp_target JsonCpp::JsonCpp)
elseif(TARGET jsoncpp_static)
    set(_jsoncpp_target jsoncpp_static)
elseif(TARGET jsoncpp_lib)
    set(_jsoncpp_target jsoncpp_lib)
else()
    message(FATAL_ERROR "jsoncpp target not found after resolving KANO_JSONCPP_SOURCE_MODE=${KANO_JSONCPP_SOURCE_MODE}")
endif()

if(DEFINED jsoncpp_SOURCE_DIR)
    set(_jsoncpp_include_dir "${jsoncpp_SOURCE_DIR}/include")
else()
    set(_jsoncpp_include_dir "")
endif()

add_subdirectory(code/systems/kano_infra_config)
add_subdirectory(code/systems/kano_infra_build_info)
add_subdirectory(code/systems/kano_infra_platform)
add_subdirectory(code/systems/kano_infra_process)
add_subdirectory(code/systems/kano_infra_diagnostics)
add_subdirectory(code/systems/kano_infra_self)
add_subdirectory(code/systems/kano_infra_timing)
add_subdirectory(code/apps/kano_infra_tool)

add_library(kano_infra_all INTERFACE)
target_link_libraries(kano_infra_all INTERFACE
    KanoInfra::config
    KanoInfra::build_info
    KanoInfra::platform
    KanoInfra::process
    KanoInfra::diagnostics
    KanoInfra::self
    KanoInfra::timing
)
add_library(KanoInfra::All ALIAS kano_infra_all)

install(DIRECTORY code/systems/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR} FILES_MATCHING PATTERN "*.h")

install(TARGETS
    kano_infra_config
    kano_infra_build_info
    kano_infra_platform
    kano_infra_process
    kano_infra_diagnostics
    kano_infra_self
    kano_infra_timing
    kano_infra_all
    EXPORT KanoInfraTargets
)

install(EXPORT KanoInfraTargets
    FILE KanoInfraTargets.cmake
    NAMESPACE KanoInfra::
    DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/KanoInfra"
)

configure_package_config_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/scripts/cmake/KanoInfraConfig.cmake.in"
    "${CMAKE_CURRENT_BINARY_DIR}/KanoInfraConfig.cmake"
    INSTALL_DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/KanoInfra"
)

write_basic_package_version_file(
    "${CMAKE_CURRENT_BINARY_DIR}/KanoInfraConfigVersion.cmake"
    VERSION ${PROJECT_VERSION}
    COMPATIBILITY SameMajorVersion
)

install(FILES
    "${CMAKE_CURRENT_BINARY_DIR}/KanoInfraConfig.cmake"
    "${CMAKE_CURRENT_BINARY_DIR}/KanoInfraConfigVersion.cmake"
    DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/KanoInfra"
)

set(KANO_INFRA_VERSION "${PROJECT_VERSION}")
