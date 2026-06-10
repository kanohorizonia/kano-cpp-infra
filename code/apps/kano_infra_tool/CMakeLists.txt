add_executable(kano_infra_tool
    main.cpp
)

set_target_properties(kano_infra_tool PROPERTIES OUTPUT_NAME kano-cpp-infra-tool)

target_compile_features(kano_infra_tool PRIVATE cxx_std_20)

target_link_libraries(kano_infra_tool PRIVATE KanoInfra::process ${_jsoncpp_target})

target_include_directories(kano_infra_tool PRIVATE ${_jsoncpp_include_dir})

install(TARGETS kano_infra_tool)
