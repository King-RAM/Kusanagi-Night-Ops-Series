#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <curl/curl.h>
#include <sys/stat.h>

#ifdef _WIN32
#include <windows.h>
#define PATH_SEP '\\'
#else
#include <unistd.h>
#define PATH_SEP '/'
#endif

/*
 * Kusanagi Night Ops: URL Scrapper (C Edition)
 *
 * - HTML mode (URL scraping + categories + --search + --full + -o)
 * - Network mode -n:
 *      * Shows red-team warning about noise
 *      * If confirmed, prints "Network mode not supported in this version"
 * - --night-ops + optional -sd <duration>:
 *      * standalone: Main URL: --night-ops    -> confirm, cleanup, exit
 *      * with URL:   <url> ... --night-ops -sd <duration> -> run, sleep, cleanup, exit
 * - Cleanup is best-effort:
 *      * delete .kno-url directory (same dir as executable) if exists
 *      * delete executable file (based on argv[0])
 */

#define MAX_LINE 4096

/* ---------- Globals ---------- */
static char *g_exe_path = NULL;

/* ---------- Simple dynamic string list ---------- */
typedef struct {
    char **items;
    size_t count;
    size_t capacity;
} StrList;

static void sl_init(StrList *sl) {
    sl->items = NULL;
    sl->count = 0;
    sl->capacity = 0;
}

static void sl_add(StrList *sl, const char *s) {
    if (!s) return;
    if (sl->count + 1 > sl->capacity) {
        size_t newcap = (sl->capacity == 0) ? 16 : sl->capacity * 2;
        char **ni = (char **)realloc(sl->items, newcap * sizeof(char *));
        if (!ni) return;
        sl->items = ni;
        sl->capacity = newcap;
    }
    sl->items[sl->count] = strdup(s);
    if (sl->items[sl->count]) {
        sl->count++;
    }
}

static void sl_free(StrList *sl) {
    if (!sl) return;
    for (size_t i = 0; i < sl->count; i++) {
        free(sl->items[i]);
    }
    free(sl->items);
    sl->items = NULL;
    sl->count = 0;
    sl->capacity = 0;
}

/* Case-insensitive substring search boolean */
static int strcasestr_bool(const char *haystack, const char *needle) {
    if (!haystack || !needle || !*needle) return 0;
    size_t nh = strlen(haystack);
    size_t nn = strlen(needle);
    if (nn > nh) return 0;
    for (size_t i = 0; i + nn <= nh; i++) {
        size_t j;
        for (j = 0; j < nn; j++) {
            char c1 = (char)tolower((unsigned char)haystack[i + j]);
            char c2 = (char)tolower((unsigned char)needle[j]);
            if (c1 != c2) break;
        }
        if (j == nn) return 1;
    }
    return 0;
}

/* ---------- HTTP fetch via libcurl ---------- */
struct MemoryBuffer {
    char *data;
    size_t size;
};

static size_t write_callback(void *contents, size_t size, size_t nmemb, void *userp) {
    size_t realsize = size * nmemb;
    struct MemoryBuffer *mem = (struct MemoryBuffer *)userp;

    char *ptr = (char *)realloc(mem->data, mem->size + realsize + 1);
    if (!ptr) return 0;
    mem->data = ptr;
    memcpy(&(mem->data[mem->size]), contents, realsize);
    mem->size += realsize;
    mem->data[mem->size] = '\0';
    return realsize;
}

static char *fetch_html(const char *url) {
    CURL *curl;
    CURLcode res;
    struct MemoryBuffer chunk;
    chunk.data = NULL;
    chunk.size = 0;

    curl = curl_easy_init();
    if (!curl) {
        fprintf(stderr, "[-] Failed to init CURL\n");
        return NULL;
    }

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "KNO-URL-C/1.0");
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, (void *)&chunk);
    /* Ignore SSL errors like Python version */
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 0L);

    res = curl_easy_perform(curl);
    if (res != CURLE_OK) {
        fprintf(stderr, "[-] CURL error fetching %s: %s\n", url, curl_easy_strerror(res));
        curl_easy_cleanup(curl);
        free(chunk.data);
        return NULL;
    }

    curl_easy_cleanup(curl);
    return chunk.data;  /* caller frees */
}

