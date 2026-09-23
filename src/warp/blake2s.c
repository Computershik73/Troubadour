//
//  blake2s.c
//  YouTube
//
//  BLAKE2s (RFC 7693) + HMAC-BLAKE2s.
//

#include "blake2s.h"
#include <string.h>

static const uint32_t blake2s_IV[8] = {
    0x6A09E667UL, 0xBB67AE85UL, 0x3C6EF372UL, 0xA54FF53AUL,
    0x510E527FUL, 0x9B05688CUL, 0x1F83D9ABUL, 0x5BE0CD19UL
};

static const uint8_t blake2s_sigma[10][16] = {
    {  0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15 },
    { 14, 10,  4,  8,  9, 15, 13,  6,  1, 12,  0,  2, 11,  7,  5,  3 },
    { 11,  8, 12,  0,  5,  2, 15, 13, 10, 14,  3,  6,  7,  1,  9,  4 },
    {  7,  9,  3,  1, 13, 12, 11, 14,  2,  6,  5, 10,  4,  0, 15,  8 },
    {  9,  0,  5,  7,  2,  4, 10, 15, 14,  1, 11, 12,  6,  8,  3, 13 },
    {  2, 12,  6, 10,  0, 11,  8,  3,  4, 13,  7,  5, 15, 14,  1,  9 },
    { 12,  5,  1, 15, 14, 13,  4, 10,  0,  7,  6,  3,  9,  2,  8, 11 },
    { 13, 11,  7, 14, 12,  1,  3,  9,  5,  0, 15,  4,  8,  6,  2, 10 },
    {  6, 15, 14,  9, 11,  3,  0,  8, 12,  2, 13,  7,  1,  4, 10,  5 },
    { 10,  2,  8,  4,  7,  6,  1,  5, 15, 11,  9, 14,  3, 12, 13,  0 }
};

