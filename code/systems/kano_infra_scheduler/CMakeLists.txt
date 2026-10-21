add_library(kano_infra_scheduler STATIC private/task_scheduler.cpp)
add_library(KanoInfra::scheduler ALIAS kano_infra_scheduler)
target_include_directories(kano_infra_scheduler PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/public>
    $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}/kano_infra_scheduler/public>)
target_link_libraries(kano_infra_scheduler PUBLIC ${_jsoncpp_target} KanoInfra::process)
target_compile_features(kano_infra_scheduler PUBLIC cxx_std_17)
if(WIN32)
    add_executable(kano_task_scheduler ../../apps/kano_task_scheduler/main.cpp)
    target_link_libraries(kano_task_scheduler PRIVATE ${_jsoncpp_target} KanoInfra::unattended taskschd ole32 oleaut32 advapi32)
    target_compile_features(kano_task_scheduler PRIVATE cxx_std_17)
    install(TARGETS kano_task_scheduler RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
endif()
