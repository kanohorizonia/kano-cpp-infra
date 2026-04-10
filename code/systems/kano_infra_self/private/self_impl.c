/* self_impl.c — self-build/rebuild metadata implementation
 *
 * Parses CMakePresets.json to build a step sequence:
 *   BOOTSTRAP -> CONFIGURE -> BUILD -> TEST
 *
 * Staleness is determined by comparing timestamps of CMakeLists.txt,
 * CMakePresets.json, and the most recent build artifact.
 */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <limits.h>
#include <ctype.h>
#include <errno.h>
#include <stdint.h>

#if defined(_WIN32)
    #include <sys/stat.h>
    #include <direct.h>
    #define PATH_SEP '\\'
#else
    #include <sys/stat.h>
    #include <unistd.h>
    #define PATH_SEP '/'
#endif

#if defined(_WIN32) && !defined(PATH_MAX)
    #define PATH_MAX _MAX_PATH
#endif

#include "kano_self.h"

struct KanoSelfStepImpl {
    KanoSelfStepType type;
    char* target;
    char* description;
};

struct KanoSelfStepSeqImpl {
    KanoSelfStep* steps;
    size_t count;
    size_t capacity;
};

/* ---------------------------------------------------------------------------
 * Memory utilities
 * --------------------------------------------------------------------------- */

static char* xstrdup(const char* s) {
    if (!s) return NULL;
    size_t len = strlen(s) + 1;
    char* r = (char*)malloc(len);
    if (r) memcpy(r, s, len);
    return r;
}

static void free_stepseq(struct KanoSelfStepSeqImpl* seq) {
    if (!seq) return;
    for (size_t i = 0; i < seq->count; i++) {
        if (seq->steps[i]) {
            free((void*)(uintptr_t)seq->steps[i]->target);
            free((void*)(uintptr_t)seq->steps[i]->description);
            free(seq->steps[i]);
        }
    }
    free(seq->steps);
    free(seq);
}

/* ---------------------------------------------------------------------------
 * Path utilities
 * --------------------------------------------------------------------------- */

static int file_exists(const char* path) {
    struct stat st;
    return stat(path, &st) == 0 && (st.st_mode & S_IFREG) != 0;
}

static int dir_exists(const char* path) {
    struct stat st;
    return stat(path, &st) == 0 && (st.st_mode & S_IFDIR) != 0;
}

static char* path_join(const char* base, const char* rel) {
    if (!base) base = ".";
    size_t bl = strlen(base);
    size_t rl = strlen(rel);
    char* r = (char*)malloc(bl + rl + 2);
    if (!r) return NULL;
    memcpy(r, base, bl);
    if (bl > 0 && base[bl-1] != '/' && base[bl-1] != '\\') {
        r[bl++] = PATH_SEP;
    }
    memcpy(r + bl, rel, rl + 1);
    return r;
}

static int path_equal(const char* a, const char* b) {
    if (!a || !b) return a == b;
    while (*a && *b) {
        if ((*a == '/' || *a == '\\') && (*b == '/' || *b == '\\')) {
            a++; b++;
        } else if (tolower((unsigned char)*a) == tolower((unsigned char)*b)) {
            a++; b++;
        } else break;
    }
    return *a == *b;
}

static char* get_cwd(char* buf, size_t bufsize) {
    if (!buf || bufsize == 0) return NULL;
#if defined(_WIN32)
    return _getcwd(buf, (int)bufsize);
#else
    return getcwd(buf, bufsize);
#endif
}

/* ---------------------------------------------------------------------------
 * Timestamp comparison for staleness
 * --------------------------------------------------------------------------- */

static time_t file_mtime(const char* path) {
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    return st.st_mtime;
}

/* ---------------------------------------------------------------------------
 * Minimal JSON parser for CMakePresets.json
 * --------------------------------------------------------------------------- */

enum JsonTok {
    TOK_NONE, TOK_LBRACE, TOK_RBRACE, TOK_LBRACKET, TOK_RBRACKET,
    TOK_COLON, TOK_COMMA, TOK_STRING, TOK_EOF
};

struct JsonParser {
    const char* p;
    const char* end;
    enum JsonTok cur_tok;
    char* cur_str;
    int depth;
    int arr_depth;
};