/* ---------- URL normalization & token parsing ---------- */
static char *normalize_url(const char *u) {
    if (!u || !*u) return NULL;
    if (!strncmp(u, "http://", 7) || !strncmp(u, "https://", 8)) {
        return strdup(u);
    }
    if (!strncmp(u, "www.", 4)) {
        size_t len = strlen(u) + 9;
        char *res = (char *)malloc(len);
        if (!res) return NULL;
        snprintf(res, len, "https://%s", u);
        return res;
    }
    if (strchr(u, '.') || strchr(u, ':')) {
        size_t len = strlen(u) + 9;
        char *res = (char *)malloc(len);
        if (!res) return NULL;
        snprintf(res, len, "https://%s", u);
        return res;
    }
    return strdup(u);
}

/* Split line into tokens (in-place, modifies buffer). Returns count. */
static int split_tokens(char *line, char **tokens, int max_tokens) {
    int count = 0;
    char *p = line;
    while (*p && count < max_tokens) {
        while (isspace((unsigned char)*p)) p++;
        if (!*p) break;
        tokens[count++] = p;
        while (*p && !isspace((unsigned char)*p)) p++;
        if (*p) {
            *p = '\0';
            p++;
        }
    }
    return count;
}

/* ---------- URL extraction (simplified) ---------- */
static void extract_urls_from_html(const char *html, StrList *urls) {
    const char *p = html;

    /* http:// */
    p = html;
    while ((p = strstr(p, "http://")) != NULL) {
        const char *start = p;
        const char *q = p;
        while (*q && !isspace((unsigned char)*q) && *q != '"' && *q != '\'' && *q != '<' && *q != '>') {
            q++;
        }
        size_t len = (size_t)(q - start);
        char *u = (char *)malloc(len + 1);
        if (!u) return;
        memcpy(u, start, len);
        u[len] = '\0';
        sl_add(urls, u);
        free(u);
        p = q;
    }

    /* https:// */
    p = html;
    while ((p = strstr(p, "https://")) != NULL) {
        const char *start = p;
        const char *q = p;
        while (*q && !isspace((unsigned char)*q) && *q != '"' && *q != '\'' && *q != '<' && *q != '>') {
            q++;
        }
        size_t len = (size_t)(q - start);
        char *u = (char *)malloc(len + 1);
        if (!u) return;
        memcpy(u, start, len);
        u[len] = '\0';
        sl_add(urls, u);
        free(u);
        p = q;
    }

    /* blob: */
    p = html;
    while ((p = strstr(p, "blob:")) != NULL) {
        const char *start = p;
        const char *q = p;
        while (*q && !isspace((unsigned char)*q) && *q != '"' && *q != '\'' && *q != '<' && *q != '>') {
            q++;
        }
        size_t len = (size_t)(q - start);
        char *u = (char *)malloc(len + 1);
        if (!u) return;
        memcpy(u, start, len);
        u[len] = '\0';
        sl_add(urls, u);
        free(u);
        p = q;
    }
}

/* ---------- Categorization helpers ---------- */
static const char *get_ext(const char *url) {
    const char *p = strrchr(url, '.');
    if (!p) return "";
    const char *slash = strchr(p, '/');
    if (slash) return "";
    return p;
}

