add_library(kano_infra_platform
    private/platform_impl.cpp
)
target_include_directories(kano_infra_platform PUBLIC
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/public>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
)
add_library(KanoInfra::platform ALIAS kano_infra_platform)