static void json_init(struct JsonParser* jp, const char* text, size_t len) {
    memset(jp, 0, sizeof(*jp));
    jp->p = text;
    jp->end = text + len;
    jp->cur_tok = TOK_NONE;
    jp->cur_str = NULL;
    jp->depth = 0;
    jp->arr_depth = 0;
}

static void json_free(struct JsonParser* jp) {
    free(jp->cur_str);
    jp->cur_str = NULL;
}

static void json_skip_ws(struct JsonParser* jp) {
    while (jp->p < jp->end && isspace((unsigned char)*jp->p)) jp->p++;
    if (jp->p + 1 < jp->end && jp->p[0] == '/' && jp->p[1] == '/') {
        while (jp->p < jp->end && *jp->p != '\n') jp->p++;
        json_skip_ws(jp);
    }
}

static enum JsonTok json_next(struct JsonParser* jp) {
    json_skip_ws(jp);
    if (jp->p >= jp->end) { jp->cur_tok = TOK_EOF; return TOK_EOF; }

    char c = *jp->p;
    switch (c) {
        case '{': jp->p++; jp->cur_tok = TOK_LBRACE; jp->depth++; break;
        case '}': jp->p++; jp->cur_tok = TOK_RBRACE; jp->depth--; break;
        case '[': jp->p++; jp->cur_tok = TOK_LBRACKET; jp->arr_depth++; break;
        case ']': jp->p++; jp->cur_tok = TOK_RBRACKET; jp->arr_depth--; break;
        case ':': jp->p++; jp->cur_tok = TOK_COLON; break;
        case ',': jp->p++; jp->cur_tok = TOK_COMMA; break;
        case '"': {
            jp->p++;
            const char* start = jp->p;
            while (jp->p < jp->end && *jp->p != '"') {
                if (*jp->p == '\\' && jp->p + 1 < jp->end) jp->p++;
                jp->p++;
            }
            size_t len = (size_t)(jp->p - start);
            if (jp->p < jp->end) jp->p++;
            free(jp->cur_str);
            jp->cur_str = (char*)malloc(len + 1);
            if (jp->cur_str) {
                memcpy(jp->cur_str, start, len);
                jp->cur_str[len] = '\0';
            }
            jp->cur_tok = TOK_STRING;
            break;
        }
        default:
            jp->cur_tok = TOK_EOF;
            break;
    }
    return jp->cur_tok;
}

static int json_match(struct JsonParser* jp, enum JsonTok tok) {
    if (jp->cur_tok == tok) {
        json_next(jp);
        return 1;
    }
    return 0;
}

static const char* json_string(struct JsonParser* jp) {
    return jp->cur_str;
}

/* ---------------------------------------------------------------------------
 * Preset storage (dynamic, 8 slots initially)
 * --------------------------------------------------------------------------- */

#define PRESET_INIT 8

typedef struct PresetItem {
    char* name;
    char* binary_dir;
    char* configure_preset;
    int hidden;
} PresetItem;

typedef struct PresetArray {
    PresetItem* items;
    size_t count;
    size_t capacity;
} PresetArray;

static void preset_array_init(PresetArray* a) {
    memset(a, 0, sizeof(*a));
    a->capacity = PRESET_INIT;
    a->items = (PresetItem*)calloc(a->capacity, sizeof(PresetItem));
}

static void preset_array_free(PresetArray* a) {
    for (size_t i = 0; i < a->count; i++) {
        free(a->items[i].name);
        free(a->items[i].binary_dir);
        free(a->items[i].configure_preset);
    }
    free(a->items);
    memset(a, 0, sizeof(*a));
}

static int preset_array_push(PresetArray* a, const char* name,
                              const char* binary_dir,
                              const char* configure_preset,
                              int hidden) {
    if (!name) return 0;
    if (a->count >= a->capacity) {
        size_t new_cap = a->capacity * 2;
        PresetItem* new_items = (PresetItem*)realloc(a->items, new_cap * sizeof(PresetItem));
        if (!new_items) return 0;
        memset(new_items + a->capacity, 0, (new_cap - a->capacity) * sizeof(PresetItem));
        a->items = new_items;
        a->capacity = new_cap;
    }
    a->items[a->count].name = xstrdup(name);
    a->items[a->count].binary_dir = xstrdup(binary_dir ? binary_dir : "");
    a->items[a->count].configure_preset = xstrdup(configure_preset ? configure_preset : "");
    a->items[a->count].hidden = hidden;
    a->count++;
    return 1;
}

