cmake_minimum_required(VERSION 3.16)
project(kano-cpp-infra VERSION 1.0.0 LANGUAGES CXX)

# Public dependency policy: this is a header-only + PRIVATE-impl library
# Consumers link via KanoInfra::* targets defined below

include(GNUInstallDirs)
include(CMakePackageConfigHelpers)

# ---------------------------------------------------------------------------
# KanoInfra::config
# ---------------------------------------------------------------------------
add_library(kano_infra_config INTERFACE)
target_include_directories(kano_infra_config INTERFACE
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/PUBLIC/config>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
)
add_library(KanoInfra::config ALIAS kano_infra_config)

# ---------------------------------------------------------------------------
# KanoInfra::build_info
# ---------------------------------------------------------------------------
add_library(kano_infra_build_info INTERFACE)
target_include_directories(kano_infra_build_info INTERFACE
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/PUBLIC/build_info>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
)
add_library(KanoInfra::build_info ALIAS kano_infra_build_info)

# ---------------------------------------------------------------------------
# KanoInfra::platform
# ---------------------------------------------------------------------------
add_library(kano_infra_platform INTERFACE)
target_include_directories(kano_infra_platform INTERFACE
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/PUBLIC/platform>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
)
add_library(KanoInfra::platform ALIAS kano_infra_platform)

# ---------------------------------------------------------------------------
# KanoInfra::process
# ---------------------------------------------------------------------------
add_library(kano_infra_process INTERFACE)
target_include_directories(kano_infra_process INTERFACE
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/PUBLIC/process>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
)
add_library(KanoInfra::process ALIAS kano_infra_process)

# ---------------------------------------------------------------------------
# KanoInfra::diagnostics
# ---------------------------------------------------------------------------
add_library(kano_infra_diagnostics INTERFACE)
target_include_directories(kano_infra_diagnostics INTERFACE
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/PUBLIC/diagnostics>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
)
add_library(KanoInfra::diagnostics ALIAS kano_infra_diagnostics)

# ---------------------------------------------------------------------------
# KanoInfra::self
# ---------------------------------------------------------------------------
add_library(kano_infra_self INTERFACE)
target_include_directories(kano_infra_self INTERFACE
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/PUBLIC/self>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
)
add_library(KanoInfra::self ALIAS kano_infra_self)

# ---------------------------------------------------------------------------
# Convenience meta-target
# ---------------------------------------------------------------------------
add_library(kano_infra_all INTERFACE)
target_link_libraries(kano_infra_all INTERFACE
    KanoInfra::config
    KanoInfra::build_info
    KanoInfra::platform
    KanoInfra::process
    KanoInfra::diagnostics
    KanoInfra::self
)
add_library(KanoInfra::All ALIAS kano_infra_all)

# ---------------------------------------------------------------------------
# Install + export
# ---------------------------------------------------------------------------
install(
    DIRECTORY PUBLIC/
    DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
    FILES_MATCHING PATTERN "*.h"
)

install(TARGETS
    kano_infra_config
    kano_infra_build_info
    kano_infra_platform
    kano_infra_process
    kano_infra_diagnostics
    kano_infra_self
    kano_infra_all
    EXPORT KanoInfraTargets
)

install(EXPORT KanoInfraTargets
    FILE KanoInfraTargets.cmake
    NAMESPACE KanoInfra::
    DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/KanoInfra"
)

configure_package_config_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/cmake/KanoInfraConfig.cmake.in"
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

# ---------------------------------------------------------------------------
# KANO_INFRA_VERSION
# ---------------------------------------------------------------------------
set(KANO_INFRA_VERSION "${PROJECT_VERSION}")
