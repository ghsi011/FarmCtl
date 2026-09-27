"""The 17 synthetic native-verifier fixtures; requires compiled host libraries."""
import ctypes
import os
import unittest

LIBRARY = os.environ.get("FARMCTL_VERIFY_LIBRARY")
SIGNER = os.environ.get("FARMCTL_FIXTURE_SIGNER")
V1_KEY = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
V1_SIG = bytes.fromhex(
    "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
    "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
V2_KEY = bytes.fromhex("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")
V2_SIG = bytes.fromhex(
    "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
    "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00")
V3_KEY = bytes.fromhex("fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025")
V3_SIG = bytes.fromhex(
    "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac"
    "18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a")
ORDER_L = int("1000000000000000000000000000000014def9dea2f79cd65812631a5cf5d3ed", 16)


@unittest.skipUnless(LIBRARY and SIGNER, "build host libraries with test_host.ps1")
class VerifierFixtures(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.library = ctypes.CDLL(LIBRARY)
        cls.verify = cls.library.farmctl_verify
        cls.verify.argtypes = [ctypes.c_void_p, ctypes.c_size_t,
                               ctypes.c_void_p, ctypes.c_size_t,
                               ctypes.c_void_p, ctypes.c_size_t]
        cls.verify.restype = ctypes.c_int
        cls.signer = ctypes.CDLL(SIGNER)
        cls.signer.farmctl_fixture_sign.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                                    ctypes.c_void_p, ctypes.c_size_t]
        cls.signer.farmctl_fixture_sign.restype = None

    def check(self, signature, key, message):
        def ptr(data):
            return ctypes.cast(ctypes.create_string_buffer(data), ctypes.c_void_p) if data else None
        return bool(self.verify(ptr(signature), len(signature), ptr(key), len(key),
                                ptr(message), len(message)))

    def api_verify(self, signature, key, message):
        if not all(isinstance(value, bytes) for value in (signature, key, message)):
            raise TypeError("verify arguments must be bytes")
        if len(signature) != 64 or len(key) != 32 or len(message) > 2048:
            return False
        return self.check(signature, key, message)

    def sign(self, message):
        sig, key = ctypes.create_string_buffer(64), ctypes.create_string_buffer(32)
        msg = ctypes.create_string_buffer(message) if message else None
        self.signer.farmctl_fixture_sign(sig, key,
            ctypes.cast(msg, ctypes.c_void_p) if msg is not None else None, len(message))
        return sig.raw, key.raw

    def test_rfc8032_test_1(self): self.assertTrue(self.check(V1_SIG, V1_KEY, b""))
    def test_rfc8032_test_2(self): self.assertTrue(self.check(V2_SIG, V2_KEY, b"\x72"))
    def test_rfc8032_test_3(self): self.assertTrue(self.check(V3_SIG, V3_KEY, b"\xaf\x82"))
    def test_wrong_key(self): self.assertFalse(self.check(V1_SIG, b"\0" * 32, b""))
    def test_bit_flipped_signature(self): self.assertFalse(self.check(bytes([V1_SIG[0] ^ 1]) + V1_SIG[1:], V1_KEY, b""))
    def test_bit_flipped_message(self): self.assertFalse(self.check(V1_SIG, V1_KEY, b"changed"))
    def test_short_signature(self): self.assertFalse(self.check(V1_SIG[:-1], V1_KEY, b""))
    def test_extra_signature(self): self.assertFalse(self.check(V1_SIG + b"\0", V1_KEY, b""))
    def test_short_key(self): self.assertFalse(self.check(V1_SIG, V1_KEY[:-1], b""))
    def test_extra_key(self): self.assertFalse(self.check(V1_SIG, V1_KEY + b"\0", b""))

    def test_signed_2048_valid(self):
        message = bytes(range(256)) * 8
        signature, key = self.sign(message)
        self.assertTrue(self.check(signature, key, message))

    def test_signed_2049_invalid(self):
        message = bytes(range(256)) * 8 + b"x"
        signature, key = self.sign(message)
        # Exercise the C adapter directly: do not let the Python-side API
        # shim reject this before the adapter's maximum-length guard.
        self.assertFalse(self.check(signature, key, message))

    def test_adapter_rejects_null_signature(self):
        self.assertFalse(self.verify(None, 64, ctypes.c_char_p(V1_KEY), 32, None, 0))

    def test_adapter_rejects_null_key(self):
        self.assertFalse(self.verify(ctypes.c_char_p(V1_SIG), 64, None, 32, None, 0))

    def test_adapter_rejects_null_nonempty_message(self):
        self.assertFalse(self.verify(ctypes.c_char_p(V1_SIG), 64,
                                     ctypes.c_char_p(V1_KEY), 32, None, 1))

    def test_adapter_rejects_bad_signature_and_key_lengths(self):
        self.assertFalse(self.verify(ctypes.c_char_p(V1_SIG), 63,
                                     ctypes.c_char_p(V1_KEY), 32, None, 0))
        self.assertFalse(self.verify(ctypes.c_char_p(V1_SIG), 64,
                                     ctypes.c_char_p(V1_KEY), 31, None, 0))

    def test_noncanonical_s_plus_l(self):
        scalar = int.from_bytes(V1_SIG[32:], "little") + ORDER_L
        self.assertFalse(self.check(V1_SIG[:32] + scalar.to_bytes(32, "little"), V1_KEY, b""))

    def test_wrong_signature_buffer_type(self):
        with self.assertRaises(TypeError): self.api_verify("sig", V1_KEY, b"")
    def test_wrong_key_buffer_type(self):
        with self.assertRaises(TypeError): self.api_verify(V1_SIG, "key", b"")
    def test_wrong_message_buffer_type(self):
        with self.assertRaises(TypeError): self.api_verify(V1_SIG, V1_KEY, "message")
    def test_integer_buffer_type(self):
        with self.assertRaises(TypeError): self.api_verify(1, V1_KEY, b"")


if __name__ == "__main__":
    unittest.main(verbosity=2)