/* ---------------------------------------------------------------------------
 * PresetSets - holds all three preset arrays
 * --------------------------------------------------------------------------- */

typedef struct PresetSets {
    PresetArray configure_presets;
    PresetArray build_presets;
    PresetArray test_presets;
} PresetSets;

static void presets_init(PresetSets* ps) {
    memset(ps, 0, sizeof(*ps));
    preset_array_init(&ps->configure_presets);
    preset_array_init(&ps->build_presets);
    preset_array_init(&ps->test_presets);
}

static void presets_free(PresetSets* ps) {
    preset_array_free(&ps->configure_presets);
    preset_array_free(&ps->build_presets);
    preset_array_free(&ps->test_presets);
    memset(ps, 0, sizeof(*ps));
}

/* ---------------------------------------------------------------------------
 * Parse a preset object from JSON.
 * --------------------------------------------------------------------------- */

static int parse_preset_object(struct JsonParser* jp, PresetArray* out) {
    const char* name = NULL;
    const char* binary_dir = NULL;
    const char* configure_preset = NULL;
    int hidden = 0;

    while (jp->cur_tok != TOK_RBRACE && jp->cur_tok != TOK_EOF) {
        if (jp->cur_tok == TOK_STRING) {
            const char* key = json_string(jp);
            json_next(jp);
            if (!json_match(jp, TOK_COLON)) break;
            json_next(jp);

            if (key) {
                if (strcmp(key, "name") == 0 && jp->cur_tok == TOK_STRING) {
                    name = json_string(jp);
                } else if (strcmp(key, "binaryDir") == 0 && jp->cur_tok == TOK_STRING) {
                    binary_dir = json_string(jp);
                } else if (strcmp(key, "configurePreset") == 0 && jp->cur_tok == TOK_STRING) {
                    configure_preset = json_string(jp);
                } else if (strcmp(key, "hidden") == 0) {
                    if (jp->cur_tok == TOK_STRING) {
                        const char* v = json_string(jp);
                        hidden = (v && strcmp(v, "true") == 0) ? 1 : 0;
                    }
                }
            }
        }
        json_next(jp);
    }
    json_match(jp, TOK_RBRACE);

    if (name) {
        return preset_array_push(out, name,
                                 binary_dir ? binary_dir : "",
                                 configure_preset ? configure_preset : "",
                                 hidden);
    }
    return 1;
}

/* ---------------------------------------------------------------------------
 * Parse a presets array
 * --------------------------------------------------------------------------- */

static int parse_preset_array(struct JsonParser* jp, PresetArray* out) {
    while (jp->cur_tok != TOK_RBRACKET && jp->cur_tok != TOK_EOF) {
        if (jp->cur_tok == TOK_LBRACE) {
            json_next(jp);
            parse_preset_object(jp, out);
            if (jp->cur_tok == TOK_RBRACE) json_next(jp);
        }
        if (jp->cur_tok == TOK_COMMA) json_next(jp);
    }
    json_match(jp, TOK_RBRACKET);
    return 1;
}

/* ---------------------------------------------------------------------------
 * Top-level parse: find configurePresets, buildPresets, testPresets
 * --------------------------------------------------------------------------- */

static int parse_presets(const char* json_text, size_t json_len,
                         PresetSets* out) {
    struct JsonParser jp;
    json_init(&jp, json_text, json_len);
    json_next(&jp);

    presets_init(out);

    while (jp.cur_tok != TOK_EOF && jp.cur_tok != TOK_RBRACE) {
        if (jp.cur_tok == TOK_STRING) {
            const char* key = json_string(&jp);
            json_next(&jp);
            if (!json_match(&jp, TOK_COLON)) break;
            json_next(&jp);

            if (key && strcmp(key, "configurePresets") == 0) {
                parse_preset_array(&jp, &out->configure_presets);
            } else if (key && strcmp(key, "buildPresets") == 0) {
                parse_preset_array(&jp, &out->build_presets);
            } else if (key && strcmp(key, "testPresets") == 0) {
                parse_preset_array(&jp, &out->test_presets);
            } else {
                while (jp.cur_tok != TOK_COMMA && jp.cur_tok != TOK_RBRACE && jp.cur_tok != TOK_EOF)
                    json_next(&jp);
                if (jp.cur_tok == TOK_COMMA) json_next(&jp);
            }
        } else {
            json_next(&jp);
        }
    }

    json_free(&jp);
    return 1;
}

