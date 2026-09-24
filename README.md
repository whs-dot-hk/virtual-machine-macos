# vmagent

Boot a Debian cloud image on macOS. Apple silicon, macOS 13+.

Rust does the setup. A small Swift program (`vmcore`) calls Virtualization.framework, because that framework has no C API and Rust cannot link it.

```bash
scripts/build.sh
scripts/fetch-debian.sh          # once
bin/vmagent --image images/debian.raw
bin/vmagent --image images/debian.raw --user-data seed/user-data --meta-data seed/meta-data
```

A window opens with the guest console. The disk is not booted through GRUB. `vmagent` splits `vmlinuz` and `initrd.img` out of `/boot` and `vmcore` starts them with `VZLinuxBootLoader`. The kernel file Debian ships is already an uncompressed ARM64 Image (it also has an EFI stub). `root=` is copied from `grub.cfg`. Close the window to stop. The working disk, kernel, and initrd are under `/tmp/vmagent-<time>` unless you pass `--dir`.

The generic image has no default password. Pass `--user-data` so cloud-init can create one. That attaches a NoCloud seed disk labeled `cidata` and adds `ds=nocloud` to the kernel command line. `user-data` must start with `#cloud-config`. Cloud-init applies it once per `instance-id`. The nocloud image is not used: it does not ship cloud-init, so the seed is ignored.
