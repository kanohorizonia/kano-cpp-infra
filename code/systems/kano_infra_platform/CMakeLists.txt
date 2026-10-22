add_library(kano_infra_platform
    private/platform_impl.cpp
    private/file_lock.cpp
)
target_compile_features(kano_infra_platform PUBLIC cxx_std_17)
if(WIN32)
    target_link_libraries(kano_infra_platform PRIVATE advapi32)
endif()
target_include_directories(kano_infra_platform PUBLIC
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/public>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}/kano_infra_platform/public>"
)
add_library(KanoInfra::platform ALIAS kano_infra_platform)