/* ---------------------------------------------------------------------------
 * File loading
 * --------------------------------------------------------------------------- */

static char* load_file(const char* path, size_t* out_len) {
    FILE* f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len <= 0) { fclose(f); return NULL; }
    char* buf = (char*)malloc((size_t)len + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t n = fread(buf, 1, (size_t)len, f);
    fclose(f);
    buf[n] = '\0';
    if (out_len) *out_len = n;
    return buf;
}

/* ---------------------------------------------------------------------------
 * Variable resolution: ${sourceDir}, ${presetDir} -> "."
 * --------------------------------------------------------------------------- */

static void resolve_variables_inplace(char* str) {
    if (!str) return;
    char tmp[4096];
    char* dst = tmp;
    const char* src = str;
    size_t rem = sizeof(tmp) - 1;

    while (*src && rem > 1) {
        if (src[0] == '$' && src[1] == '{') {
            const char* start = src + 2;
            const char* end = start;
            while (*end && *end != '}') end++;
            size_t vlen = (size_t)(end - start);

            if (vlen == 9 && strncmp(start, "sourceDir", 9) == 0) {
                *dst++ = '.'; rem--;
            } else if (vlen == 9 && strncmp(start, "presetDir", 9) == 0) {
                *dst++ = '.'; rem--;
            } else {
                if (rem > 2) { *dst++ = '$'; rem--; }
                if (rem > 2) { *dst++ = '{'; rem--; }
                size_t cp = vlen < rem ? vlen : rem - 1;
                memcpy(dst, start, cp);
                dst += cp; rem -= cp;
                src = (*end == '}') ? end + 1 : end;
                continue;
            }
            src = (*end == '}') ? end + 1 : end;
        } else {
            *dst++ = *src++;
            rem--;
        }
    }
    *dst = '\0';
    strcpy(str, tmp);
}

/* ---------------------------------------------------------------------------
 * Find the default (non-hidden) configure preset
 * --------------------------------------------------------------------------- */

static const PresetItem* find_default_configure(const PresetSets* ps) {
    for (size_t i = 0; i < ps->configure_presets.count; i++) {
        if (!ps->configure_presets.items[i].hidden &&
            ps->configure_presets.items[i].name &&
            ps->configure_presets.items[i].name[0] != '\0') {
            return &ps->configure_presets.items[i];
        }
    }
    return NULL;
}

/* ---------------------------------------------------------------------------
 * Build a KanoSelfStepSeq from parsed presets
 * --------------------------------------------------------------------------- */

