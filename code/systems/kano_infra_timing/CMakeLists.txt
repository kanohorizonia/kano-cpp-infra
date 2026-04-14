add_library(kano_infra_timing
    private/timing_impl.cpp
)
target_compile_features(kano_infra_timing PUBLIC cxx_std_23)
target_include_directories(kano_infra_timing PUBLIC
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/public>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
)
add_library(KanoInfra::timing ALIAS kano_infra_timing)
