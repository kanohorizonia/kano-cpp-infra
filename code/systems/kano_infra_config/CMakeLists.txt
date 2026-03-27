add_library(kano_infra_config
    private/config_loader.cpp
)
target_include_directories(kano_infra_config PUBLIC
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/public>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
)
add_library(KanoInfra::config ALIAS kano_infra_config)
