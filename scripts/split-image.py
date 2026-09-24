#!/usr/bin/env python3
"""Split a Debian cloud raw disk into kernel, initrd, and a command line.

The kernel and initrd live in /boot on the ext4 root, not on the ESP.
vmlinuz is an uncompressed ARM64 Image (the EFI stub is only a header).
The root= argument is copied from grub.cfg.
"""

import argparse
import os
import struct
import sys

BLOCK = 4096


class Ext4:
    def __init__(self, path, part_off):
        self.f = open(path, "rb")
        self.part = part_off
        sb = self._read(1024, 1024)
        if struct.unpack_from("<H", sb, 0x38)[0] != 0xEF53:
            raise SystemExit("root partition is not ext4")
        self.ipg = struct.unpack_from("<I", sb, 0x28)[0]
        self.inode_size = struct.unpack_from("<H", sb, 0x58)[0]
        self.desc_size = struct.unpack_from("<H", sb, 0xFE)[0] or 32
        if not (struct.unpack_from("<I", sb, 0x60)[0] & 0x40):
            raise SystemExit("ext4 without extents is not supported")

    def _read(self, off, n):
        self.f.seek(self.part + off)
        data = self.f.read(n)
        if len(data) != n:
            raise SystemExit("short read in disk image")
        return data

    def _inode_table(self, group):
        e = self._read(BLOCK + group * self.desc_size, self.desc_size)
        lo = struct.unpack_from("<I", e, 8)[0]
        hi = struct.unpack_from("<I", e, 0x28)[0] if self.desc_size >= 0x2C else 0
        return lo | (hi << 32)

    def inode(self, ino):
        group, index = divmod(ino - 1, self.ipg)
        off = self._inode_table(group) * BLOCK + index * self.inode_size
        raw = self._read(off, self.inode_size)
        mode = struct.unpack_from("<H", raw, 0)[0]
        size = struct.unpack_from("<I", raw, 4)[0] | (struct.unpack_from("<I", raw, 108)[0] << 32)
        return mode, size, raw

    def _extents(self, raw):
        magic, entries, _, depth = struct.unpack_from("<HHHI", raw, 40)
        if magic != 0xF30A:
            raise SystemExit("inode is not extent-based")
        out = []

        def walk(buf, count, depth):
            for i in range(count):
                e = buf[i * 12:(i + 1) * 12]
                if depth == 0:
                    logical, length, hi, lo = struct.unpack("<IHHI", e)
                    out.append((logical, lo | (hi << 32), length & 0x7FFF))
                else:
                    _, lo, hi, _ = struct.unpack("<IIHH", e)
                    blk = self._read((lo | (hi << 32)) * BLOCK, BLOCK)
                    h = struct.unpack_from("<HHHI", blk)
                    walk(blk[12:12 + h[1] * 12], h[1], depth - 1)

        walk(raw[52:52 + entries * 12], entries, depth)
        return out

    def read_file(self, ino):
        mode, size, raw = self.inode(ino)
        if (mode & 0xF000) == 0xA000 and size < 60:
            return mode, raw[40:40 + size]
        data = bytearray(size)
        for logical, phys, length in self._extents(raw):
            chunk = self._read(phys * BLOCK, length * BLOCK)
            start = logical * BLOCK
            n = max(0, size - start)
            data[start:start + n] = chunk[:n]
        return mode, bytes(data)

    def lookup(self, path):
        ino = 2
        for part in path.strip("/").split("/"):
            mode, data = self.read_file(ino)
            if (mode & 0xF000) != 0x4000:
                raise SystemExit(f"not a directory: {path}")
            found = None
            i = 0
            while i + 8 <= len(data):
                child, rec, name_len, _ = struct.unpack_from("<IHBB", data, i)
                if rec < 8:
                    break
                name = data[i + 8:i + 8 + name_len].decode()
                if child and name == part:
                    found = child
                    break
                i += rec
            if found is None:
                raise SystemExit(f"not in image: {path}")
            ino = found
        return ino


def gpt_root(path):
    with open(path, "rb") as f:
        f.seek(512)
        hdr = f.read(92)
        if hdr[:8] != b"EFI PART":
            raise SystemExit("not a GPT disk")
        ents = struct.unpack_from("<I", hdr, 80)[0]
        esz = struct.unpack_from("<I", hdr, 84)[0]
        lba = struct.unpack_from("<Q", hdr, 72)[0]
        f.seek(lba * 512)
        linux = bytes.fromhex("45b021b9f01dc341af444c6f280d3fae")
        for _ in range(ents):
            e = f.read(esz)
            if e[:16] == linux:
                return struct.unpack_from("<Q", e, 32)[0] * 512
    raise SystemExit("no Linux filesystem partition")


def kernel_image(blob):
    """Debian's arm64 vmlinuz is an uncompressed Image that also has an EFI stub.

    The boot header magic sits at offset 0x38. Virtualization.framework accepts
    that file as-is. The .text section is not a standalone Image.
    """
    if len(blob) < 0x40 or blob[0x38:0x3C] != b"ARM\x64":
        raise SystemExit("vmlinuz is not an uncompressed ARM64 Image")
    return blob


def linux_line(grub_cfg):
    for line in grub_cfg.splitlines():
        line = line.strip()
        if line.startswith("linux") and "root=" in line:
            parts = line.split()
            # linux /boot/vmlinuz-... root=PARTUUID=... ro
            return parts[1], parts[2:]
    raise SystemExit("grub.cfg has no linux root= line")


def command_line(args, extra):
    if extra:
        args = args + extra.split()
    return " ".join(args)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("outdir")
    ap.add_argument("--append", default="", help="extra kernel args, e.g. ds=nocloud")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    fs = Ext4(args.image, gpt_root(args.image))
    _, grub = fs.read_file(fs.lookup("/boot/grub/grub.cfg"))
    grub = grub.decode()
    kernel_path, kargs = linux_line(grub)
    cmdline = command_line(kargs, args.append)
    # Cloud images often have no /boot/vmlinuz symlink. GRUB names the real file.
    _, kernel = fs.read_file(fs.lookup(kernel_path))
    initrd_path = kernel_path.replace("/vmlinuz-", "/initrd.img-")
    if initrd_path == kernel_path:
        initrd_path = "/boot/initrd.img"
    _, initrd = fs.read_file(fs.lookup(initrd_path))
    kernel = kernel_image(kernel)

    kpath = os.path.join(args.outdir, "vmlinuz")
    ipath = os.path.join(args.outdir, "initrd")
    cpath = os.path.join(args.outdir, "cmdline")
    for path, data in ((kpath, kernel), (ipath, initrd), (cpath, (cmdline + "\n").encode())):
        with open(path, "wb") as f:
            f.write(data)
    print(cmdline)


if __name__ == "__main__":
    main()
