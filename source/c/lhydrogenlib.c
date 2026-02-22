/* lhydrogenlib.c

   Copyright 2026 Max Chernoff <tex@maxchernoff.ca>

   This file is part of LuaTeX.

   LuaTeX is free software; you can redistribute it and/or modify it under
   the terms of the GNU General Public License as published by the Free
   Software Foundation; either version 2 of the License, or (at your
   option) any later version.

   LuaTeX is distributed in the hope that it will be useful, but WITHOUT
   ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
   FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
   License for more details.

   You should have received a copy of the GNU General Public License along
   with LuaTeX; if not, see <http://www.gnu.org/licenses/>. */

// Just treat libhydrogen as a header-only library, since it makes the
// compilation process simpler and the functions are only ever used in this
// file. Note: this fails if you use '#include "ptexlib.h"' before it.
#include "third-party/libhydrogen/hydrogen.c"

// Includes from LuaTeX
#define LUA_COMPAT_MODULE
#include "third-party/luatex/lauxlib.h"
#include "third-party/luatex/xmalloc.c"

// Helper macro to get a Lua string argument as a uint8_t pointer and length.
// This is needed because libhydrogen expects uint8_t arrays as input, but Lua
// only returns char arrays for strings. This cast might be undefined on systems
// with non-8-bit chars, but I doubt that LuaTeX runs on such systems anyways.
#define lua_uint8_string(idx, len) \
    ((const uint8_t *)luaL_checklstring(L, idx, len))

// Get the optional context argument, or use a default one if not provided.
// libhydrogen requires a context for most of its functions
//
//     https://github.com/jedisct1/libhydrogen/wiki/Contexts
//
// so we'll define a helper function here to get the context from Lua if it's
// provided, or use a default context if not.
#define DEFAULT_CONTEXT "LuaTeX\0\0"

static inline void get_context(lua_State *L, int idx,
    char ctx [hydro_sign_CONTEXTBYTES])
{
    const char *ctx_str;
    if (lua_type(L,idx) == LUA_TSTRING) {
        size_t ctx_len;
        ctx_str = luaL_checklstring(L, idx, &ctx_len);
        if (ctx_str == NULL || ctx_len != hydro_sign_CONTEXTBYTES) {
            luaL_error(L,
                "libhydrogen: context must be a string of length %d",
                hydro_sign_CONTEXTBYTES);
        }
    } else {
        ctx_str = DEFAULT_CONTEXT;
    }

    memcpy(ctx, ctx_str, hydro_sign_CONTEXTBYTES);
}

// Signing (asymmetric/public key) functions. These are the reason that this
// module exists, because I was unable to find any pure Lua implementations of
// elliptic curve signing algorithms, I'm not crazy enough to implement the
// primitives myself, and it's not easy to use an external library via luaffi
// for this.

// Generates a new keypair used for signing by using a CSPRNG.
static int luahydro_sign_keygen(lua_State *L)
{
    hydro_sign_keypair kp;
    hydro_sign_keygen(&kp);

    lua_pushlstring(L, (char *)kp.pk, hydro_sign_PUBLICKEYBYTES);
    lua_pushlstring(L, (char *)kp.sk, hydro_sign_SECRETKEYBYTES);

    return 2;
}

// Create a new signature for a given message and keypair.
static int luahydro_sign_create(lua_State *L)
{
    // Process the arguments
    size_t msg_len, sk_len;
    const uint8_t *msg = lua_uint8_string(1, &msg_len);
    const uint8_t *sk = lua_uint8_string(2, &sk_len);

    if (msg == NULL || sk == NULL) {
        return luaL_error(L, "libhydrogen.sign_create: invalid arguments");
    }

    if (sk_len != hydro_sign_SECRETKEYBYTES) {
        return luaL_error(L,
            "libhydrogen.sign_create: secret key must be a string of length %d",
            hydro_sign_SECRETKEYBYTES);
    }

    char ctx[hydro_sign_CONTEXTBYTES];
    get_context(L, 3, ctx);

    // Create the signature
    uint8_t signature[hydro_sign_BYTES];
    const int result = hydro_sign_create(signature, msg, msg_len, ctx, sk);

    // Check for errors and return the signature as a Lua string
    if (result != 0) {
        return luaL_error(L,
            "libhydrogen.sign_create: failed to create signature");
    }
    lua_pushlstring(L, (char *)signature, hydro_sign_BYTES);
    return 1;
}

