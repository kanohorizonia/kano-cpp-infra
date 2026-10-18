add_library(kano_infra_process
    private/process_impl.cpp
    private/process_session_impl.inl
)
target_compile_features(kano_infra_process PRIVATE cxx_std_17)
target_include_directories(kano_infra_process PUBLIC
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/public>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
)
add_library(KanoInfra::process ALIAS kano_infra_process)
