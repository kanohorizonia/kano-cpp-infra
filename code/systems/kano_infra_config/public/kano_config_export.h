#pragma once

/**
 * kano_config_export.h — DLL export/import macros for KanoConfig
 *
 * On Windows: KANO_CONFIG_EXPORTS when building the DLL.
 * Consumers: define KANO_CONFIG_STATIC or let the default import behavior apply.
 */

#if defined(_WIN32)
    #if defined(KANO_CONFIG_EXPORTS)
        #define KANO_CONFIG_API __declspec(dllexport)
    #elif defined(KANO_CONFIG_STATIC)
        #define KANO_CONFIG_API
    #else
        #define KANO_CONFIG_API __declspec(dllimport)
    #endif
#else
    #define KANO_CONFIG_API
#endif

/* Convenience macro for decoration-free implementations */
#ifndef KANO_CONFIG_NOEXPORT
    #define KANO_CONFIG_NOEXPORT
#endif
