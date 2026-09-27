/* Test-only signer for the published RFC8032 test-1 seed. Never for releases. */
#include <stddef.h>
#include <stdint.h>

#include "monocypher-ed25519.h"

void farmctl_fixture_sign(uint8_t signature[64], uint8_t public_key[32],
                          const uint8_t *message, size_t message_size)
{
    uint8_t seed[32] = {
        0x9d,0x61,0xb1,0x9d,0xef,0xfd,0x5a,0x60,0xba,0x84,0x4a,0xf4,0x92,0xec,0x2c,0xc4,
        0x44,0x49,0xc5,0x69,0x7b,0x32,0x69,0x19,0x70,0x3b,0xac,0x03,0x1c,0xae,0x7f,0x60
    };
    uint8_t secret_key[64];
    crypto_ed25519_key_pair(secret_key, public_key, seed);
    crypto_ed25519_sign(signature, secret_key, message, message_size);
    crypto_wipe(secret_key, sizeof(secret_key));
}
