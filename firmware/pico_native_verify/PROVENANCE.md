# Native verifier source provenance and status

This directory contains FarmCtl's Ed25519 verification adapter and MicroPython
dynruntime binding. Pinned third-party sources are downloaded to a fresh
external scratch directory by `tool/pico_native_verify/build.ps1`; they are not
vendored here.

## Pinned inputs

| Input | Revision / identity | Archive SHA-256 |
| --- | --- | --- |
| MicroPython | v1.29.0, commit `0fd6c573ea815774668bbb16b8e197c8822368b2` | `77331374753ac6e524b9f7aa606fbcfd1cc2c6ae9fb567c971a2e31cb5de6225` |
| Monocypher | 4.0.3, commit `ab2b16dd619ad5f6979a4fbe69cfa324a6fcc35f` | `60dda1114a817826a0c753275190968e1b4a2d9f7e31e3d6daa09272c4746f5f` |
| Arm GNU Toolchain | 14.3.Rel1, GCC 14.3.1 (Build arm-14.174), target `arm-none-eabi` | `864c0c8815857d68a1bbba2e5e2782255bb922845c71c97636004a3d74f60986` |

The script compiles `native/verify.c`, `adapter/verifier.c`, and the two
unmodified Monocypher sources `src/monocypher.c` and
`src/optional/monocypher-ed25519.c`. The pinned toolchain's `libgcc.a`,
`libm.a`, and `libc.a` are the runtime archives provided to the linker, with
Thumb/Cortex-M3/soft-float flags (`-mfloat-abi=soft`). `mpy_ld.py -vv` emits
the selected `archive:member` trace; the build record preserves the exact
archive paths, selected member names, per-archive hashes, and pinned toolchain
archive origin/hash. MicroPython's linker uses `pyelftools==0.31` (wheel
SHA-256 `f52de7b3c7e8c64c8abc04a79a1cf37ac5fb0b8a49809827130b858944840607`)
and `ar==1.0.1` (wheel SHA-256
`ee6b676acbe1c31b28e108361f23e44432324dafc87a782e9286896bf77dec8e`).

## Build reproducibility

Run `tool/pico_native_verify/build.ps1`. Each invocation creates a unique fresh
directory below the system temporary directory (or
`FARMCTL_PICO_VERIFY_WORK`), fetches every pinned archive anew, and verifies
each archive SHA-256 before extraction. It sets `PYTHONHASHSEED=42`, builds
twice from fresh build subdirectories, and requires identical output sizes and
hashes. Per-build link traces and `build-record.json` capture archive/source/
object hashes, the selected archive members, source revision, Python version,
installed Python package versions, seed, and artifact hash/size. Artifacts
remain `.UNQUALIFIED` and external to the repo. A host-only synthetic fixture
signer is used solely for tests. No production or release private key is
involved and no production signing operation occurs.

## Execution record and limits

The current 42,535-byte `.UNQUALIFIED` artifact has SHA-256
`aede1790ab191a8829a8f4e23bb0711556f8dce4fb6feb9ec1018d7982d8c539`. Its
external fresh-build record and new-binding device result are kept outside the
repository. The device run passed 24 synthetic spare binding checks; its report
is `C:/Users/ghsi0/AppData/Local/Temp/opencode/farmctl-pico-native-verify/NEW-BINDING-DEVICE-RESULTS.md`.
This is a narrow synthetic spare result, not production/device qualification.
Host fixtures use published RFC 8032 vectors and synthetic host signing; they
cover valid/mutated signatures, input lengths, the 2,048-byte boundary,
noncanonical `S+L`, and input types. They are not device qualification.

The binding intentionally accepts read-only MicroPython buffer-protocol inputs
(such as `bytes`, and bytearray/memoryview where supported), rather than
enforcing exact `bytes`. Signature/key/message length guards are applied before
cryptography. The fixed-arity function object enforces three positional
arguments. It does not look up caller globals `bytes` or `TypeError`. Buffer
conversion behavior is not covered by the host adapter tests.

Outstanding before production use: independently reviewed and qualified
binary/source integration; actual RP2350 resource/peak stack and heap bounds;
watchdog/reset behavior; combined-system and recovery tests; firmware loading,
upgrade, rollback and recovery behavior; and integration with the real
update/manifest path. Do not load a `.UNQUALIFIED` artifact into production.

## Distributed license notices — unresolved blocker

The MicroPython MIT notice and chosen Monocypher BSD-2-Clause notice are
verbatim in `LICENSES/`; versions, source archive hashes, and unresolved
toolchain requirements are documented in `NOTICE.md`. The selected runtime
archive members and their exact archive paths/hashes are recorded by the
verbose-link build record. The fresh links selected `_aeabi_uldivmod.o`,
`_udivmoddi4.o`, and `_dvmd_tls.o` from `libgcc.a`, and `libc_a-memcpy.o` and
`libc_a-memset.o` from `libc.a`; no members were selected from `libm.a`. Both
reproducibility outputs selected the same members. The applicable GCC Runtime Library Exception and
newlib notice texts for those members remain unverified and are not fabricated.
Distribution remains blocked until the exact applicable notices are verified
and included in any eventual firmware/package.

Arm's official 14.3.Rel1 source snapshot was downloaded **outside this repository**
and matched the published `.sha256asc` checksum text: SHA-256
`d8676291e48029ba8814037a8c5daa30728e406d0a1ba89f1081470af9175d69`.
Arm's release notes identify GCC revision
`c6ee55bf5766d1d38e57d92e3a757fde4722d55d` and newlib revision
`2f43c4b625a1f72dc794144c799bfa4d9e812716`. Source inspection found
plausible GCC files for `_aeabi_uldivmod.o` and `_udivmoddi4.o`, but did not
map `_dvmd_tls.o` or establish which newlib implementation built either libc
member in the released Windows toolchain. The source checksum does not prove
member-to-source identity or independently authenticate the checksum signature.
Do not distribute the verifier binary on the strength of this snapshot alone.

The device report records in-session cleanup as verified, but the independent
post-disconnect stat is pending: it could not reconnect to a raw-REPL prompt.
Potential leftover paths are listed in that report. No combined TLS/watchdog
power-cut testing or distribution approval is claimed; rollout issue #43
remains open and unpassed.
