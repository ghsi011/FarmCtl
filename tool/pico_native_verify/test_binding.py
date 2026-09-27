"""Manual MicroPython smoke test for verify.mpy; run on a disposable device."""
import verify as verifier

verify_alias = verifier.verify
signature = bytes.fromhex(
    "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
    "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
)
public_key = bytes.fromhex(
    "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
)

# Shadow names in the caller module after capturing the alias. The native
# binding must not consult these caller globals for type checks or exceptions.
bytes = lambda *args: None
TypeError = object()

assert verify_alias(signature, public_key, b"") is True
assert verify_alias(bytearray(signature), bytearray(public_key), b"") is True
assert verify_alias(memoryview(signature), memoryview(public_key), b"") is True
assert verify_alias(signature, public_key, bytearray()) is True
assert verify_alias(signature[:-1], public_key, b"") is False
print("native verifier binding smoke test passed")
