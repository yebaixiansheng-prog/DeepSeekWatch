/*
 * NAPI 胶水层：把 keccak_core 暴露给 ArkTS
 *
 * 暴露两个方法：
 *   hashHex(msg: string): string                  —— 64 位小写 hex 摘要（自检用）
 *   searchRange(prefix, challengeHex, from, to): number
 *                                                 —— 搜 nonce，未命中返回 -1
 */
#include "napi/native_api.h"
#include "keccak_core.h"

#include <string>

namespace {

std::string GetString(napi_env env, napi_value value) {
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
        return std::string();
    }
    std::string s;
    s.resize(len + 1);
    size_t copied = 0;
    napi_get_value_string_utf8(env, value, &s[0], len + 1, &copied);
    s.resize(len);
    return s;
}

int HexVal(char c) {
    if (c >= '0' && c <= '9') {
        return c - '0';
    }
    if (c >= 'a' && c <= 'f') {
        return c - 'a' + 10;
    }
    if (c >= 'A' && c <= 'F') {
        return c - 'A' + 10;
    }
    return 0;
}

/** hashHex(input: string): string */
napi_value HashHex(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_error(env, nullptr, "hashHex expects 1 argument");
        return nullptr;
    }
    std::string msg = GetString(env, args[0]);
    char out[DS_HASH_LEN * 2 + 1];
    ds_hash_hex(reinterpret_cast<const uint8_t *>(msg.data()), msg.size(), out);
    napi_value result = nullptr;
    napi_create_string_utf8(env, out, NAPI_AUTO_LENGTH, &result);
    return result;
}

/** searchRange(prefix: string, challengeHex: string, from: number, to: number): number */
napi_value SearchRange(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4) {
        napi_throw_error(env, nullptr, "searchRange expects 4 arguments");
        return nullptr;
    }

    std::string prefix = GetString(env, args[0]);
    std::string challengeHex = GetString(env, args[1]);
    int64_t from = 0;
    int64_t to = 0;
    napi_get_value_int64(env, args[2], &from);
    napi_get_value_int64(env, args[3], &to);

    if (challengeHex.size() < DS_HASH_LEN * 2) {
        napi_throw_error(env, nullptr, "challengeHex must be 64 hex chars");
        return nullptr;
    }

    uint8_t challenge[DS_HASH_LEN];
    for (int i = 0; i < DS_HASH_LEN; i++) {
        challenge[i] = (uint8_t)((HexVal(challengeHex[i * 2]) << 4) | HexVal(challengeHex[i * 2 + 1]));
    }

    long long hit = ds_search_range(prefix.data(), prefix.size(), challenge, from, to);
    napi_value result = nullptr;
    napi_create_int64(env, hit, &result);
    return result;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"hashHex", nullptr, HashHex, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"searchRange", nullptr, SearchRange, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

}  // namespace

static napi_module g_entryModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void) {
    napi_module_register(&g_entryModule);
}
