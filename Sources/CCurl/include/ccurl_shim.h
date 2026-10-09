#ifndef CCURL_SHIM_H
#define CCURL_SHIM_H

#include <curl/curl.h>

/*  curl_easy_setopt is a C variadic function, which Swift cannot call directly.
    These static inline wrappers give Swift one typed entry point per argument
    kind. They compile away to a direct call — no runtime cost.               */

static inline CURLcode ferry_setopt_long(CURL *h, CURLoption o, long v) {
    return curl_easy_setopt(h, o, v);
}

static inline CURLcode ferry_setopt_str(CURL *h, CURLoption o, const char *v) {
    return curl_easy_setopt(h, o, v);
}

static inline CURLcode ferry_setopt_ptr(CURL *h, CURLoption o, void *v) {
    return curl_easy_setopt(h, o, v);
}

static inline CURLcode ferry_setopt_off(CURL *h, CURLoption o, curl_off_t v) {
    return curl_easy_setopt(h, o, v);
}

static inline CURLcode ferry_setopt_slist(CURL *h, CURLoption o, struct curl_slist *v) {
    return curl_easy_setopt(h, o, v);
}

static inline CURLcode ferry_setopt_write_cb(CURL *h, CURLoption o,
                                             size_t (*f)(char *, size_t, size_t, void *)) {
    return curl_easy_setopt(h, o, f);
}

static inline CURLcode ferry_setopt_read_cb(CURL *h, CURLoption o,
                                            size_t (*f)(char *, size_t, size_t, void *)) {
    return curl_easy_setopt(h, o, f);
}

static inline CURLcode ferry_setopt_xfer_cb(CURL *h, CURLoption o,
                                            int (*f)(void *, curl_off_t, curl_off_t, curl_off_t, curl_off_t)) {
    return curl_easy_setopt(h, o, f);
}

static inline CURLcode ferry_getinfo_str(CURL *h, CURLINFO i, char **v) {
    return curl_easy_getinfo(h, i, v);
}

static inline CURLcode ferry_getinfo_long(CURL *h, CURLINFO i, long *v) {
    return curl_easy_getinfo(h, i, v);
}

static inline CURLcode ferry_getinfo_off(CURL *h, CURLINFO i, curl_off_t *v) {
    return curl_easy_getinfo(h, i, v);
}

#endif
