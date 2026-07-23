/* config_loader.c — layered TOML config implementation (pure C99) */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>

#include "kano_config.h"
#include "kano_config_export.h"

/* ============================================================================
 * Memory utilities — avoid std::string/std::vector dependency
 * ============================================================================ */

static char* xstrdup(const char* s) {
    if (!s) return NULL;
    size_t len = strlen(s) + 1;
    char* r = (char*)malloc(len);
    if (!r) return NULL;
    memcpy(r, s, len);
    return r;
}

static char* xstrndup(const char* s, size_t n) {
    if (!s) return NULL;
    size_t len = strlen(s);
    if (len > n) len = n;
    char* r = (char*)malloc(len + 1);
    if (!r) return NULL;
    memcpy(r, s, len);
    r[len] = '\0';
    return r;
}

static void* xrealloc(void* p, size_t n) {
    void* r = realloc(p, n);
    if (!r && n > 0) {
        free(p);
    }
    return r;
}

static char* kano_strtok_reentrant(char* str, const char* delim, char** saveptr) {
#if defined(_WIN32)
    return strtok_s(str, delim, saveptr);
#else
    return strtok_r(str, delim, saveptr);
#endif
}

/* ============================================================================
 * TomlValue — tagged union stored in the map
 * ============================================================================ */

enum TomlValueType {
    TOML_STRING = 0,
    TOML_INTEGER,
    TOML_FLOAT,
    TOML_BOOLEAN,
    TOML_ARRAY,
    TOML_TABLE,       /* inline table — stored as nested flat key */
};

typedef struct TomlValue {
    enum TomlValueType type;
    char*  s;    /* string / array repr */
    int64_t i;   /* integer */
    double  f;   /* float */
    int     b;   /* boolean (0/1) */
} TomlValue;

/* ============================================================================
 * TomlMap — dynamic array of key-value entries + a simple hash index
 *
 * Uses open-addressing hash table for name→index lookup so that
 * kano_config_get() is O(1) average. The flat entry array stores ordered
 * keys (insertion order preserved for dump output).
 * ============================================================================ */

#define TOML_MAP_LOAD_FACTOR 75  /* percent — resize when filled to this */
#define TOML_MAP_INIT_CAP    16

typedef struct TomlEntry {
    char*       key;       /* owned; NULL = empty slot */
    TomlValue   value;
} TomlEntry;

typedef struct TomlMap {
    TomlEntry*  entries;   /* flat array of entries */
    size_t*     hash_slots; /* parallel array: entry index or SIZE_MAX */
    size_t      count;       /* used entries */
    size_t      capacity;   /* allocated slots */
    size_t      hash_size;  /* hash table size (power of 2) */
} TomlMap;

static size_t tomap_hash(const char* key, size_t hash_size) {
    /* FNV-1a 64-bit */
    size_t h = 0xCBF29CE84222325ULL;
    while (*key) {
        h ^= (size_t)(unsigned char)(*key);
        h *= 0x100000001B3ULL;
        key++;
    }
    return h & (hash_size - 1);
}

static int tomap_resize(TomlMap* m) {
    size_t new_hash_size = m->hash_size == 0 ? TOML_MAP_INIT_CAP : m->hash_size * 2;
    size_t* new_slots = (size_t*)calloc(new_hash_size, sizeof(size_t));
    if (!new_slots) return 0;
    for (size_t i = 0; i < new_hash_size; i++) new_slots[i] = SIZE_MAX;

    /* rehash existing entries */
    for (size_t i = 0; i < m->capacity; i++) {
        if (m->entries[i].key) {
            size_t slot = tomap_hash(m->entries[i].key, new_hash_size);
            while (new_slots[slot] != SIZE_MAX) {
                slot = (slot + 1) & (new_hash_size - 1);
            }
            new_slots[slot] = i;
        }
    }

    free(m->hash_slots);
    m->hash_slots = new_slots;
    m->hash_size = new_hash_size;
    return 1;
}

