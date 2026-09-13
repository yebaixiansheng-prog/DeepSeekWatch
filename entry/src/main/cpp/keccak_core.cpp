#include "keccak_core.h"

/* ---------------- ι 轮常量（标准 Keccak，24 个） ---------------- */
static const uint64_t RC[24] = {
    0x0000000000000001ULL, 0x0000000000008082ULL, 0x800000000000808aULL, 0x8000000080008000ULL,
    0x000000000000808bULL, 0x0000000080000001ULL, 0x8000000080008081ULL, 0x8000000000008009ULL,
    0x000000000000008aULL, 0x0000000000000088ULL, 0x0000000080008009ULL, 0x000000008000000aULL,
    0x000000008000808bULL, 0x800000000000008bULL, 0x8000000000008089ULL, 0x8000000000008003ULL,
    0x8000000000008002ULL, 0x8000000000000080ULL, 0x000000000000800aULL, 0x800000008000000aULL,
    0x8000000080008081ULL, 0x8000000000008080ULL, 0x0000000080000001ULL, 0x8000000080008008ULL};

/* ρ 偏移，下标 x + 5*y */
static const int ROT[25] = {
    0, 1, 62, 28, 27,
    36, 44, 6, 55, 20,
    3, 10, 43, 25, 39,
    41, 45, 15, 21, 8,
    18, 2, 61, 56, 14};

static inline uint64_t rotl64(uint64_t x, int n) {
    return (n == 0) ? x : ((x << n) | (x >> (64 - n)));
}

/**
 * Keccak-f[1600]，rounds 1..23（跳过 round 0）
 * a 为 25 个 lane（原地修改），下标 x + 5*y
 */
static void ds_permute(uint64_t *a) {
    uint64_t b[25];
    for (int round = 1; round < 24; round++) {
        /* θ */
        uint64_t c[5], d[5];
        for (int x = 0; x < 5; x++) {
            c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20];
        }
        for (int x = 0; x < 5; x++) {
            d[x] = c[(x + 4) % 5] ^ rotl64(c[(x + 1) % 5], 1);
        }
        for (int x = 0; x < 5; x++) {
            for (int y = 0; y < 5; y++) {
                a[x + 5 * y] ^= d[x];
            }
        }
        /* ρ + π：B[y][(2x+3y)%5] = rot(A[x][y], R[x][y]) */
        for (int x = 0; x < 5; x++) {
            for (int y = 0; y < 5; y++) {
                b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl64(a[x + 5 * y], ROT[x + 5 * y]);
            }
        }
        /* χ */
        for (int x = 0; x < 5; x++) {
            for (int y = 0; y < 5; y++) {
                a[x + 5 * y] = b[x + 5 * y] ^ ((~b[((x + 1) % 5) + 5 * y]) & b[((x + 2) % 5) + 5 * y]);
            }
        }
        /* ι */
        a[0] ^= RC[round];
    }
}

/** 把 8 字节按小端读成一个 lane */
static inline uint64_t load_lane(const uint8_t *p) {
    uint64_t v = 0;
    for (int b = 7; b >= 0; b--) {
        v = (v << 8) | (uint64_t)p[b];
    }
    return v;
}

/** 把一个 lane 按小端写出 */
static inline void store_lane(uint8_t *p, uint64_t v) {
    for (int b = 0; b < 8; b++) {
        p[b] = (uint8_t)(v & 0xff);
        v >>= 8;
    }
}

void ds_hash_bytes(const uint8_t *msg, size_t len, uint8_t *out32) {
    uint8_t blk[DS_RATE];
    uint64_t a[25];
    for (int i = 0; i < 25; i++) {
        a[i] = 0;
    }

    size_t off = 0;
    while (off + DS_RATE <= len) {
        for (int i = 0; i < DS_RATE; i++) {
            blk[i] = msg[off + i];
        }
        for (int i = 0; i < 17; i++) {
            a[i] ^= load_lane(blk + i * 8);
        }
        ds_permute(a);
        off += DS_RATE;
    }

    size_t tail = len - off;
    for (int i = 0; i < DS_RATE; i++) {
        blk[i] = 0;
    }
    for (size_t i = 0; i < tail; i++) {
        blk[i] = msg[off + i];
    }
    blk[tail] = 0x06;
    blk[DS_RATE - 1] |= 0x80;
    for (int i = 0; i < 17; i++) {
        a[i] ^= load_lane(blk + i * 8);
    }
    ds_permute(a);

    for (int i = 0; i < 4; i++) {
        store_lane(out32 + i * 8, a[i]);
    }
}

void ds_hash_hex(const uint8_t *msg, size_t len, char *out65) {
    static const char HEX[] = "0123456789abcdef";
    uint8_t d[DS_HASH_LEN];
    ds_hash_bytes(msg, len, d);
    for (int i = 0; i < DS_HASH_LEN; i++) {
        out65[i * 2] = HEX[(d[i] >> 4) & 0xf];
        out65[i * 2 + 1] = HEX[d[i] & 0xf];
    }
    out65[DS_HASH_LEN * 2] = '\0';
}

long long ds_search_range(const char *prefix, size_t prefixLen,
                          const uint8_t *challenge32,
                          long long from, long long to) {
    /* 单块快路径的前提：前缀 + 最多 7 位 nonce + 0x06 + 0x80 都要塞进 136 字节 */
    if (to <= from || prefixLen + 9 > DS_RATE - 1) {
        return -1;
    }

    /* 目标：前 4 个 lane */
    uint64_t t0 = load_lane(challenge32);
    uint64_t t1 = load_lane(challenge32 + 8);
    uint64_t t2 = load_lane(challenge32 + 16);
    uint64_t t3 = load_lane(challenge32 + 24);

    /* 模板块：前缀 + 全 0 的 nonce 区 + 末尾 0x80 */
    uint8_t blk[DS_RATE];
    for (int i = 0; i < DS_RATE; i++) {
        blk[i] = 0;
    }
    for (size_t i = 0; i < prefixLen; i++) {
        blk[i] = (uint8_t)prefix[i];
    }
    blk[DS_RATE - 1] = 0x80;

    /* 模板状态：只有受 nonce 影响的 lane 会被覆盖，其余 23 个 lane 每轮直接拷贝 */
    uint64_t tpl[25];
    for (int i = 0; i < 25; i++) {
        tpl[i] = 0;
    }
    for (int i = 0; i < 17; i++) {
        tpl[i] = load_lane(blk + i * 8);
    }

    uint64_t a[25];
    long long n = from;
    while (n < to) {
        /* 写十进制 nonce + 0x06（n 递增，位数只增不减，不会留下残字节） */
        int d = 1;
        long long tmp = n;
        while (tmp >= 10) {
            tmp /= 10;
            d++;
        }
        tmp = n;
        for (int k = d - 1; k >= 0; k--) {
            blk[prefixLen + k] = (uint8_t)('0' + (int)(tmp % 10));
            tmp /= 10;
        }
        blk[prefixLen + d] = 0x06;

        /* 拷贝模板 + 覆盖受影响的 lane */
        int laneLo = (int)(prefixLen >> 3);
        int laneHi = (int)((prefixLen + (size_t)d) >> 3);
        for (int i = 0; i < 25; i++) {
            a[i] = tpl[i];
        }
        for (int ln = laneLo; ln <= laneHi && ln < 17; ln++) {
            a[ln] = load_lane(blk + ln * 8);
        }

        ds_permute(a);

        if (a[0] == t0 && a[1] == t1 && a[2] == t2 && a[3] == t3) {
            return n;
        }
        n++;
    }
    return -1;
}
