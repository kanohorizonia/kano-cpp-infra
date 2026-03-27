cmake_minimum_required(VERSION 3.16)
project(kano-cpp-infra VERSION 1.0.0 LANGUAGES CXX)

include(GNUInstallDirs)
include(CMakePackageConfigHelpers)

add_subdirectory(code/systems/kano_infra_config)
add_subdirectory(code/systems/kano_infra_build_info)
add_subdirectory(code/systems/kano_infra_platform)
add_subdirectory(code/systems/kano_infra_process)
add_subdirectory(code/systems/kano_infra_diagnostics)
add_subdirectory(code/systems/kano_infra_self)

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

install(DIRECTORY code/systems/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR} FILES_MATCHING PATTERN "*.h")

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