// Verify a signature for a given message and public key
static int luahydro_sign_verify(lua_State *L)
{
    // Process the arguments
    size_t msg_len, sig_len, pubkey_len;
    const uint8_t *msg = lua_uint8_string(1, &msg_len);
    const uint8_t *sig = lua_uint8_string(2, &sig_len);
    const uint8_t *pubkey = lua_uint8_string(3, &pubkey_len);

    if (msg == NULL || sig == NULL || pubkey == NULL) {
        return luaL_error(L, "libhydrogen.sign_verify: invalid arguments");
    }

    if (sig_len != hydro_sign_BYTES) {
        return luaL_error(L,
            "libhydrogen.sign_verify: signature must be a string of length %d",
            hydro_sign_BYTES);
    }

    if (pubkey_len != hydro_sign_PUBLICKEYBYTES) {
        return luaL_error(L,
            "libhydrogen.sign_verify: public key must be a string of length %d",
            hydro_sign_PUBLICKEYBYTES);
    }

    char ctx[hydro_sign_CONTEXTBYTES];
    get_context(L, 4, ctx);

    // Verify the signature
    const int result = hydro_sign_verify(sig, msg, msg_len, ctx, pubkey);

    lua_pushboolean(L, result == 0);
    return 1;
}

// Hash functions. These are somewhat redundant with the preexisting sha2
// module, but:
//
// 1. libhydrogen uses them internally for the signing functions, so they come
//    for "free" with the library.
//
// 2. They don't use the Merkle--Damgard construction, so unlike sha2, they
//    are not vulnerable to length extension attacks.
//
// 3. They allow arbitrary output lengths, versus sha2 which only defines 3
//    fixed output lengths (256, 384, and 512 bits).
//
// 4. They are purportedly faster than sha2, but this is unlikely to be relevant
//    for LuaTeX.

// Common function used by keyed and unkeyed hash functions.
static int luahydro_hash_helper(lua_State *L, size_t msg_len,
    const uint8_t msg[static msg_len], size_t out_len,
    const int ctx_idx, const uint8_t key[hydro_hash_KEYBYTES])
{
    // Validate the arguments
    if (out_len < hydro_hash_BYTES_MIN || out_len > hydro_hash_BYTES_MAX) {
        return luaL_error(L,
            "libhydrogen.hash: output length must be between %d and %d",
            hydro_hash_BYTES_MIN, hydro_hash_BYTES_MAX);
    }

    char ctx[hydro_hash_CONTEXTBYTES];
    get_context(L, ctx_idx, ctx);

    // Hash the message
    uint8_t *out = xmalloc(out_len);
    const int result = hydro_hash_hash(out, out_len, msg, msg_len, ctx, key);

    // Return the hash as a Lua string, or an error if hashing failed
    if (result != 0) {
        free(out);
        return luaL_error(L, "libhydrogen.hash: failed to hash message");
    }
    lua_pushlstring(L, (char *)out, out_len);
    free(out);
    return 1;
}

// A basic, unkeyed hash function.
#define DEFAULT_HASH_BYTES 32 // (256 bits)

static int luahydro_hash(lua_State *L)
{
    // Process the arguments
    size_t msg_len, out_len;
    const uint8_t *msg = lua_uint8_string(1, &msg_len);
    if (lua_gettop(L) == 1) {
        out_len = DEFAULT_HASH_BYTES;
    } else {
        out_len = (size_t)luaL_checkinteger(L, 2);
    }

    if (msg == NULL) {
        return luaL_error(L, "libhydrogen.hash: invalid message argument");
    }

    // Call the common helper function with a NULL key
    return luahydro_hash_helper(L, msg_len, msg, out_len, 3, NULL);
}

