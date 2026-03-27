/* config_loader.cpp — layered TOML config implementation */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "kano_config.h"
#include "kano_config_export.h"

/* ---------------------------------------------------------------------------
 * Minimal TOML parsing (subset: key=value, [section] headers)
 * Full TOML v1 support would require a TOML library; this is a stub
 * that loads a config file as a flat key=value store for bootstrap.
 * --------------------------------------------------------------------------- */

struct KanoConfigImpl {
    char* filepath;
    /* TODO: use a small hash map or flat array for key=value pairs */
    /* Stub: this implementation is intentionally minimal as a placeholder */
};

KanoConfig kano_config_load(const char* filepath) {
    if (!filepath) return NULL;
    KanoConfig cfg = (KanoConfig)calloc(1, sizeof(struct KanoConfigImpl));
    if (!cfg) return NULL;
    cfg->filepath = (char*)malloc(strlen(filepath) + 1);
    if (!cfg->filepath) { free(cfg); return NULL; }
    strcpy(cfg->filepath, filepath);
    /* TODO: parse TOML file into key=value store */
    return cfg;
}

bool kano_config_reload(KanoConfig cfg) {
    /* TODO: re-parse from filepath */
    (void)cfg;
    return true;
}

void kano_config_free(KanoConfig cfg) {
    if (!cfg) return;
    free(cfg->filepath);
    free(cfg);
}

const char* kano_config_get(KanoConfig cfg, const char* key) {
    /* TODO: look up key in parsed TOML store */
    (void)cfg; (void)key;
    return NULL;
}

bool kano_config_get_int(KanoConfig cfg, const char* key, int* out_value) {
    (void)cfg; (void)key; (void)out_value;
    return false;
}

bool kano_config_get_bool(KanoConfig cfg, const char* key, bool* out_value) {
    (void)cfg; (void)key; (void)out_value;
    return false;
}

bool kano_config_has(KanoConfig cfg, const char* key) {
    (void)cfg; (void)key;
    return false;
}

bool kano_config_merge(KanoConfig cfg, KanoConfig other) {
    (void)cfg; (void)other;
    return true;
}

char* kano_config_resolve_path(KanoConfig cfg, const char* repo_relative_path) {
    /* TODO: base + repo_relative_path concatenation */
    (void)cfg; (void)repo_relative_path;
    return NULL;
}

void kano_config_dump(KanoConfig cfg) {
    if (!cfg) return;
    printf("[kano_config] filepath=%s\n", cfg->filepath ? cfg->filepath : "(null)");
}
