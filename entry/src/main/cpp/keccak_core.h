/*
 * DeepSeekHashV1 —— DeepSeek 网页版 PoW 使用的哈希（原生实现）
 *
 * ⚠️ 与标准 SHA3-256 的唯一差异：
 *    Keccak-f[1600] 只做 **rounds 1..23**（跳过 round 0），
 *    其余（rate=136、填充 0x06…0x80、输出 32 字节、lane 小端）与 SHA3-256 完全一致。
 *    用标准 SHA3-256 会被服务端判 40301 INVALID_POW_RESPONSE。
 *
 * 为什么要用 C++ 重写：
 *    ArkTS/JS 版在 HUAWEI WATCH 5 上实测只有 **约 1000~2000 次哈希/秒**
 *    （一次 144000 范围的 PoW 要 20~55 秒）。同样的算法用 C++ 编译后
 *    每秒可算数百万次，PoW 降到毫秒级 —— 这是唯一能真正解决
 *    「安全校验太慢」的办法（ArkTS 不支持 WebAssembly，只能用 NAPI 原生模块）。
 *
 * lane 布局：A[x][y] 存在下标 `x + 5*y`。
 */
#ifndef DSWATCH_KECCAK_CORE_H
#define DSWATCH_KECCAK_CORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/** 摘要字节数 */
#define DS_HASH_LEN 32
/** SHA3-256 的 rate（字节） */
#define DS_RATE 136

/**
 * 计算 H(msg)（DeepSeekHashV1）
 * @param msg    输入字节
 * @param len    输入长度
 * @param out32  输出缓冲区，必须 >= 32 字节
 */
void ds_hash_bytes(const uint8_t *msg, size_t len, uint8_t *out32);

/**
 * 计算 H(msg) 并输出 64 个小写 hex 字符（+ NUL），便于自检与跨实现比对
 */
void ds_hash_hex(const uint8_t *msg, size_t len, char *out65);

/**
 * 在 [from, to) 内搜索 nonce，使 H(prefix + 十进制(nonce)) == challenge32
 *
 * @param prefix      前缀（形如 "<salt>_<expire_at>_"，调用方拼好）
 * @param prefixLen   前缀长度（必须 <= DS_RATE - 9）
 * @param challenge32 目标摘要（32 字节）
 * @param from/to     搜索区间（左闭右开）
 * @return 命中的 nonce；未命中返回 -1
 */
long long ds_search_range(const char *prefix, size_t prefixLen,
                          const uint8_t *challenge32,
                          long long from, long long to);

#ifdef __cplusplus
}
#endif

#endif /* DSWATCH_KECCAK_CORE_H */