// A keyed hash function
static int luahydro_hash_keyed(lua_State *L)
{
    // Process the arguments
    size_t msg_len, out_len, key_len;
    const uint8_t *msg = lua_uint8_string(1, &msg_len);
    const uint8_t *key = lua_uint8_string(2, &key_len);
    if (lua_gettop(L) == 2) {
        out_len = DEFAULT_HASH_BYTES;
    } else {
        out_len = (size_t)luaL_checkinteger(L, 3);
    }

    if (msg == NULL) {
        return luaL_error(L, "libhydrogen.hash: invalid message argument");
    }

    if (key != NULL && key_len != hydro_hash_KEYBYTES) {
        return luaL_error(L,
            "libhydrogen.hash: key must be a string of length %d",
            hydro_hash_KEYBYTES);
    }

    // Call the common helper function with a NULL key
    return luahydro_hash_helper(L, msg_len, msg, out_len, 4, key);
}

// Generate a random key for use with the keyed hash function.
static int luahydro_hash_keygen(lua_State *L)
{
    uint8_t key[hydro_hash_KEYBYTES];
    hydro_hash_keygen(key);
    lua_pushlstring(L, (char *)key, hydro_hash_KEYBYTES);
    return 1;
}

// CSPRNG (cryptographically secure pseudorandom number generator). Lua's
// built-in "math.random" function is sufficient for non-cryptographic uses, and
// the specialized "keygen" functions provided above are sufficient for use with
// their corresponding functions, but for completeness sake, we are also
// exposing the other random functions provided by libhydrogen here. All of
// these functions are cryptographically secure, and are therefore suitable
// for generating random keys, nonces, salts, etc.

#define RANDOM_BYTES_MAX (1 << 27) // (128 MiB) Arbitrary limit

static int luahydro_random_bytes(lua_State *L)
{
    // Process the arguments
    const size_t out_len = (size_t)luaL_checkinteger(L, 1);
    if (out_len == 0 || out_len > RANDOM_BYTES_MAX) {
        return luaL_error(L,
            "libhydrogen.random_bytes: output length must be between 1 and %d",
            RANDOM_BYTES_MAX);
    }

    // Generate the random bytes and return them as a Lua string
    uint8_t *out = xmalloc(out_len);
    hydro_random_buf(out, out_len);

    lua_pushlstring(L, (char *)out, out_len);
    free(out);
    return 1;
}

static int luahydro_random_integer(lua_State *L)
{
    // Process the arguments
    const uint64_t minimum = (uint64_t)luaL_checkinteger(L, 1);
    const uint64_t maximum = (uint64_t)luaL_checkinteger(L, 2);

    if (minimum > maximum) {
        return luaL_error(L,
            "libhydrogen.random_integer: minimum must be less than or equal to maximum");
    }

    const uint64_t range = maximum - minimum;
    if (range > UINT32_MAX - 1) {
        return luaL_error(L,
            "libhydrogen.random_integer: range is too large");
    }

    // Generate a random integer in the specified range and return it as a Lua
    // integer
    const uint64_t result = hydro_random_uniform(range + 1) + minimum;
    lua_pushinteger(L, (lua_Integer)result);
    return 1;
}

// Define the table exported to Lua
static const struct luaL_Reg hydrogenlib[] = {
    {"sign_keygen", luahydro_sign_keygen},
    {"sign_create", luahydro_sign_create},
    {"sign_verify", luahydro_sign_verify},
    {"hash",        luahydro_hash},
    {"hash_keyed",  luahydro_hash_keyed},
    {"hash_keygen", luahydro_hash_keygen},
    {"random_bytes", luahydro_random_bytes},
    {"random_integer", luahydro_random_integer},
    {NULL, NULL} /* sentinel */
};

// Initialize the module
int luaopen_hydrogen(lua_State * L)
{
    if (hydro_init() == 0) {
        luaL_openlib(L, "libhydrogen", hydrogenlib, 0);
    } else {
        lua_pushnil(L);
    }
    return 1;
}