static KanoSelfStepSeq build_seq_from_presets(const PresetSets* ps,
                                               const char* repo_root) {
    (void)repo_root;
    struct KanoSelfStepSeqImpl* seq = (struct KanoSelfStepSeqImpl*)
        calloc(1, sizeof(struct KanoSelfStepSeqImpl));
    if (!seq) return NULL;
    seq->capacity = 16;
    seq->steps = (KanoSelfStep*)calloc(seq->capacity, sizeof(KanoSelfStep*));

    const PresetItem* def_cfg = find_default_configure(ps);

    if (def_cfg && def_cfg->name && def_cfg->name[0]) {
        KanoSelfStep step = (KanoSelfStep)calloc(1, sizeof(struct KanoSelfStepImpl));
        if (step) {
            step->type = KANO_SELF_STEP_CONFIGURE;
            step->target = xstrdup(def_cfg->name);
            step->description = xstrdup(def_cfg->binary_dir && def_cfg->binary_dir[0]
                                        ? def_cfg->binary_dir : "<in-source>");
            if (seq->count >= seq->capacity) {
                seq->capacity *= 2;
                KanoSelfStep* new_steps = (KanoSelfStep*)
                    realloc(seq->steps, seq->capacity * sizeof(KanoSelfStep*));
                if (new_steps) seq->steps = new_steps;
            }
            seq->steps[seq->count++] = step;
        }
    }

    for (size_t i = 0; i < ps->build_presets.count; i++) {
        const PresetItem* bp = &ps->build_presets.items[i];
        if (def_cfg && bp->configure_preset &&
            strcmp(bp->configure_preset, def_cfg->name) == 0) {
            KanoSelfStep step = (KanoSelfStep)calloc(1, sizeof(struct KanoSelfStepImpl));
            if (step) {
                step->type = KANO_SELF_STEP_BUILD;
                step->target = xstrdup(bp->name ? bp->name : "");
                step->description = xstrdup(bp->binary_dir && bp->binary_dir[0]
                                            ? bp->binary_dir : "<in-source>");
                if (seq->count >= seq->capacity) {
                    seq->capacity *= 2;
                    KanoSelfStep* new_steps = (KanoSelfStep*)
                        realloc(seq->steps, seq->capacity * sizeof(KanoSelfStep*));
                    if (new_steps) seq->steps = new_steps;
                }
                seq->steps[seq->count++] = step;
            }
        }
    }

    for (size_t i = 0; i < ps->test_presets.count; i++) {
        const PresetItem* tp = &ps->test_presets.items[i];
        if (def_cfg && tp->configure_preset &&
            strcmp(tp->configure_preset, def_cfg->name) == 0) {
            KanoSelfStep step = (KanoSelfStep)calloc(1, sizeof(struct KanoSelfStepImpl));
            if (step) {
                step->type = KANO_SELF_STEP_TEST;
                step->target = xstrdup(tp->name ? tp->name : "");
                step->description = xstrdup(tp->binary_dir && tp->binary_dir[0]
                                            ? tp->binary_dir : "<in-source>");
                if (seq->count >= seq->capacity) {
                    seq->capacity *= 2;
                    KanoSelfStep* new_steps = (KanoSelfStep*)
                        realloc(seq->steps, seq->capacity * sizeof(KanoSelfStep*));
                    if (new_steps) seq->steps = new_steps;
                }
                seq->steps[seq->count++] = step;
            }
        }
    }

    if (seq->count == 0) {
        KanoSelfStep step = (KanoSelfStep)calloc(1, sizeof(struct KanoSelfStepImpl));
        if (step) {
            step->type = KANO_SELF_STEP_BOOTSTRAP;
            step->description = xstrdup("cmake --presetup");
            if (seq->count >= seq->capacity) {
                seq->capacity *= 2;
                KanoSelfStep* new_steps = (KanoSelfStep*)
                    realloc(seq->steps, seq->capacity * sizeof(KanoSelfStep*));
                if (new_steps) seq->steps = new_steps;
            }
            seq->steps[seq->count++] = step;
        }
    }

    return (KanoSelfStepSeq)seq;
}

/* ---------------------------------------------------------------------------
 * KanoSelfCtxImpl - the opaque context
 * --------------------------------------------------------------------------- */

struct KanoSelfCtxImpl {
    char* root;
    PresetSets presets;
    KanoSelfStepSeq seq;
    int is_clean;
};

static KanoSelfCtx kano_self_create_int(const char* directory) {
    KanoSelfCtx ctx = (KanoSelfCtx)calloc(1, sizeof(struct KanoSelfCtxImpl));
    if (!ctx) return NULL;

    ctx->root = xstrdup(directory);
    presets_init(&ctx->presets);

    char* presets_path = path_join(directory, "CMakePresets.json");
    if (presets_path && file_exists(presets_path)) {
        size_t json_len = 0;
        char* json_text = load_file(presets_path, &json_len);
        if (json_text) {
            parse_presets(json_text, json_len, &ctx->presets);
            free(json_text);
        }
    }
    free(presets_path);

    ctx->seq = build_seq_from_presets(&ctx->presets, directory);

    char* cache_path = path_join(directory, "CMakeCache.txt");
    ctx->is_clean = !file_exists(cache_path);
    free(cache_path);

    const char* build_dirs[] = { "build", "cmake-build", "_build", "bin", "lib", NULL };
    for (int i = 0; build_dirs[i]; i++) {
        char* bd = path_join(directory, build_dirs[i]);
        if (bd && dir_exists(bd)) ctx->is_clean = 0;
        free(bd);
    }

    return ctx;
}

