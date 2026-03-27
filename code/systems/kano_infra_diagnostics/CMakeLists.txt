add_library(kano_infra_diagnostics
    private/diagnostics_impl.cpp
)
target_include_directories(kano_infra_diagnostics PUBLIC
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/public>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
)
add_library(KanoInfra::diagnostics ALIAS kano_infra_diagnostics)