static int tomap_grow(TomlMap* m) {
    size_t new_cap = m->capacity == 0 ? TOML_MAP_INIT_CAP : m->capacity * 2;
    TomlEntry* new_entries = (TomlEntry*)xrealloc(m->entries, new_cap * sizeof(TomlEntry));
    if (!new_entries) return 0;
    for (size_t i = m->capacity; i < new_cap; i++) {
        new_entries[i].key = NULL;
        memset(&new_entries[i].value, 0, sizeof(TomlValue));
    }
    m->entries = new_entries;
    m->capacity = new_cap;

    /* grow hash table when load factor exceeds threshold */
    size_t used_slots = 0;
    for (size_t i = 0; i < m->hash_size; i++) {
        if (m->hash_slots[i] != SIZE_MAX) used_slots++;
    }
    if (used_slots * 100 / (m->hash_size ? m->hash_size : 1) >= TOML_MAP_LOAD_FACTOR) {
        tomap_resize(m);
    }
    return 1;
}

static void tomap_init(TomlMap* m) {
    memset(m, 0, sizeof(TomlMap));
}

static void tomap_entry_free(TomlEntry* e) {
    free(e->key);
    e->key = NULL;
    if (e->value.s) {
        free(e->value.s);
        e->value.s = NULL;
    }
}

static void tomap_free(TomlMap* m) {
    if (!m) return;
    for (size_t i = 0; i < m->capacity; i++) {
        tomap_entry_free(&m->entries[i]);
    }
    free(m->entries);
    free(m->hash_slots);
    memset(m, 0, sizeof(TomlMap));
}

static TomlValue* tomap_get(const TomlMap* m, const char* key) {
    if (!m->hash_size || !key) return NULL;
    size_t slot = tomap_hash(key, m->hash_size);
    while (1) {
        size_t idx = m->hash_slots[slot];
        if (idx == SIZE_MAX) return NULL;
        if (idx < m->capacity && m->entries[idx].key && strcmp(m->entries[idx].key, key) == 0) {
            return &m->entries[idx].value;
        }
        slot = (slot + 1) & (m->hash_size - 1);
    }
}

static int tomap_set(TomlMap* m, const char* key, TomlValue value) {
    if (!key || !key[0]) return 0;

    /* already present? */
    TomlValue* existing = tomap_get(m, key);
    if (existing) {
        /* replace */
        if (existing->s) free(existing->s);
        *existing = value;
        return 1;
    }

    /* grow if needed */
    if (m->capacity == 0 || m->count >= m->capacity) {
        if (!tomap_grow(m)) return 0;
    }

    /* find empty entry slot */
    size_t entry_idx = m->count;

    /* insert into hash table */
    if (m->hash_size == 0) {
        if (!tomap_resize(m)) return 0;
    }
    size_t slot = tomap_hash(key, m->hash_size);
    while (m->hash_slots[slot] != SIZE_MAX) {
        slot = (slot + 1) & (m->hash_size - 1);
    }
    m->hash_slots[slot] = entry_idx;

    /* store entry */
    m->entries[entry_idx].key = xstrdup(key);
    m->entries[entry_idx].value = value;
    m->count++;
    return 1;
}

/* For ordered iteration (dump) */
static TomlEntry* tomap_iter_next(const TomlMap* m, size_t* cursor) {
    while (*cursor < m->capacity) {
        if (m->entries[*cursor].key) {
            return &m->entries[(*cursor)++];
        }
        (*cursor)++;
    }
    return NULL;
}

/* ============================================================================
 * String utilities (pure C)
 * ============================================================================ */

static int string_ends_with(const char* s, const char* suffix) {
    size_t sl = strlen(s);
    size_t pl = strlen(suffix);
    if (pl > sl) return 0;
    return strcmp(s + sl - pl, suffix) == 0;
}

/* Trim leading and trailing whitespace (modifies in-place, returns start) */
static char* str_trim_inplace(char* s) {
    while (isspace((unsigned char)*s)) s++;
    if (!*s) return s;
    char* end = s + strlen(s) - 1;
    while (end > s && isspace((unsigned char)*end)) *end-- = '\0';
    return s;
}

/* Returns pointer to first non-space char; does not modify input */
static const char* str_skip_ws(const char* s) {
    while (s && isspace((unsigned char)*s)) s++;
    return s;
}

/* Trim comment from line (does not modify input), returns new length */
static size_t trim_comment_inplace(char* line) {
    int in_str = 0;
    char q = 0;
    char* p = line;
    while (*p) {
        char c = *p;
        if (!in_str && (c == '"' || c == '\'')) { in_str = 1; q = c; }
        else if (in_str && c == q && p > line && p[-1] != '\\') { in_str = 0; }
        else if (!in_str && c == '#') { *p = '\0'; break; }
        p++;
    }
    return (size_t)(str_trim_inplace(line) - line);
}