static const char *categorize_url(const char *url) {
    const char *ext = get_ext(url);
    char lower_ext[16];
    size_t i;

    if (strlen(ext) < sizeof(lower_ext)) {
        for (i = 0; ext[i] && i < sizeof(lower_ext) - 1; i++) {
            lower_ext[i] = (char)tolower((unsigned char)ext[i]);
        }
        lower_ext[i] = '\0';
    } else {
        lower_ext[0] = '\0';
    }

    if (strstr(url, "/api/") || strcasestr_bool(url, "graphql")) {
        return "API / ENDPOINTS";
    }

    if (!strcmp(lower_ext, ".js") || !strcmp(lower_ext, ".mjs")) {
        return "SCRIPTS";
    }
    if (!strcmp(lower_ext, ".png") || !strcmp(lower_ext, ".jpg") ||
        !strcmp(lower_ext, ".jpeg") || !strcmp(lower_ext, ".gif") ||
        !strcmp(lower_ext, ".svg") || !strcmp(lower_ext, ".webp") ||
        !strcmp(lower_ext, ".ico") || !strcmp(lower_ext, ".mp4") ||
        !strcmp(lower_ext, ".mov") || !strcmp(lower_ext, ".wav")) {
        return "MEDIA";
    }
    if (!strcmp(lower_ext, ".json") || !strcmp(lower_ext, ".xml") ||
        !strcmp(lower_ext, ".yml") || !strcmp(lower_ext, ".yaml") ||
        !strcmp(lower_ext, ".pdf") || !strcmp(lower_ext, ".txt") ||
        !strcmp(lower_ext, ".doc") || !strcmp(lower_ext, ".docx") ||
        !strcmp(lower_ext, ".csv")) {
        return "DOCUMENTS / CONFIG";
    }
    if (!strcmp(lower_ext, ".html") || !strcmp(lower_ext, ".htm") ||
        strstr(url, ".bundle.js") || strstr(url, ".chunk.js")) {
        return "HTML / FRAMEWORK";
    }

    return "OTHER";
}

/* ---------- Sorting by extension ---------- */
typedef struct {
    char *url;
    const char *ext;
} UrlWithExt;

static int cmp_uwe(const void *a, const void *b) {
    const UrlWithExt *ua = (const UrlWithExt *)a;
    const UrlWithExt *ub = (const UrlWithExt *)b;
    int c = strcmp(ua->ext, ub->ext);
    if (c != 0) return c;
    return strcmp(ua->url, ub->url);
}

/* ---------- Duration parsing (1h30m, 90s, etc.) ---------- */
static long parse_duration_seconds(const char *s) {
    if (!s || !*s) return -1;
    char buf[128];
    size_t bi = 0;
    for (size_t i = 0; s[i] && bi < sizeof(buf) - 1; i++) {
        if (!isspace((unsigned char)s[i])) {
            buf[bi++] = (char)tolower((unsigned char)s[i]);
        }
    }
    buf[bi] = '\0';
    if (!buf[0]) return -1;

    int all_digits = 1;
    for (size_t i = 0; buf[i]; i++) {
        if (!isdigit((unsigned char)buf[i])) {
            all_digits = 0;
            break;
        }
    }
    if (all_digits) {
        return atol(buf);
    }

    long total = 0;
    size_t i = 0;
    while (buf[i]) {
        if (!isdigit((unsigned char)buf[i])) return -1;
        long val = 0;
        while (isdigit((unsigned char)buf[i])) {
            val = val * 10 + (buf[i] - '0');
            i++;
        }
        char unit = buf[i];
        if (unit == 'h') {
            total += val * 3600;
            i++;
        } else if (unit == 'm') {
            total += val * 60;
            i++;
        } else if (unit == 's' || unit == '\0') {
            total += val;
            if (unit == 's') i++;
        } else {
            return -1;
        }
    }
    return (total > 0) ? total : -1;
}

