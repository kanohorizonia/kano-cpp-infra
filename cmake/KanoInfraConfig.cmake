# CMake config file for find_package(kano-cpp-infra)
# Consumed as: find_package(KanoInfra REQUIRED)
# Then: target_link_libraries(my_target PUBLIC KanoInfra::config ...)

@PACKAGE_INIT@

include("${CMAKE_CURRENT_LIST_DIR}/KanoInfraTargets.cmake")

# Convenience: re-export all modules
if(NOT KanoInfra_All_FOUND)
    check_required_components(All)
endif()
