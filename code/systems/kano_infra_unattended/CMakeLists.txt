add_library(kano_infra_unattended INTERFACE)
target_include_directories(kano_infra_unattended INTERFACE
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/public>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
)
target_compile_features(kano_infra_unattended INTERFACE cxx_std_17)
set_target_properties(kano_infra_unattended PROPERTIES EXPORT_NAME unattended)
add_library(KanoInfra::unattended ALIAS kano_infra_unattended)
