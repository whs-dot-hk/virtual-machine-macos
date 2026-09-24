# vmagent

Boot a Debian cloud image on macOS. Apple silicon, macOS 13+.

Rust does the setup. A small Swift program (`vmcore`) calls Virtualization.framework, because that framework has no C API and Rust cannot link it.

```bash
scripts/build.sh
scripts/fetch-debian.sh          # once
bin/vmagent --image images/debian.raw
bin/vmagent --image images/debian.raw --user-data seed/user-data --meta-data seed/meta-data
```

A window opens with the guest console. The VM boots the disk with `VZEFIBootLoader`, the same path as Apple's GUI Linux sample. The Debian image then loads its own boot entry. Close the window to stop. The working disk and `NVRAM` (the EFI variable store) are under `/tmp/vmagent-<time>` unless you pass `--dir`.

Login on the nocloud image is usually `debian` / `debian`. Pass `--user-data` to attach a NoCloud seed disk labeled `cidata` instead. `user-data` must start with `#cloud-config`. Cloud-init applies it once per `instance-id`.
