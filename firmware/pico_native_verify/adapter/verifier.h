/* FarmCtl Ed25519 verifier adapter. See PROVENANCE.md for pinned sources. */
#ifndef FARMCTL_VERIFIER_H
#define FARMCTL_VERIFIER_H

#include <stddef.h>
#include <stdint.h>

#define FARMCTL_SIGNATURE_SIZE 64u
#define FARMCTL_PUBLIC_KEY_SIZE 32u
#define FARMCTL_MAX_MESSAGE_SIZE 2048u

/* Returns 1 for a valid signature and 0 for invalid input or forgery. */
int farmctl_verify(const uint8_t *signature, size_t signature_size,
                   const uint8_t *public_key, size_t public_key_size,
                   const uint8_t *message, size_t message_size);

#endif
