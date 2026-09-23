// ChaCha20 на NEON для armv7 (Cortex-A8, iPhone 4).
//
// Скалярная версия monocypher расшифровывает пакет туннеля (~1300 байт) за
// ~168 мкс — это около четверти всего процессорного времени службы на iPhone 4,
// где при закачке процессор занят на 100%. NEON считает четыре слова разом:
// состояние ChaCha20 — это ровно четыре 128-битных регистра.
//
// Считаем два блока за проход: у Cortex-A8 длинный конвейер NEON, и на одном
// блоке половина тактов уходит в ожидание зависимостей.
//
// Формат тот же, что у monocypher: state[16] — константа, ключ, счётчик, nonce
// (32-битные слова в порядке хоста), счётчик state[12] увеличивается на каждый
// блок. Полные блоки по 64 байта; хвост остаётся скалярным.

#include <stddef.h>
#include <stdint.h>

#if defined(__ARM_NEON__) || defined(__ARM_NEON)

#include <arm_neon.h>

#define ROTL32(x, n) vsriq_n_u32(vshlq_n_u32((x), (n)), (x), 32 - (n))

// Один двойной раунд над четырьмя строками состояния.
#define DOUBLE_ROUND(a, b, c, d)                                   \
    a = vaddq_u32(a, b);                                           \
    d = veorq_u32(d, a);                                           \
    d = vreinterpretq_u32_u16(vrev32q_u16(vreinterpretq_u16_u32(d))); /* <<< 16 */ \
    c = vaddq_u32(c, d);                                           \
    b = veorq_u32(b, c);                                           \
    b = ROTL32(b, 12);                                             \
    a = vaddq_u32(a, b);                                           \
    d = veorq_u32(d, a);                                           \
    d = ROTL32(d, 8);                                              \
    c = vaddq_u32(c, d);                                           \
    b = veorq_u32(b, c);                                           \
    b = ROTL32(b, 7);                                              \
    /* столбцы -> диагонали */                                     \
    b = vextq_u32(b, b, 1);                                        \
    c = vextq_u32(c, c, 2);                                        \
    d = vextq_u32(d, d, 3);                                        \
    a = vaddq_u32(a, b);                                           \
    d = veorq_u32(d, a);                                           \
    d = vreinterpretq_u32_u16(vrev32q_u16(vreinterpretq_u16_u32(d))); \
    c = vaddq_u32(c, d);                                           \
    b = veorq_u32(b, c);                                           \
    b = ROTL32(b, 12);                                             \
    a = vaddq_u32(a, b);                                           \
    d = veorq_u32(d, a);                                           \
    d = ROTL32(d, 8);                                              \
    c = vaddq_u32(c, d);                                           \
    b = veorq_u32(b, c);                                           \
    b = ROTL32(b, 7);                                              \
    /* обратно в столбцы */                                        \
    b = vextq_u32(b, b, 3);                                        \
    c = vextq_u32(c, c, 2);                                        \
    d = vextq_u32(d, d, 1)

// Гамма блока в out (64 байта), плюс XOR со входом, если in != NULL.
static inline void chacha_out(uint8_t *out, const uint8_t *in,
                              uint32x4_t a, uint32x4_t b, uint32x4_t c, uint32x4_t d)
{
    uint8x16_t k0 = vreinterpretq_u8_u32(a), k1 = vreinterpretq_u8_u32(b);
    uint8x16_t k2 = vreinterpretq_u8_u32(c), k3 = vreinterpretq_u8_u32(d);
    if (in != NULL) {
        k0 = veorq_u8(k0, vld1q_u8(in));
        k1 = veorq_u8(k1, vld1q_u8(in + 16));
        k2 = veorq_u8(k2, vld1q_u8(in + 32));
        k3 = veorq_u8(k3, vld1q_u8(in + 48));
    }
    vst1q_u8(out,      k0);
    vst1q_u8(out + 16, k1);
    vst1q_u8(out + 32, k2);
    vst1q_u8(out + 48, k3);
}

void awg_chacha20_neon_blocks(uint8_t *out, const uint8_t *in,
                              size_t nb_blocks, uint32_t state[16])
{
    const uint32x4_t s0 = vld1q_u32(state);
    const uint32x4_t s1 = vld1q_u32(state + 4);
    const uint32x4_t s2 = vld1q_u32(state + 8);

    while (nb_blocks >= 2) {
        uint32x4_t s3 = vld1q_u32(state + 12);
        uint32x4_t s3b = vsetq_lane_u32(vgetq_lane_u32(s3, 0) + 1, s3, 0);

        uint32x4_t a0 = s0, b0 = s1, c0 = s2, d0 = s3;
        uint32x4_t a1 = s0, b1 = s1, c1 = s2, d1 = s3b;
        for (int i = 0; i < 10; i++) {
            DOUBLE_ROUND(a0, b0, c0, d0);
            DOUBLE_ROUND(a1, b1, c1, d1);
        }
        chacha_out(out, in, vaddq_u32(a0, s0), vaddq_u32(b0, s1),
                   vaddq_u32(c0, s2), vaddq_u32(d0, s3));
        chacha_out(out + 64, in ? in + 64 : NULL, vaddq_u32(a1, s0), vaddq_u32(b1, s1),
                   vaddq_u32(c1, s2), vaddq_u32(d1, s3b));

        state[12] += 2;
        if (state[12] < 2) state[13]++;   // перенос при переполнении счётчика
        out += 128;
        if (in != NULL) in += 128;
        nb_blocks -= 2;
    }

    while (nb_blocks > 0) {
        uint32x4_t s3 = vld1q_u32(state + 12);
        uint32x4_t a = s0, b = s1, c = s2, d = s3;
        for (int i = 0; i < 10; i++) {
            DOUBLE_ROUND(a, b, c, d);
        }
        chacha_out(out, in, vaddq_u32(a, s0), vaddq_u32(b, s1),
                   vaddq_u32(c, s2), vaddq_u32(d, s3));
        state[12]++;
        if (state[12] == 0) state[13]++;
        out += 64;
        if (in != NULL) in += 64;
        nb_blocks--;
    }
}

int awg_chacha20_neon_available(void) { return 1; }

#else   // не ARM: NEON нет, monocypher считает сам

void awg_chacha20_neon_blocks(uint8_t *out, const uint8_t *in,
                              size_t nb_blocks, uint32_t state[16])
{
    (void)out; (void)in; (void)nb_blocks; (void)state;
}

int awg_chacha20_neon_available(void) { return 0; }

#endif
