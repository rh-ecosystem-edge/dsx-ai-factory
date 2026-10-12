#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Strip the .cmdline PE section from a UKI EFI binary so systemd-stub falls
# back to LoadOptions (the parameters the bootloader passes via chain/start).
#
# RHEL 10's sd-stub enforces the embedded .cmdline section and ignores
# LoadOptions, unlike Ubuntu's sd-stub which appends LoadOptions in
# non-Secure-Boot mode. For qcow-imager, the imaging parameters
# (image_url, rootfs_label, ds=nocloud-net, etc.) must come from iPXE chain
# arguments — they are per-machine/instance and cannot be baked in.
#
# Usage: strip-cmdline.py <efi-file>
import struct
import sys

path = sys.argv[1]
with open(path, "rb") as f:
    data = bytearray(f.read())

pe_off = struct.unpack_from("<I", data, 0x3c)[0]
num_sections = struct.unpack_from("<H", data, pe_off + 6)[0]
opt_size = struct.unpack_from("<H", data, pe_off + 20)[0]
sect_off = pe_off + 24 + opt_size

found = False
for i in range(num_sections):
    off = sect_off + i * 40
    name = data[off:off + 8].rstrip(b"\x00").decode("latin1")
    if name == ".cmdline":
        vsize = struct.unpack_from("<I", data, off + 16)[0]
        raw_off = struct.unpack_from("<I", data, off + 20)[0]
        original = bytes(data[raw_off:raw_off + min(vsize, 128)]).rstrip(b"\x00")
        print(f"Zeroing .cmdline ({vsize} bytes): {original.decode('utf-8', 'replace')!r}")
        data[raw_off:raw_off + vsize] = b"\x00" * vsize
        found = True

if not found:
    print("WARNING: .cmdline section not found — nothing to strip")
    sys.exit(0)

with open(path, "wb") as f:
    f.write(data)
print(f"Written {len(data)} bytes to {path}")