/* ============================================================================
 * TOML value parsers (pure C, operate on owned buffers)
 * ============================================================================ */

static int parse_integer(const char* s, int64_t* out) {
    if (!s || !*s) return 0;
    char* end = NULL;
    errno = 0;
    *out = strtoll(s, &end, 0);
    if (errno != 0 || *end != '\0') return 0;
    return 1;
}

static int parse_float(const char* s, double* out) {
    if (!s || !*s) return 0;
    char* end = NULL;
    errno = 0;
    *out = strtod(s, &end);
    if (errno != 0 || *end != '\0') return 0;
    return 1;
}

/* Parse a TOML string value. Returns newly allocated string. */
static char* parse_toml_string(const char* raw) {
    size_t len = strlen(raw);
    if (len < 2) return NULL;
    char q = raw[0];
    if (q != '"' && q != '\'') return NULL;
    if (raw[len - 1] != q) return NULL;

    int literal = (q == '\'');
    char* out = (char*)malloc(len + 1); /* worst case */
    if (!out) return NULL;
    size_t j = 0;

    for (size_t i = 1; i + 1 < len; i++) {
        char c = raw[i];
        if (c == '\\' && !literal && i + 1 < len) {
            char n = raw[++i];
            switch (n) {
                case '"':  out[j++] = '"';  break;
                case '\\': out[j++] = '\\'; break;
                case 'n':  out[j++] = '\n'; break;
                case 'r':  out[j++] = '\r'; break;
                case 't':  out[j++] = '\t'; break;
                default:    out[j++] = n;   break;
            }
        } else {
            out[j++] = c;
        }
    }
    out[j] = '\0';
    return out;
}

/* Parse array — returns JSON-quoted string representation (newly allocated) */
static char* parse_array(const char* raw) {
    size_t len = strlen(raw);
    if (len < 2 || raw[0] != '[' || raw[len - 1] != ']') return NULL;

    char* inner = xstrndup(raw + 1, len - 2);
    char* ctx_inner = inner;
    char* saveptr = NULL;
    char* item_tok = kano_strtok_reentrant(inner, ",", &saveptr);
    int items_cap = 8;
    char** items = (char**)malloc(items_cap * sizeof(char*));
    int item_count = 0;

    while (item_tok) {
        char* trimmed = str_trim_inplace(item_tok);
        if (*trimmed) {
            if (item_count >= items_cap) {
                items_cap *= 2;
                char** new_items = (char**)realloc(items, items_cap * sizeof(char*));
                if (!new_items) { free(items); free(ctx_inner); return NULL; }
                items = new_items;
            }
            if (*trimmed == '"' || *trimmed == '\'') {
                char* parsed = parse_toml_string(trimmed);
                if (!parsed) { parsed = xstrdup(trimmed); }
                size_t parsed_len = strlen(parsed);
                items[item_count] = (char*)malloc(parsed_len + 3);
                sprintf(items[item_count], "\"%s\"", parsed);
                free(parsed);
            } else {
                items[item_count] = xstrdup(trimmed);
            }
            item_count++;
        }
        item_tok = kano_strtok_reentrant(NULL, ",", &saveptr);
    }
    free(ctx_inner);

    /* build output */
    size_t out_len = 3; /* '[', ']', and trailing NUL */
    for (int i = 0; i < item_count; i++) out_len += strlen(items[i]) + 2; /* ", " */
    char* out = (char*)malloc(out_len);
    if (!out) {
        for (int i = 0; i < item_count; i++) free(items[i]);
        free(items);
        return NULL;
    }
    char* p = out;
    *p++ = '[';
    for (int i = 0; i < item_count; i++) {
        if (i > 0) { *p++ = ','; *p++ = ' '; }
        size_t il = strlen(items[i]);
        memcpy(p, items[i], il);
        p += il;
    }
    *p++ = ']';
    *p = '\0';

    for (int i = 0; i < item_count; i++) free(items[i]);
    free(items);
    return out;
}

/* ============================================================================
 * TOML line parser (pure C, works on a scratch buffer)
 *
 * Parses a single non-blank, non-comment line and stores into m.
 * current_section: dot-prefix for keys (e.g. "section" or "section.subsection")
 * scratch: working buffer (line will be copied here and modified in-place)
 * Returns: 1 on success, 0 on fatal error, -1 on non-fatal (skip)
 * ============================================================================ */

