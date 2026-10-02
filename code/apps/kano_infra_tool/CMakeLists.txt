add_executable(kano_infra_tool
    main.cpp
)

set_target_properties(kano_infra_tool PROPERTIES OUTPUT_NAME kano-cpp-infra-tool)

target_compile_features(kano_infra_tool PRIVATE cxx_std_20)
if(WIN32)
    target_compile_definitions(kano_infra_tool PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
endif()

target_link_libraries(kano_infra_tool PRIVATE KanoInfra::process KanoInfra::unattended ${_jsoncpp_target})

if(_jsoncpp_include_dir)
    target_include_directories(kano_infra_tool PRIVATE ${_jsoncpp_include_dir})
endif()

# Source and install consumers resolve this stamp without executing a stale
# binary before the watchdog has established its deadline and containment.
add_custom_command(TARGET kano_infra_tool POST_BUILD
    COMMAND "${CMAKE_COMMAND}" "-DKANO_UNATTENDED_BINARY=$<TARGET_FILE:kano_infra_tool>"
        -P "${CMAKE_CURRENT_LIST_DIR}/../../../scripts/cmake/WriteUnattendedStamp.cmake"
    VERBATIM
)

install(TARGETS kano_infra_tool)
install(FILES "$<TARGET_FILE:kano_infra_tool>.unattended-v1"
    DESTINATION "${CMAKE_INSTALL_BINDIR}"
)