KanoSelfCtx kano_self_create_from_cwd(void) {
    char buf[PATH_MAX];
    if (!get_cwd(buf, sizeof(buf))) return NULL;
    return kano_self_create_int(buf);
}

KanoSelfCtx kano_self_create(const char* directory) {
    if (!directory) return kano_self_create_from_cwd();
    return kano_self_create_int(directory);
}

void kano_self_free(KanoSelfCtx ctx) {
    if (!ctx) return;
    free(ctx->root);
    presets_free(&ctx->presets);
    if (ctx->seq) free_stepseq((struct KanoSelfStepSeqImpl*)ctx->seq);
    free(ctx);
}

const char* kano_self_get_root(KanoSelfCtx ctx) {
    return ctx ? ctx->root : NULL;
}

bool kano_self_is_clean(KanoSelfCtx ctx) {
    return ctx ? ctx->is_clean : true;
}

KanoSelfStepSeq kano_self_get_build_sequence(KanoSelfCtx ctx) {
    return ctx ? ctx->seq : NULL;
}

size_t kano_self_seq_count(KanoSelfStepSeq seq) {
    if (!seq) return 0;
    return ((struct KanoSelfStepSeqImpl*)seq)->count;
}

KanoSelfStep kano_self_seq_at(KanoSelfStepSeq seq, size_t index) {
    if (!seq) return NULL;
    struct KanoSelfStepSeqImpl* s = (struct KanoSelfStepSeqImpl*)seq;
    if (index >= s->count) return NULL;
    return s->steps[index];
}

/* ---------------------------------------------------------------------------
 * Step property accessors
 * --------------------------------------------------------------------------- */

static const char* step_type_names[] = {
    "BOOTSTRAP", "CONFIGURE", "BUILD", "INSTALL", "TEST"
};

const char* kano_self_step_type_name(KanoSelfStep step) {
    if (!step) return "???";
    switch (step->type) {
        case KANO_SELF_STEP_BOOTSTRAP:  return step_type_names[0];
        case KANO_SELF_STEP_CONFIGURE:  return step_type_names[1];
        case KANO_SELF_STEP_BUILD:      return step_type_names[2];
        case KANO_SELF_STEP_INSTALL:    return step_type_names[3];
        case KANO_SELF_STEP_TEST:       return step_type_names[4];
        default: return "???";
    }
}

const char* kano_self_step_target(KanoSelfStep step) {
    return step ? (const char*)(step->target) : NULL;
}

const char* kano_self_step_description(KanoSelfStep step) {
    return step ? (const char*)(step->description) : NULL;
}

/* ---------------------------------------------------------------------------
 * Step execution
 * --------------------------------------------------------------------------- */

bool kano_self_step_execute(KanoSelfStep step, bool dry_run) {
    if (!step) return false;

    const char* type_name = kano_self_step_type_name(step);
    const char* target = kano_self_step_target(step);
    const char* description = kano_self_step_description(step);

    if (dry_run) {
        printf("[kano_self] dry-run: %s", type_name);
        if (target && target[0]) printf(" --target=%s", target);
        if (description) printf(" (%s)", description);
        printf("\n");
        return true;
    }

    switch (step->type) {
        case KANO_SELF_STEP_BOOTSTRAP:
            printf("[kano_self] running: cmake --presetup\n");
            break;
        case KANO_SELF_STEP_CONFIGURE:
            if (target && target[0])
                printf("[kano_self] running: cmake --preset=%s\n", target);
            break;
        case KANO_SELF_STEP_BUILD:
            if (target && target[0])
                printf("[kano_self] running: cmake --build --preset=%s\n", target);
            break;
        case KANO_SELF_STEP_TEST:
            if (target && target[0])
                printf("[kano_self] running: ctest --preset=%s\n", target);
            break;
        default:
            printf("[kano_self] unknown step type: %d\n", (int)step->type);
            return false;
    }
    return true;
}
