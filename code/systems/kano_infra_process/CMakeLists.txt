add_library(kano_infra_process
    private/process_impl.cpp
    private/process_listener.cpp
    private/process_replace.cpp
    private/process_session_impl.inl
)
target_compile_features(kano_infra_process PRIVATE cxx_std_17)
target_link_libraries(kano_infra_process PUBLIC KanoInfra::platform)
if(NOT WIN32)
    find_package(Threads REQUIRED)
    target_link_libraries(kano_infra_process PUBLIC Threads::Threads)
endif()
target_include_directories(kano_infra_process PUBLIC
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/public>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}/kano_infra_process/public>"
)
add_library(KanoInfra::process ALIAS kano_infra_process)
if(WIN32)
    target_link_libraries(kano_infra_process PRIVATE iphlpapi ws2_32)
endif()
