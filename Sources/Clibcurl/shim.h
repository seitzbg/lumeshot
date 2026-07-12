#ifndef Clibcurl_shim_h
#define Clibcurl_shim_h

#include <curl/curl.h>

// curl_easy_setopt is a C variadic function and is not callable from Swift.
// These typed, non-variadic static-inline wrappers forward to it from C, where variadics work.

static inline CURLcode clibcurl_set_string(CURL *curl, CURLoption option, const char *value) {
    return curl_easy_setopt(curl, option, value);
}
static inline CURLcode clibcurl_set_long(CURL *curl, CURLoption option, long value) {
    return curl_easy_setopt(curl, option, value);
}
static inline CURLcode clibcurl_set_upload(CURL *curl, long yesNo) {
    return curl_easy_setopt(curl, CURLOPT_UPLOAD, yesNo);
}
static inline CURLcode clibcurl_set_readfunc(CURL *curl, void *userdata,
        size_t (*read_cb)(char *buffer, size_t size, size_t nitems, void *userdata)) {
    CURLcode rc = curl_easy_setopt(curl, CURLOPT_READDATA, userdata);
    if (rc == CURLE_OK) rc = curl_easy_setopt(curl, CURLOPT_READFUNCTION, read_cb);
    return rc;
}
static inline CURLcode clibcurl_set_infilesize(CURL *curl, curl_off_t size) {
    return curl_easy_setopt(curl, CURLOPT_INFILESIZE_LARGE, size);
}

#endif