/* ---------- Night Ops cleanup ---------- */
static void night_ops_cleanup(void) {
    printf("[*] --night-ops: attempting local cleanup...\n");

    if (g_exe_path) {
        char *path_copy = strdup(g_exe_path);
        if (path_copy) {
            char *last_sep = NULL;
            for (char *p = path_copy; *p; p++) {
                if (*p == '/' || *p == '\\') last_sep = p;
            }
            if (last_sep) {
                *last_sep = '\0';
            } else {
                strcpy(path_copy, ".");
            }

            size_t len = strlen(path_copy) + strlen("/.kno-url") + 1;
            char *kno_dir = (char *)malloc(len);
            if (kno_dir) {
                snprintf(kno_dir, len, "%s/.kno-url", path_copy);
                struct stat st;
                if (stat(kno_dir, &st) == 0 && (st.st_mode & S_IFDIR)) {
                    if (rmdir(kno_dir) == 0) {
                        printf("[*] Removed directory %s (if empty).\n", kno_dir);
                    } else {
                        printf("[!] Could not remove directory (might not be empty): %s\n", kno_dir);
                    }
                }
                free(kno_dir);
            }
            free(path_copy);
        }

        if (remove(g_exe_path) == 0) {
            printf("[*] Removed executable %s\n", g_exe_path);
        } else {
            printf("[!] Could not delete executable (possibly in use): %s\n", g_exe_path);
        }
    }

    printf("[+] Self-destruct complete. Exiting.\n");
}

