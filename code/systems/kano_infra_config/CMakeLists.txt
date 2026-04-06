add_library(kano_infra_config
    private/config_loader.c
)
target_compile_definitions(kano_infra_config PUBLIC KANO_CONFIG_STATIC)
target_include_directories(kano_infra_config PUBLIC
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/public>"
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/vendor>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
)
# Pure C99 — no C++ stdlib dependency
target_compile_features(kano_infra_config PUBLIC c_std_99)
add_library(KanoInfra::config ALIAS kano_infra_config)