static int parse_line(const char* line_in, const char* current_section,
                      TomlMap* m, char* scratch, size_t scratch_size) {
    const size_t line_length = strlen(line_in);
    if (line_length >= scratch_size) return -1;
    memmove(scratch, line_in, line_length + 1);
    trim_comment_inplace(scratch);
    if (!*scratch) return -1;

    if (scratch[0] == '[') {
        /* table header */
        char* end_bracket = strchr(scratch, ']');
        if (!end_bracket) return 0;
        *end_bracket = '\0';
        const char* section_key = str_trim_inplace(scratch + 1);
        if (!*section_key) return 0;
        /* store section marker as special key */
        TomlValue v;
        memset(&v, 0, sizeof(v));
        v.type = TOML_STRING;
        v.s = xstrdup(section_key);
        char section_buf[1024];
        sprintf(section_buf, "__section__%s", section_key);
        tomap_set(m, section_buf, v);
        return 1;
    }

    /* key=value */
    char* eq = strchr(scratch, '=');
    if (!eq || eq == scratch) return 0;
    *eq = '\0';
    char* key_part = str_trim_inplace(scratch);
    char* raw_val = str_trim_inplace(eq + 1);
    if (!*key_part || !*raw_val) return 0;

    /* trim_comment_inplace already removed comments while preserving quoted whitespace. */
    if (!*raw_val) return -1;

    /* build full key */
    char full_key[1024];
    if (current_section && *current_section) {
        /* section from special key */
        const char* sec = "";
        {
            char section_buf[1024];
            sprintf(section_buf, "__section__%s", current_section);
            TomlValue* sv = tomap_get(m, section_buf);
            if (sv && sv->s) sec = sv->s;
        }
        if (sec && *sec) {
            sprintf(full_key, "%s.%s", sec, key_part);
        } else {
            sprintf(full_key, "%s.%s", current_section, key_part);
        }
    } else {
        strcpy(full_key, key_part);
    }

    TomlValue v;
    memset(&v, 0, sizeof(v));

    if (*raw_val == '"' || *raw_val == '\'') {
        char* parsed = parse_toml_string(raw_val);
        if (!parsed) return 0;
        v.type = TOML_STRING;
        v.s = parsed;
    } else if (strcmp(raw_val, "true") == 0) {
        v.type = TOML_BOOLEAN;
        v.b = 1;
    } else if (strcmp(raw_val, "false") == 0) {
        v.type = TOML_BOOLEAN;
        v.b = 0;
    } else if (*raw_val == '[') {
        char* arr = parse_array(raw_val);
        if (!arr) return 0;
        v.type = TOML_ARRAY;
        v.s = arr;
    } else {
        int64_t iv = 0;
        double fv = 0.0;
        if (parse_integer(raw_val, &iv)) {
            v.type = TOML_INTEGER;
            v.i = iv;
        } else if (parse_float(raw_val, &fv)) {
            v.type = TOML_FLOAT;
            v.f = fv;
        } else {
            v.type = TOML_STRING;
            v.s = xstrdup(raw_val);
        }
    }

    if (!tomap_set(m, full_key, v)) return 0;
    return 1;
}

/* ============================================================================
 * TOML file parser
 * ============================================================================ */

static int toml_parse_file(FILE* f, TomlMap* out) {
    tomap_init(out);

    /* read entire file into memory */
    char* content = NULL;
    size_t content_cap = 0;
    size_t content_len = 0;
    char line_buf[4096];
    char scratch_buf[4096];
    char current_section[256] = {0};

    while (fgets(line_buf, (int)sizeof(line_buf), f)) {
        /* strip \r\n */
        size_t ll = strlen(line_buf);
        while (ll > 0 && (line_buf[ll-1] == '\n' || line_buf[ll-1] == '\r')) {
            line_buf[--ll] = '\0';
        }

        /* skip blank / comment lines */
        const char* p = str_skip_ws(line_buf);
        if (!*p || *p == '#') continue;

        int r = parse_line(line_buf, current_section, out, scratch_buf, sizeof(scratch_buf));
        if (r == 0) {
            tomap_free(out);
            return 0;
        }

        /* track current section */
        if (p[0] == '[') {
            char* end_bracket = strchr(line_buf, ']');
            if (end_bracket) {
                *end_bracket = '\0';
                const char* sec = str_trim_inplace(line_buf + 1);
                if (*sec) {
                    strncpy(current_section, sec, sizeof(current_section) - 1);
                    current_section[sizeof(current_section) - 1] = '\0';
                }
            }
        }
    }

    (void)content; (void)content_cap; (void)content_len; /* unused */
    return 1;
}