/* ---------- HTML mode core ---------- */
static void run_html_mode(const char *url, char **args, int argc) {
    int use_scripts = 0, use_media = 0, use_api = 0, use_docs = 0, use_html = 0, use_other = 0;
    int no_media_mode = 0;
    char *output_file = NULL;
    int full_mode = 0;
    StrList search_terms; sl_init(&search_terms);

    for (int i = 0; i < argc; i++) {
        if (strcmp(args[i], "-s") == 0) use_scripts = 1;
        else if (strcmp(args[i], "-md") == 0) use_media = 1;
        else if (strcmp(args[i], "-a") == 0) use_api = 1;
        else if (strcmp(args[i], "-d") == 0) use_docs = 1;
        else if (strcmp(args[i], "-ht") == 0) use_html = 1;
        else if (strcmp(args[i], "-O") == 0) use_other = 1;
        else if (strcmp(args[i], "--no-media") == 0) no_media_mode = 1;
        else if (strcmp(args[i], "-o") == 0 && i + 1 < argc) {
            output_file = args[i + 1];
            i++;
        } else if (strcmp(args[i], "--search") == 0 && i + 1 < argc) {
            char *val = args[i + 1];
            char *tok = strtok(val, ",");
            while (tok) {
                while (*tok && isspace((unsigned char)*tok)) tok++;
                if (*tok) sl_add(&search_terms, tok);
                tok = strtok(NULL, ",");
            }
            i++;
        } else if (strcmp(args[i], "--full") == 0) {
            full_mode = 1;
        }
    }

    printf("[*] Fetching HTML from %s ...\n", url);
    char *html = fetch_html(url);
    if (!html) {
        sl_free(&search_terms);
        return;
    }

    if (full_mode) {
        if (output_file) {
            FILE *f = fopen(output_file, "w");
            if (f) {
                fputs(html, f);
                fclose(f);
                printf("[*] Full HTML written to %s\n", output_file);
            } else {
                fprintf(stderr, "[-] Failed to write to %s\n", output_file);
            }
        }
        printf("%s\n", html);
        free(html);
        sl_free(&search_terms);
        return;
    }

    StrList all_urls; sl_init(&all_urls);
    extract_urls_from_html(html, &all_urls);

    StrList cat_scripts, cat_media, cat_api, cat_docs, cat_html_list, cat_other;
    sl_init(&cat_scripts); sl_init(&cat_media); sl_init(&cat_api);
    sl_init(&cat_docs); sl_init(&cat_html_list); sl_init(&cat_other);

    int have_cat_flags = use_scripts || use_media || use_api || use_docs || use_html || use_other;

    for (size_t j = 0; j < all_urls.count; j++) {
        const char *u = all_urls.items[j];

        int keep = 1;
        if (search_terms.count > 0) {
            keep = 0;
            for (size_t st = 0; st < search_terms.count; st++) {
                if (strcasestr_bool(u, search_terms.items[st])) {
                    keep = 1;
                    break;
                }
            }
        }
        if (!keep) continue;

        const char *cat = categorize_url(u);

        if (have_cat_flags) {
            int wanted = 0;
            if (strcmp(cat, "SCRIPTS") == 0 && use_scripts) wanted = 1;
            if (strcmp(cat, "MEDIA") == 0   && use_media)   wanted = 1;
            if (strcmp(cat, "API / ENDPOINTS") == 0 && use_api) wanted = 1;
            if (strcmp(cat, "DOCUMENTS / CONFIG") == 0 && use_docs) wanted = 1;
            if (strcmp(cat, "HTML / FRAMEWORK") == 0 && use_html) wanted = 1;
            if (strcmp(cat, "OTHER") == 0 && use_other) wanted = 1;
            if (!wanted) continue;
        }

        if (no_media_mode) {
            int excluded = 0;
            if (strcmp(cat, "SCRIPTS") == 0 && use_scripts) excluded = 1;
            if (strcmp(cat, "MEDIA") == 0   && use_media)   excluded = 1;
            if (strcmp(cat, "API / ENDPOINTS") == 0 && use_api) excluded = 1;
            if (strcmp(cat, "DOCUMENTS / CONFIG") == 0 && use_docs) excluded = 1;
            if (strcmp(cat, "HTML / FRAMEWORK") == 0 && use_html) excluded = 1;
            if (strcmp(cat, "OTHER") == 0 && use_other) excluded = 1;
            if (excluded) continue;
        }

        if (strcmp(cat, "SCRIPTS") == 0) sl_add(&cat_scripts, u);
        else if (strcmp(cat, "MEDIA") == 0) sl_add(&cat_media, u);
        else if (strcmp(cat, "API / ENDPOINTS") == 0) sl_add(&cat_api, u);
        else if (strcmp(cat, "DOCUMENTS / CONFIG") == 0) sl_add(&cat_docs, u);
        else if (strcmp(cat, "HTML / FRAMEWORK") == 0) sl_add(&cat_html_list, u);
        else sl_add(&cat_other, u);
    }

    StrList *cats[6] = {&cat_scripts, &cat_media, &cat_api, &cat_docs, &cat_html_list, &cat_other};
    const char *names[6] = {"SCRIPTS", "MEDIA", "API / ENDPOINTS",
                            "DOCUMENTS / CONFIG", "HTML / FRAMEWORK", "OTHER"};

    StrList out_lines; sl_init(&out_lines);

    for (int c = 0; c < 6; c++) {
        StrList *cl = cats[c];
        if (cl->count == 0) continue;

        UrlWithExt *with_ext = (UrlWithExt *)calloc(cl->count, sizeof(UrlWithExt));
        StrList no_ext; sl_init(&no_ext);
        size_t we_count = 0;

        for (size_t j = 0; j < cl->count; j++) {
            const char *u = cl->items[j];
            const char *ext = get_ext(u);
            if (ext && *ext) {
                with_ext[we_count].url = (char *)u;
                with_ext[we_count].ext = ext;
                we_count++;
            } else {
                sl_add(&no_ext, u);
            }
        }

        if (we_count > 0) {
            qsort(with_ext, we_count, sizeof(UrlWithExt), cmp_uwe);
        }

        sl_add(&out_lines, names[c]);
        for (size_t j = 0; j < we_count; j++) {
            sl_add(&out_lines, with_ext[j].url);
        }
        for (size_t j = 0; j < no_ext.count; j++) {
            sl_add(&out_lines, no_ext.items[j]);
        }
        sl_add(&out_lines, "");

        sl_free(&no_ext);
        free(with_ext);
    }

    if (out_lines.count > 0) {
        for (size_t j = 0; j < out_lines.count; j++) {
            printf("%s\n", out_lines.items[j]);
        }
        if (output_file) {
            FILE *f = fopen(output_file, "w");
            if (f) {
                for (size_t j = 0; j < out_lines.count; j++) {
                    fputs(out_lines.items[j], f);
                    fputc('\n', f);
                }
                fclose(f);
                printf("[*] Results written to %s\n", output_file);
            } else {
                fprintf(stderr, "[-] Failed to write to %s\n", output_file);
            }
        }
    } else {
        printf("[*] No URLs matched filters.\n");
    }

    sl_free(&all_urls);
    sl_free(&cat_scripts);
    sl_free(&cat_media);
    sl_free(&cat_api);
    sl_free(&cat_docs);
    sl_free(&cat_html_list);
    sl_free(&cat_other);
    sl_free(&out_lines);
    sl_free(&search_terms);
    free(html);
}

