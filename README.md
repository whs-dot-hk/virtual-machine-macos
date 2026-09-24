# vmagent

Boot a Debian cloud image on macOS. Apple silicon, macOS 13+.

Rust does the setup. A small Swift program (`vmcore`) calls Virtualization.framework, because that framework has no C API and Rust cannot link it.

```bash
scripts/build.sh
scripts/fetch-debian.sh          # once
bin/vmagent --image images/debian.raw
```

A window opens with the guest console. The VM boots the disk with UEFI firmware (`VZEFIBootLoader`); the Debian image then loads its own EFI boot entry. Close the window to stop. The working disk and UEFI variable store are under `/tmp/vmagent-<time>` unless you pass `--dir`.

Login on the nocloud image is usually `debian` / `debian`.
