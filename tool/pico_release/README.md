# Host-only Pico release manifest v1

This package builds and verifies **local fixtures only**. It is not a device
verifier, release discovery client, or publishing workflow. Stable release
publishing remains blocked pending issue #43 qualification. The production
Ed25519 private key must be held outside this repository by a protected job;
never check it in or place it on a Pico.

The v1 host checks enforce a 2048-byte manifest ceiling, at most eight targets
(the app plus seven libraries), a 64-character target name, a 512 KiB per-asset
ceiling, and 1 MiB total assets. These are conservative format/resource bounds,
not a qualified Pico application or storage budget; device qualification remains
required before release.

## v1 format decisions

`manifest.json` is deterministic UTF-8 JSON with sorted object keys, compact
separators, and no ASCII escaping. `manifest.sig` is a detached binary Ed25519
signature over the exact bytes of `manifest.json`. Verification checks the
signature **before** decoding or trusting manifest content. v1 requires exactly
these top-level fields (unknown fields are errors):

```json
{"algorithm":"Ed25519","board":"RPI_PICO2_W","format_version":1,"min_runtime":"v1.29.0","release_id":12,"targets":[{"name":"app.mpy","path":"app.mpy","size_bytes":123,"sha256":"<64 lowercase hex characters>"}]}
```

The `release_id` is a positive integer and the release tag must be exactly
`pico-<release_id>`; Android `v*` tags are not Pico tags. Runtime versions use
`vMAJOR.MINOR.PATCH`, and a candidate requires the specified minimum official
UF2 runtime or newer. Paths are limited to required root `app.mpy` and optional
flat companions `lib/<name>.mpy`. Absolute paths, traversal, backslashes,
symlinks, duplicates, unknown/nested locations and unlisted or missing files
are rejected. Each target binds its filename, path, byte length and SHA-256.
The verifier also supports applied/failed release-ID high-water checks; issue
#36's retained-good recovery exception is intentionally outside this candidate
verification interface.

The host dependency is the already-installed Python `cryptography` package
(Ed25519); CI that runs these checks must install it explicitly. It is not an
application/Flutter dependency. Key input is either 32-byte raw Ed25519 or
PEM/DER PKCS#8 for private keys and PEM/DER SubjectPublicKeyInfo for public
keys. Sign output files are only manifest/signature, not private key material.
The prototype device trust-key slot is exactly 32 raw Ed25519 public-key bytes;
PEM/DER accepted by this host CLI is normalized to raw bytes and must not be
copied to the device as-is. Builders emit canonical JSON, while verification
authenticates exact signed bytes and accepts valid noncanonical JSON as well.

## Local fixture CLI

Run from repository root. The input directory may contain `app.mpy` and
optional flat companions under `lib/`:

```powershell
python -m tool.pico_release.cli sign --release-id 12 --min-runtime v1.29.0 `
  --assets .\fixture-assets --private-key .\fixture-ed25519-private.der `
  --output .\fixture-signed
python -m tool.pico_release.cli verify --manifest .\fixture-signed\manifest.json `
  --signature .\fixture-signed\manifest.sig --assets .\fixture-assets `
  --public-key .\fixture-ed25519-public.der --tag pico-12 --runtime v1.29.0
```

CLI failures print a short error and never print key contents. Tests generate a
fresh ephemeral key in memory and never persist it. Run:

```powershell
python -m unittest discover -s tool/pico_release/tests -v
```

Residual blockers: there is no device-side verifier or production signing
workflow, and host tests do not qualify the Pico runtime, watchdog, power-loss
transaction, TLS, or resource budget. Issue #43 remains a stop/go gate.