/* ============================================================================
 * Config impl — opaque handle contents
 * ============================================================================ */

struct KanoConfigImpl {
    char*     filepath;   /* owned */
    TomlMap   data;       /* merged TOML data */
    char*     root_dir;   /* for resolve_path: project root */
    char*     last_err;   /* owned */
};

#define TOML_SECTION_PREFIX "__section__:"

static const char* get_section_prefix(const char* section) {
    while (*section && *section != '[') section++;
    if (*section) section++;
    return section;
}

/* ============================================================================
 * Lifecycle
 * ============================================================================ */

KANO_CONFIG_API
KanoConfig kano_config_create_empty(void) {
    KanoConfig cfg = (KanoConfig)calloc(1, sizeof(struct KanoConfigImpl));
    if (!cfg) return NULL;
    tomap_init(&cfg->data);
    return cfg;
}

KANO_CONFIG_API
KanoConfig kano_config_load(const char* filepath) {
    if (!filepath) return NULL;

    FILE* f = fopen(filepath, "rb");
    if (!f) {
        fprintf(stderr, "[kano_config] cannot open file: %s\n", filepath);
        return NULL;
    }

    TomlMap data;
    if (!toml_parse_file(f, &data)) {
        fclose(f);
        return NULL;
    }
    fclose(f);

    KanoConfig cfg = kano_config_create_empty();
    if (!cfg) {
        tomap_free(&data);
        return NULL;
    }

    cfg->filepath = xstrdup(filepath);
    cfg->data = data;
    cfg->last_err = NULL;

    /* extract root dir from filepath */
    {
        size_t fl = strlen(filepath);
        char* fp_copy = xstrdup(filepath);
        char* last_sep = strrchr(fp_copy, '/');
        char* bs = strrchr(fp_copy, '\\');
        if (bs > last_sep) last_sep = bs;
        if (last_sep) *last_sep = '\0';
        cfg->root_dir = xstrdup(fp_copy);
        free(fp_copy);
    }

    return cfg;
}

KANO_CONFIG_API
bool kano_config_reload(KanoConfig cfg) {
    if (!cfg || !cfg->filepath) return false;
    KanoConfig new_cfg = kano_config_load(cfg->filepath);
    if (!new_cfg) return false;
    tomap_free(&cfg->data);
    cfg->data = new_cfg->data;
    free(new_cfg->filepath);
    free(new_cfg);
    return true;
}

KANO_CONFIG_API
void kano_config_free(KanoConfig cfg) {
    if (!cfg) return;
    free(cfg->filepath);
    tomap_free(&cfg->data);
    free(cfg->root_dir);
    free(cfg->last_err);
    free(cfg);
}

/* ============================================================================
 * Accessors
 * ============================================================================ */

KANO_CONFIG_API
const char* kano_config_get(KanoConfig cfg, const char* key) {
    if (!cfg || !key) return NULL;
    TomlValue* v = tomap_get(&cfg->data, key);
    if (!v || v->type != TOML_STRING) return NULL;
    return v->s;
}

KANO_CONFIG_API
bool kano_config_get_int(KanoConfig cfg, const char* key, int* out_value) {
    if (!cfg || !key) return false;
    TomlValue* v = tomap_get(&cfg->data, key);
    if (!v || v->type != TOML_INTEGER) return false;
    if (out_value) *out_value = (int)v->i;
    return true;
}

KANO_CONFIG_API
bool kano_config_get_bool(KanoConfig cfg, const char* key, bool* out_value) {
    if (!cfg || !key) return false;
    TomlValue* v = tomap_get(&cfg->data, key);
    if (!v || v->type != TOML_BOOLEAN) return false;
    if (out_value) *out_value = v->b != 0;
    return true;
}

KANO_CONFIG_API
bool kano_config_has(KanoConfig cfg, const char* key) {
    if (!cfg || !key) return false;
    return tomap_get(&cfg->data, key) != NULL;
}

