/* MicroPython dynruntime entry point. Inputs are read-only bytes-like buffers. */
#include "py/dynruntime.h"

#include "verifier.h"

static mp_obj_t verify(size_t n_args, const mp_obj_t *args)
{
    mp_buffer_info_t signature_buffer;
    mp_buffer_info_t key_buffer;
    mp_buffer_info_t message_buffer;
    mp_get_buffer_raise(args[0], &signature_buffer, MP_BUFFER_READ);
    mp_get_buffer_raise(args[1], &key_buffer, MP_BUFFER_READ);
    mp_get_buffer_raise(args[2], &message_buffer, MP_BUFFER_READ);

    /* Reject lengths before entering the cryptographic implementation. */
    if (signature_buffer.len != FARMCTL_SIGNATURE_SIZE ||
        key_buffer.len != FARMCTL_PUBLIC_KEY_SIZE ||
        message_buffer.len > FARMCTL_MAX_MESSAGE_SIZE) {
        return mp_const_false;
    }
    return mp_obj_new_bool(farmctl_verify(signature_buffer.buf, signature_buffer.len,
                                          key_buffer.buf, key_buffer.len,
                                          message_buffer.buf, message_buffer.len));
}
static MP_DEFINE_CONST_FUN_OBJ_VAR_BETWEEN(verify_obj, 3, 3, verify);

mp_obj_t mpy_init(mp_obj_fun_bc_t *self, size_t n_args, size_t n_kw, mp_obj_t *args)
{
    (void)n_args;
    (void)n_kw;
    (void)args;
    MP_DYNRUNTIME_INIT_ENTRY

    mp_store_global(MP_QSTR___name__, MP_OBJ_NEW_QSTR(MP_QSTR_verify));
    mp_store_global(MP_QSTR_verify, MP_OBJ_FROM_PTR(&verify_obj));

    MP_DYNRUNTIME_INIT_EXIT
}
