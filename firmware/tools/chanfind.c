// Fast candidate search for find_channel_names.py (macOS: CommonCrypto, all cores; about 36M names
// a second on an M4 Max). A hashtag channel's key is SHA256("#name")[:16], its 1-byte hash
// SHA256(key)[0], and each packet carries HMAC-SHA256(key || 16 zero bytes, ciphertext)[:2].
// Prints every name whose hash byte and MAC match a packet: about 1 in 16.7M names per packet does
// by chance, so the Python side decrypts each one to confirm.
//   chanfind brute <maxlen> <hex payload>...   every #name of [a-z0-9-] up to maxlen characters
//   chanfind words <hex payload>... < names    one name per line, '#' added
// Build: cc -O3 -o chanfind chanfind.c
#include <CommonCrypto/CommonDigest.h>
#include <CommonCrypto/CommonHMAC.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>

typedef struct { unsigned char h, mac[2]; unsigned char ct[200]; int ctlen; } Sample;
static Sample S[256]; static int ns = 0; static unsigned char want[256];
static const char ALPHA[] = "abcdefghijklmnopqrstuvwxyz0123456789-";
static int NA = sizeof(ALPHA) - 1, maxlen = 0, nthreads = 16;   // 16: enough threads for any current Mac
static atomic_int next_first = 0; static atomic_llong tried = 0;
static pthread_mutex_t out_mtx = PTHREAD_MUTEX_INITIALIZER;

static void check(const char* name, int len) {
  unsigned char d[32], key[32], h2[32];
  CC_SHA256(name, len, d);
  memcpy(key, d, 16); memset(key + 16, 0, 16);
  CC_SHA256(key, 16, h2);
  if (!want[h2[0]]) return;
  for (int i = 0; i < ns; i++) {
    if (S[i].h != h2[0]) continue;
    unsigned char m[32];
    CCHmac(kCCHmacAlgSHA256, key, 32, S[i].ct, S[i].ctlen, m);
    if (m[0] == S[i].mac[0] && m[1] == S[i].mac[1]) {
      pthread_mutex_lock(&out_mtx); printf("%.*s\n", len, name); fflush(stdout); pthread_mutex_unlock(&out_mtx);
      return;
    }
  }
}

static void* brute(void* arg) {
  char buf[16]; buf[0] = '#';
  for (;;) {
    int f = atomic_fetch_add(&next_first, 1);
    if (f >= NA) return NULL;
    buf[1] = ALPHA[f];
    long long local = 0;
    for (int len = 1; len <= maxlen; len++) {   // names of `len` characters starting with ALPHA[f]
      int idx[16] = {0};
      for (;;) {
        for (int k = 1; k < len; k++) buf[1 + k] = ALPHA[idx[k]];
        check(buf, 1 + len); local++;
        int k = len - 1;
        while (k >= 1 && ++idx[k] == NA) { idx[k] = 0; k--; }
        if (k < 1) break;
      }
    }
    atomic_fetch_add(&tried, local);
  }
}

int main(int argc, char** argv) {
  // payloads (hash, mac[2], ciphertext) as hex arguments
  if (argc < 3) { fprintf(stderr, "usage: chanfind brute <maxlen> <hex>... | chanfind words <hex>... < names\n"); return 2; }
  int first = strcmp(argv[1], "brute") == 0 ? 3 : 2;
  if (first == 3) maxlen = atoi(argv[2]);
  for (int a = first; a < argc && ns < 256; a++) {
    const char* hx = argv[a]; int n = strlen(hx) / 2; if (n < 3 + 16) continue;
    unsigned char b[256]; for (int i = 0; i < n && i < 256; i++) sscanf(hx + 2 * i, "%2hhx", &b[i]);
    S[ns].h = b[0]; S[ns].mac[0] = b[1]; S[ns].mac[1] = b[2]; S[ns].ctlen = n - 3 > 200 ? 200 : n - 3;
    memcpy(S[ns].ct, b + 3, S[ns].ctlen); want[b[0]] = 1; ns++;
  }
  if (first == 3) {
    pthread_t t[64];
    for (int i = 0; i < nthreads; i++) pthread_create(&t[i], NULL, brute, NULL);
    for (int i = 0; i < nthreads; i++) pthread_join(t[i], NULL);
    fprintf(stderr, "tried %lld names\n", (long long)atomic_load(&tried));
  } else {
    char line[512]; long long n = 0, len;
    char name[520];
    while (fgets(line, sizeof line, stdin)) {
      len = strcspn(line, "\r\n"); line[len] = 0; if (!len) continue;
      int off = line[0] == '#' ? 1 : 0;
      int m = snprintf(name, sizeof name, "#%s", line + off);
      check(name, m); n++;
    }
    fprintf(stderr, "tried %lld names\n", n);
  }
  return 0;
}