/* ============================================================================
 * Merge
 * ============================================================================ */

KANO_CONFIG_API
bool kano_config_merge(KanoConfig cfg, KanoConfig other) {
    if (!cfg || !other) return false;
    /* iterate over other's entries and insert/replace into cfg */
    size_t cursor = 0;
    TomlEntry* e;
    while ((e = tomap_iter_next(&other->data, &cursor)) != NULL) {
        /* clone the value */
        TomlValue nv = e->value;
        if (nv.s) nv.s = xstrdup(nv.s);
        tomap_set(&cfg->data, e->key, nv);
    }
    return true;
}

KANO_CONFIG_API
bool kano_config_foreach(KanoConfig cfg, KanoConfigForEachFn callback, void* user_data) {
    if (!cfg || !callback) return false;

    size_t cursor = 0;
    TomlEntry* e;
    while ((e = tomap_iter_next(&cfg->data, &cursor)) != NULL) {
        KanoConfigEntryView view;
        memset(&view, 0, sizeof(view));
        view.key = e->key;
        view.type = (KanoConfigValueType)e->value.type;

        switch (e->value.type) {
            case TOML_STRING:
            case TOML_ARRAY:
            case TOML_TABLE:
                view.string_value = e->value.s;
                break;
            case TOML_INTEGER:
                view.integer_value = e->value.i;
                break;
            case TOML_FLOAT:
                view.float_value = e->value.f;
                break;
            case TOML_BOOLEAN:
                view.bool_value = e->value.b != 0;
                break;
        }

        if (!callback(&view, user_data)) {
            return false;
        }
    }

    return true;
}

/* ============================================================================
 * Path discovery
 * ============================================================================ */

/* Returns number of paths discovered; paths must be freed by caller */
static size_t discover_config_paths_impl(const char* domain, char*** out_paths) {
    size_t paths_cap = 8;
    size_t paths_count = 0;
    *out_paths = (char**)malloc(paths_cap * sizeof(char*));
    if (!*out_paths) return 0;

#define ADD_PATH(p) do { \
        if (paths_count >= paths_cap) { \
            paths_cap *= 2; \
            char** np = (char**)realloc(*out_paths, paths_cap * sizeof(char*)); \
            if (!np) { for (size_t _i = 0; _i < paths_count; _i++) free((*out_paths)[_i]); \
                       free(*out_paths); *out_paths = NULL; return 0; } \
            *out_paths = np; \
        } \
        (*out_paths)[paths_count++] = (p); \
    } while (0)

    /* KANO_CONFIG_PATH */
    {
        const char* env_val = getenv("KANO_CONFIG_PATH");
        if (env_val && *env_val) {
            char* ev = xstrdup(env_val);
            char* ctx = ev;
            char* tok = strtok(ev, ",;:");
            while (tok) {
                char* trimmed = str_trim_inplace(tok);
                if (*trimmed) ADD_PATH(xstrdup(trimmed));
                tok = strtok(NULL, ",;:");
            }
            free(ctx);
        }
    }

    /* Platform-specific home dir */
    const char* home = getenv("HOME");
    if (!home || !*home) home = getenv("USERPROFILE");

    /* XDG_CONFIG_HOME / ~/.config */
    {
        const char* xdg = getenv("XDG_CONFIG_HOME");
        char base[512] = {0};
        if (xdg && *xdg) {
            snprintf(base, sizeof(base), "%s", xdg);
        } else if (home && *home) {
            snprintf(base, sizeof(base), "%s/.config", home);
        }
        if (base[0]) {
            char tmp[1024];
            snprintf(tmp, sizeof(tmp), "%s/kano/%s/config.toml", base, domain);
            ADD_PATH(xstrdup(tmp));
            snprintf(tmp, sizeof(tmp), "%s/%s/config.toml", base, domain);
            ADD_PATH(xstrdup(tmp));
        }
    }

    /* ~/.kano/<domain>/config.toml */
    if (home && *home) {
        char tmp[1024];
        snprintf(tmp, sizeof(tmp), "%s/.kano/%s/config.toml", home, domain);
        ADD_PATH(xstrdup(tmp));
    }

    /* system-wide */
