add_library(kano_infra_process
    private/process_impl.cpp
)
target_include_directories(kano_infra_process PUBLIC
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/public>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
)
add_library(KanoInfra::process ALIAS kano_infra_process)
