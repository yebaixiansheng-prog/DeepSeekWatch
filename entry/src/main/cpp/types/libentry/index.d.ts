/**
 * DeepSeekHashV1 / PoW 搜索（C++ 原生实现）的 ArkTS 声明
 *
 * 实现见 entry/src/main/cpp/keccak_core.cpp + napi_init.cpp
 */

/** 计算 DeepSeekHashV1 摘要，返回 64 个小写 hex 字符 */
export const hashHex: (msg: string) => string;

/**
 * 在 [from, to) 内搜索 nonce，使 H(prefix + 十进制(nonce)) == challengeHex
 * @returns 命中的 nonce；未命中返回 -1
 */
export const searchRange: (prefix: string, challengeHex: string, from: number, to: number) => number;
