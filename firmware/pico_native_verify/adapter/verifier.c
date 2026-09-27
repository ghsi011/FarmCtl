/* FarmCtl Ed25519 verifier adapter; no signing interface is provided. */
#include "verifier.h"

#include "monocypher-ed25519.h"

int farmctl_verify(const uint8_t *signature, size_t signature_size,
                   const uint8_t *public_key, size_t public_key_size,
                   const uint8_t *message, size_t message_size)
{
    if (signature_size != FARMCTL_SIGNATURE_SIZE ||
        public_key_size != FARMCTL_PUBLIC_KEY_SIZE ||
        message_size > FARMCTL_MAX_MESSAGE_SIZE) {
        return 0;
    }
    if (signature == NULL || public_key == NULL ||
        (message_size != 0u && message == NULL)) {
        return 0;
    }

    /* Monocypher returns 0 for success and -1 for a forgery. */
    return crypto_ed25519_check(signature, public_key, message, message_size) == 0;
}
