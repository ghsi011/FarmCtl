# Third-party notices and distribution status

This verifier is built from MicroPython v1.29.0 (commit
`0fd6c573ea815774668bbb16b8e197c8822368b2`, source archive SHA-256
`77331374753ac6e524b9f7aa606fbcfd1cc2c6ae9fb567c971a2e31cb5de6225`) and
Monocypher 4.0.3 (commit `ab2b16dd619ad5f6979a4fbe69cfa324a6fcc35f`, source
archive SHA-256 `60dda1114a817826a0c753275190968e1b4a2d9f7e31e3d6daa09272c4746f5f`).
The MicroPython MIT notice is reproduced in
`LICENSES/MIT-MicroPython.txt`. Monocypher's dual license permits choosing
either BSD-2-Clause or CC0; this project elects BSD-2-Clause, reproduced in
`LICENSES/BSD-2-Clause-Monocypher.txt`.

The build also links selected members of the pinned Arm GNU Toolchain 14.3.Rel1
archive (GCC 14.3.1, build arm-14.174; archive SHA-256
`864c0c8815857d68a1bbba2e5e2782255bb922845c71c97636004a3d74f60986`), from
`libgcc.a`, `libm.a`, and `libc.a`. The exact selected member names, archive
paths, and hashes are captured by `build-record.json` from the verbose linker
trace. In the fresh verifier link, `libgcc.a` supplied `_aeabi_uldivmod.o`,
`_udivmoddi4.o`, and `_dvmd_tls.o`; `libc.a` supplied `libc_a-memcpy.o` and
`libc_a-memset.o`; no member was selected from `libm.a`. These member sets were
identical in both reproducibility builds. The applicable GCC Runtime Library Exception and newlib notice texts
for those selected members have not been verified and are not included here.

**Distribution is blocked.** Any eventual firmware/package containing this
verifier must include these notice files and the exact applicable verified
GCC/newlib notices for the selected archive members. Do not distribute until
the missing toolchain notice review is complete. These files do not constitute
legal approval or a complete distribution notice set.
