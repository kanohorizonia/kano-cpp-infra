#pragma once

/**
 * kano_config.h — public config facade for kano-cpp-infra
 *
 * Responsibility: layered TOML config loading, effective config merge, path discovery
 * Non-goals: not a schema validator, not a CLI argument parser
 *
 * Usage:
 *   #include <kano_config.h>
 *   KanoConfig cfg = kano_config_load("config/default.toml");
 *   const char* value = kano_config_get(cfg, "section.key");
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * Opaque handle
 * --------------------------------------------------------------------------- */
typedef struct KanoConfigImpl* KanoConfig;

typedef enum KanoConfigValueType {
    KANO_CONFIG_VALUE_STRING = 0,
    KANO_CONFIG_VALUE_INTEGER,
    KANO_CONFIG_VALUE_FLOAT,
    KANO_CONFIG_VALUE_BOOLEAN,
    KANO_CONFIG_VALUE_ARRAY,
    KANO_CONFIG_VALUE_TABLE,
} KanoConfigValueType;

typedef struct KanoConfigEntryView {
    const char* key;
    KanoConfigValueType type;
    const char* string_value;
    int64_t integer_value;
    double float_value;
    bool bool_value;
} KanoConfigEntryView;

typedef bool (*KanoConfigForEachFn)(const KanoConfigEntryView* entry, void* user_data);

/* ---------------------------------------------------------------------------
 * Lifecycle
 * --------------------------------------------------------------------------- */
/**
 * Create an empty config object for callers that want to merge explicit layers.
 */
KanoConfig kano_config_create_empty(void);

/**
 * Load a TOML config file. Returns NULL on failure.
 * The config object owns its memory; call kano_config_free() to release.
 */
KanoConfig kano_config_load(const char* filepath);

/**
 * Reload from the same filepath. Returns false on failure; config unchanged.
 */
bool kano_config_reload(KanoConfig cfg);

/**
 * Free a config object.
 */
void kano_config_free(KanoConfig cfg);

/* ---------------------------------------------------------------------------
 * Accessors
 * --------------------------------------------------------------------------- */
/**
 * Get a string value. Returns NULL if key not found.
 * The returned pointer is owned by the config object; do not free.
 */
const char* kano_config_get(KanoConfig cfg, const char* key);

/**
 * Get an integer value. Returns false if key not found or not an integer.
 */
bool kano_config_get_int(KanoConfig cfg, const char* key, int* out_value);

/**
 * Get a boolean value. Returns false if key not found or not a boolean.
 */
bool kano_config_get_bool(KanoConfig cfg, const char* key, bool* out_value);

/**
 * Returns true if the key exists (even if the value is null).
 */
bool kano_config_has(KanoConfig cfg, const char* key);

/* ---------------------------------------------------------------------------
 * Merge
 * --------------------------------------------------------------------------- */
/**
 * Merge another config into cfg (other takes priority on conflict).
 * Returns false if merge fails; entries copied before failure remain applied.
 */
bool kano_config_merge(KanoConfig cfg, KanoConfig other);

/**
 * Iterate through all flattened config entries in insertion order.
 * Returns false only when cfg/callback are invalid or the callback aborts.
 */
bool kano_config_foreach(KanoConfig cfg, KanoConfigForEachFn callback, void* user_data);

/* ---------------------------------------------------------------------------
 * Path discovery
 * --------------------------------------------------------------------------- */
/**
 * Resolve a repo-relative path using the config's discovered root.
 * The returned path is allocated; call free() to release.
 */
char* kano_config_resolve_path(KanoConfig cfg, const char* repo_relative_path);

/* ---------------------------------------------------------------------------
 * Debug
 * --------------------------------------------------------------------------- */
/**
 * Dump config contents to stdout (for debugging only).
 */
void kano_config_dump(KanoConfig cfg);

#ifdef __cplusplus
}
#endif