#if defined(_WIN32)
    {
        const char* sysroot = getenv("SystemRoot");
        if (sysroot && *sysroot) {
            char tmp[1024];
            snprintf(tmp, sizeof(tmp), "%s/kano/%s/config.toml", sysroot, domain);
            ADD_PATH(xstrdup(tmp));
        }
    }
#else
    {
        char tmp[1024];
        snprintf(tmp, sizeof(tmp), "/etc/kano/%s/config.toml", domain);
        ADD_PATH(xstrdup(tmp));
        snprintf(tmp, sizeof(tmp), "/etc/%s/config.toml", domain);
        ADD_PATH(xstrdup(tmp));
    }
#endif

#undef ADD_PATH
    return paths_count;
}

KANO_CONFIG_API
char* kano_config_discover(const char* domain) {
    if (!domain || !*domain) domain = "kano";

    char** paths = NULL;
    size_t count = discover_config_paths_impl(domain, &paths);
    if (count == 0) return NULL;

    KanoConfig merged = NULL;
    for (size_t i = 0; i < count; i++) {
        KanoConfig layer = kano_config_load(paths[i]);
        if (!layer) { free(paths[i]); continue; }
        if (!merged) {
            merged = layer;
        } else {
            kano_config_merge(merged, layer);
            kano_config_free(layer);
        }
        free(paths[i]);
    }
    free(paths);

    if (!merged) return NULL;

    /* return the first loaded filepath as a handle identifier */
    char* result = merged->filepath ? xstrdup(merged->filepath) : xstrdup("");
    /* keep merged alive; caller must kano_config_free */
    kano_config_free(merged);
    return result;
}

KANO_CONFIG_API
char* kano_config_resolve_path(KanoConfig cfg, const char* repo_relative_path) {
    if (!cfg || !repo_relative_path) return NULL;
    const char* base = cfg->root_dir ? cfg->root_dir : ".";

    /* detect absolute path */
    if (repo_relative_path[0] == '/' ||
        (repo_relative_path[1] == ':' && repo_relative_path[2] == '\\') ||
        (repo_relative_path[1] == ':' && repo_relative_path[2] == '/')) {
        return xstrdup(repo_relative_path);
    }

    size_t bl = strlen(base);
    size_t rl = strlen(repo_relative_path);
    char* result = (char*)malloc(bl + rl + 2);
    if (!result) return NULL;
    memcpy(result, base, bl);
    result[bl] = '/';
    memcpy(result + bl + 1, repo_relative_path, rl + 1);

    /* normalise double slashes */
    char* p = result;
    while (*p) {
        if (p[0] == '/' && p[1] == '/') {
            /* remove one slash */
            memmove(p, p + 1, strlen(p));
        } else {
            p++;
        }
    }
    return result;
}

/* ============================================================================
 * Debug dump
 * ============================================================================ */

KANO_CONFIG_API
void kano_config_dump(KanoConfig cfg) {
    if (!cfg) { printf("[kano_config] (null)\n"); return; }
    printf("[kano_config] filepath=%s\n", cfg->filepath ? cfg->filepath : "(null)");
    printf("[kano_config] root_dir=%s\n", cfg->root_dir ? cfg->root_dir : "(null)");
    printf("[kano_config] entries (%zu):\n", cfg->data.count);

    size_t cursor = 0;
    TomlEntry* e;
    while ((e = tomap_iter_next(&cfg->data, &cursor)) != NULL) {
        const char* type_str = "???";
        switch (e->value.type) {
            case TOML_STRING:  type_str = "string";  break;
            case TOML_INTEGER: type_str = "integer"; break;
            case TOML_FLOAT:   type_str = "float";   break;
            case TOML_BOOLEAN: type_str = "boolean"; break;
            case TOML_ARRAY:   type_str = "array";   break;
            case TOML_TABLE:   type_str = "table";   break;
        }
        printf("  %s (%s) = ", e->key, type_str);
        switch (e->value.type) {
            case TOML_STRING:  printf("%s", e->value.s ? e->value.s : "(null)"); break;
            case TOML_INTEGER: printf("%lld", (long long)e->value.i); break;
            case TOML_FLOAT:   printf("%g", e->value.f); break;
            case TOML_BOOLEAN: printf("%s", e->value.b ? "true" : "false"); break;
            case TOML_ARRAY:   printf("%s", e->value.s ? e->value.s : "[]"); break;
            default:           printf("???"); break;
        }
        printf("\n");
    }
}