static uint32_t load32(const void *src) {
    const uint8_t *p = (const uint8_t *)src;
    return ((uint32_t)p[0])       | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void store32(void *dst, uint32_t w) {
    uint8_t *p = (uint8_t *)dst;
    p[0] = (uint8_t)(w);       p[1] = (uint8_t)(w >> 8);
    p[2] = (uint8_t)(w >> 16); p[3] = (uint8_t)(w >> 24);
}

static uint32_t rotr32(uint32_t w, unsigned c) {
    return (w >> c) | (w << (32 - c));
}

static void blake2s_compress(blake2s_state *S, const uint8_t block[BLAKE2S_BLOCKBYTES], int last) {
    uint32_t m[16];
    uint32_t v[16];
    size_t i;

    for (i = 0; i < 16; i++) m[i] = load32(block + i * 4);
    for (i = 0; i < 8;  i++) v[i] = S->h[i];

    v[8]  = blake2s_IV[0];
    v[9]  = blake2s_IV[1];
    v[10] = blake2s_IV[2];
    v[11] = blake2s_IV[3];
    v[12] = blake2s_IV[4] ^ S->t[0];
    v[13] = blake2s_IV[5] ^ S->t[1];
    v[14] = last ? ~blake2s_IV[6] : blake2s_IV[6];
    v[15] = blake2s_IV[7];

#define G(r, i, a, b, c, d)                              \
    do {                                                 \
        a = a + b + m[blake2s_sigma[r][2 * i + 0]];      \
        d = rotr32(d ^ a, 16);                           \
        c = c + d;                                       \
        b = rotr32(b ^ c, 12);                           \
        a = a + b + m[blake2s_sigma[r][2 * i + 1]];      \
        d = rotr32(d ^ a, 8);                            \
        c = c + d;                                       \
        b = rotr32(b ^ c, 7);                            \
    } while (0)

#define ROUND(r)                                 \
    do {                                         \
        G(r, 0, v[0], v[4], v[ 8], v[12]);       \
        G(r, 1, v[1], v[5], v[ 9], v[13]);       \
        G(r, 2, v[2], v[6], v[10], v[14]);       \
        G(r, 3, v[3], v[7], v[11], v[15]);       \
        G(r, 4, v[0], v[5], v[10], v[15]);       \
        G(r, 5, v[1], v[6], v[11], v[12]);       \
        G(r, 6, v[2], v[7], v[ 8], v[13]);       \
        G(r, 7, v[3], v[4], v[ 9], v[14]);       \
    } while (0)

    ROUND(0); ROUND(1); ROUND(2); ROUND(3); ROUND(4);
    ROUND(5); ROUND(6); ROUND(7); ROUND(8); ROUND(9);

#undef G
#undef ROUND

    for (i = 0; i < 8; i++) S->h[i] = S->h[i] ^ v[i] ^ v[i + 8];
}

static void blake2s_increment_counter(blake2s_state *S, uint32_t inc) {
    S->t[0] += inc;
    if (S->t[0] < inc) S->t[1]++;
}

void blake2s_init(blake2s_state *S, size_t outlen) {
    blake2s_init_key(S, outlen, NULL, 0);
}

void blake2s_init_key(blake2s_state *S, size_t outlen, const void *key, size_t keylen) {
    size_t i;
    if (outlen == 0 || outlen > BLAKE2S_OUTBYTES) outlen = BLAKE2S_OUTBYTES;
    if (keylen > 32) keylen = 32;

    memset(S, 0, sizeof(*S));
    for (i = 0; i < 8; i++) S->h[i] = blake2s_IV[i];
    // Parameter block: digest length, key length, fanout 1, depth 1.
    S->h[0] ^= 0x01010000UL ^ ((uint32_t)keylen << 8) ^ (uint32_t)outlen;
    S->outlen = outlen;

    if (keylen > 0 && key != NULL) {
        uint8_t block[BLAKE2S_BLOCKBYTES];
        memset(block, 0, sizeof(block));
        memcpy(block, key, keylen);
        blake2s_update(S, block, BLAKE2S_BLOCKBYTES);
        memset(block, 0, sizeof(block));
    }
}

void blake2s_update(blake2s_state *S, const void *in, size_t inlen) {
    const uint8_t *p = (const uint8_t *)in;
    if (inlen == 0 || p == NULL) return;

    // Keep a full block in reserve so the last one can be flagged final.
    if (S->buflen + inlen > BLAKE2S_BLOCKBYTES) {
        size_t left = S->buflen;
        size_t fill = BLAKE2S_BLOCKBYTES - left;
        memcpy(S->buf + left, p, fill);
        blake2s_increment_counter(S, BLAKE2S_BLOCKBYTES);
        blake2s_compress(S, S->buf, 0);
        S->buflen = 0;
        p += fill;
        inlen -= fill;

        while (inlen > BLAKE2S_BLOCKBYTES) {
            blake2s_increment_counter(S, BLAKE2S_BLOCKBYTES);
            blake2s_compress(S, p, 0);
            p += BLAKE2S_BLOCKBYTES;
            inlen -= BLAKE2S_BLOCKBYTES;
        }
    }
    memcpy(S->buf + S->buflen, p, inlen);
    S->buflen += inlen;
}

void blake2s_final(blake2s_state *S, void *out) {
    uint8_t buffer[BLAKE2S_OUTBYTES];
    size_t i;

    if (S->finished) return;
    S->finished = 1;

    blake2s_increment_counter(S, (uint32_t)S->buflen);
    memset(S->buf + S->buflen, 0, BLAKE2S_BLOCKBYTES - S->buflen);
    blake2s_compress(S, S->buf, 1);

    memset(buffer, 0, sizeof(buffer));
    for (i = 0; i < 8; i++) store32(buffer + i * 4, S->h[i]);
    memcpy(out, buffer, S->outlen);
    memset(buffer, 0, sizeof(buffer));
}

void blake2s(void *out, size_t outlen, const void *key, size_t keylen,
             const void *in, size_t inlen) {
    blake2s_state S;
    blake2s_init_key(&S, outlen, key, keylen);
    blake2s_update(&S, in, inlen);
    blake2s_final(&S, out);
    memset(&S, 0, sizeof(S));
}

void blake2s_hmac(uint8_t out[32], const void *key, size_t keylen,
                  const void *in, size_t inlen) {
    uint8_t x_key[BLAKE2S_BLOCKBYTES];
    uint8_t i_hash[BLAKE2S_OUTBYTES];
    blake2s_state S;
    size_t i;

    memset(x_key, 0, sizeof(x_key));
    if (keylen > BLAKE2S_BLOCKBYTES) {
        blake2s(x_key, BLAKE2S_OUTBYTES, NULL, 0, key, keylen);
    } else if (keylen > 0) {
        memcpy(x_key, key, keylen);
    }

    for (i = 0; i < BLAKE2S_BLOCKBYTES; i++) x_key[i] ^= 0x36;
    blake2s_init(&S, BLAKE2S_OUTBYTES);
    blake2s_update(&S, x_key, BLAKE2S_BLOCKBYTES);
    blake2s_update(&S, in, inlen);
    blake2s_final(&S, i_hash);

    for (i = 0; i < BLAKE2S_BLOCKBYTES; i++) x_key[i] ^= 0x5c ^ 0x36;
    blake2s_init(&S, BLAKE2S_OUTBYTES);
    blake2s_update(&S, x_key, BLAKE2S_BLOCKBYTES);
    blake2s_update(&S, i_hash, BLAKE2S_OUTBYTES);
    blake2s_final(&S, i_hash);

    memcpy(out, i_hash, BLAKE2S_OUTBYTES);
    memset(x_key, 0, sizeof(x_key));
    memset(i_hash, 0, sizeof(i_hash));
    memset(&S, 0, sizeof(S));
}