/* ---------- Main loop with Night Ops semantics ---------- */
int main(int argc, char **argv) {
    char line[MAX_LINE];

    if (argc > 0 && argv[0]) {
        g_exe_path = strdup(argv[0]);
    }

    curl_global_init(CURL_GLOBAL_DEFAULT);
    printf("Kusanagi Night Ops: URL Scrapper (C Edition)\n");

    for (;;) {
        printf("Main URL: ");
        fflush(stdout);
        if (!fgets(line, sizeof(line), stdin)) break;

        size_t len = strlen(line);
        if (len > 0 && line[len-1] == '\n') line[len-1] = '\0';
        if (line[0] == '\0') {
            printf("[-] No URL detected. Use -h or --help for usage.\n");
            continue;
        }

        char *tokens[64];
        int ntok = split_tokens(line, tokens, 64);
        if (ntok == 0) {
            printf("[-] No URL detected.\n");
            continue;
        }

        /* Help */
        if (ntok == 1 && (strcmp(tokens[0], "-h") == 0 || strcmp(tokens[0], "--help") == 0)) {
            printf("Kusanagi Night Ops: URL Scrapper (C Edition)\n");
            printf("HTML mode flags:\n");
            printf("  -s -md -a -d -ht -O    category filters\n");
            printf("  --no-media             treat selected as exclusions\n");
            printf("  --search term1,term2   substring filter\n");
            printf("  --full                 dump full HTML\n");
            printf("  -o file                write output to file\n");
            printf("Network mode:\n");
            printf("  -n                     Network mode not supported in this version (with noise warning)\n");
            printf("Night Ops:\n");
            printf("  --night-ops            cleanup & self-destruct\n");
            printf("  --night-ops -sd 90s    schedule self-destruct\n");
            continue;
        }

        /* Standalone --night-ops (no URL, no other tokens) */
        if (ntok == 1 && strcmp(tokens[0], "--night-ops") == 0) {
            char ans[16];
            printf("[!] --night-ops will attempt to delete this binary and local .kno-url dir. Proceed? [y/N]: ");
            if (!fgets(ans, sizeof(ans), stdin)) {
                printf("\n[*] --night-ops canceled.\n");
                continue;
            }
            if (ans[0] == 'y' || ans[0] == 'Y') {
                night_ops_cleanup();
                curl_global_cleanup();
                return 0;
            } else {
                printf("[*] --night-ops canceled; no cleanup performed.\n");
                continue;
            }
        }

        /* URL parsing */
        char *url = NULL;
        int arg_start = 0;

        if (strcmp(tokens[0], "-u") == 0 && ntok >= 2) {
            url = normalize_url(tokens[1]);
            arg_start = 2;
        } else if (tokens[0][0] != '-') {
            url = normalize_url(tokens[0]);
            arg_start = 1;
        } else {
            for (int i = 0; i < ntok; i++) {
                if (!strncmp(tokens[i], "http://", 7) ||
                    !strncmp(tokens[i], "https://", 8) ||
                    !strncmp(tokens[i], "www.", 4)) {
                    url = normalize_url(tokens[i]);
                    arg_start = i + 1;
                    break;
                }
            }
        }

        char *args[64];
        int aargc = 0;
        for (int i = arg_start; i < ntok && aargc < 64; i++) {
            args[aargc++] = tokens[i];
        }

        if (!url) {
            printf("[-] No URL detected. Use -h or --help for usage, or use '--night-ops' alone.\n");
            continue;
        }

        /* Parse Night Ops & -sd duration */
        int night_ops = 0;
        long sd_seconds = -1;

        for (int i = 0; i < aargc; i++) {
            if (strcmp(args[i], "--night-ops") == 0) night_ops = 1;
        }

        for (int i = 0; i < aargc; i++) {
            if (strcmp(args[i], "-sd") == 0) {
                char durbuf[128];
                durbuf[0] = '\0';
                int j = i + 1;
                int first = 1;
                while (j < aargc && args[j][0] != '-') {
                    if (!first) strncat(durbuf, " ", sizeof(durbuf) - strlen(durbuf) - 1);
                    strncat(durbuf, args[j], sizeof(durbuf) - strlen(durbuf) - 1);
                    first = 0;
                    j++;
                }
                if (durbuf[0] == '\0') {
                    printf("Error: -sd requires a duration like '90s' or '1h30m'.\n");
                    free(url);
                    goto loop_continue;
                }
                sd_seconds = parse_duration_seconds(durbuf);
                if (sd_seconds <= 0) {
                    printf("Error: invalid -sd duration: %s\n", durbuf);
                    free(url);
                    goto loop_continue;
                }
                int new_aargc = 0;
                for (int k = 0; k < aargc; k++) {
                    if (k == i) {
                        k = j - 1;
                        continue;
                    }
                    args[new_aargc++] = args[k];
                }
                aargc = new_aargc;
                break;
            }
        }

        if (sd_seconds >= 0 && !night_ops) {
            printf("Error: -sd can only be used together with --night-ops.\n");
            free(url);
            goto loop_continue;
        }

        if (night_ops && sd_seconds < 0) {
            printf("Error: --night-ops can't be ran along side other commands unless -sd is defined with a time to execute\n");
            free(url);
            goto loop_continue;
        }

        if (night_ops) {
            int new_aargc = 0;
            for (int i = 0; i < aargc; i++) {
                if (strcmp(args[i], "--night-ops") == 0) continue;
                args[new_aargc++] = args[i];
            }
            aargc = new_aargc;
        }

        /* Network mode stub with red-team warning */
        int net_mode = 0;
        for (int i = 0; i < aargc; i++) {
            if (strcmp(args[i], "-n") == 0) {
                net_mode = 1;
                break;
            }
        }
        if (net_mode) {
            char ans[16];
            printf("WARNING: Network mode may be noisy for a stealthy Red Team Op, would you like to proceed? [y/N]: ");
            if (!fgets(ans, sizeof(ans), stdin)) {
                printf("\n[*] Network mode canceled.\n");
            } else {
                if (ans[0] == 'y' || ans[0] == 'Y') {
                    printf("Network mode not supported in this version\n");
                } else {
                    printf("[*] Network mode canceled.\n");
                }
            }
            free(url);
            goto loop_continue;
        }

        /* Unknown flags detection */
        const char *valid_flags[] = {
            "-s","-md","-a","-d","-ht","-O",
            "--no-media","--search","--full",
            "-o","-u","-h","--help"
        };
        int nvalid = (int)(sizeof(valid_flags)/sizeof(valid_flags[0]));
        int bad = 0;
        for (int i = 0; i < aargc; i++) {
            if (args[i][0] != '-') continue;
            int known = 0;
            for (int j = 0; j < nvalid; j++) {
                if (strcmp(args[i], valid_flags[j]) == 0) {
                    known = 1;
                    break;
                }
            }
            if (!known) {
                printf("Error: That flag does not exist: %s\n", args[i]);
                bad = 1;
                break;
            }
        }
        if (bad) {
            free(url);
            goto loop_continue;
        }

        run_html_mode(url, args, aargc);

        if (night_ops && sd_seconds > 0) {
            printf("[*] --night-ops scheduled via -sd, sleeping for %ld seconds before cleanup...\n", sd_seconds);
#ifdef _WIN32
            Sleep((DWORD)(sd_seconds * 1000));
#else
            sleep((unsigned int)sd_seconds);
#endif
            night_ops_cleanup();
            curl_global_cleanup();
            free(url);
            return 0;
        }

        free(url);
    loop_continue:
        continue;
    }

    curl_global_cleanup();
    free(g_exe_path);
    return 0;
}
