//! Boot Debian on macOS.
//!
//! Apple's Virtualization.framework has no C API, so the VM itself is a tiny
//! Swift program (`vmcore`). This binary copies the cloud image, splits the
//! kernel and initrd out of it, and starts that helper.
//!
//!   vmagent --image debian.raw --user-data cloud-init/user-data --meta-data cloud-init/meta-data
//!
//! Apple silicon, macOS 13+.

use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use clap::Parser;

#[derive(Parser)]
#[command(name = "vmagent", version, about = "Boot a Debian cloud image on macOS")]
struct Cli {
    /// Path to a Debian generic raw image (arm64 on Apple silicon).
    #[arg(long)]
    image: PathBuf,

    /// Where the working disk, kernel, and initrd go.
    /// Defaults to a new directory under /tmp.
    #[arg(long)]
    dir: Option<PathBuf>,

    /// cloud-config. Must start with `#cloud-config`. Attached as a cidata disk.
    #[arg(long)]
    user_data: Option<PathBuf>,

    /// cloud-init meta-data. Defaults to a one-line instance-id if omitted.
    #[arg(long)]
    meta_data: Option<PathBuf>,

    #[arg(long, default_value_t = 2)]
    cpus: u32,

    #[arg(long, default_value_t = 2048)]
    mem_mb: u64,
}

fn main() {
    let cli = Cli::parse();

    if !cfg!(target_os = "macos") {
        die("this only runs on macOS");
    }
    if !cli.image.is_file() {
        die(&format!("image not found: {}", cli.image.display()));
    }

    let dir = cli.dir.unwrap_or_else(tmp_dir);
    if let Err(e) = fs::create_dir_all(&dir) {
        die(&format!("cannot create {}: {e}", dir.display()));
    }

    let disk = dir.join("disk.img");
    if !disk.exists() {
        eprintln!("copying image to {}", disk.display());
        if let Err(e) = fs::copy(&cli.image, &disk) {
            die(&format!("copy failed: {e}"));
        }
    }

    let cloud_init = match (&cli.user_data, &cli.meta_data) {
        (None, None) => None,
        _ => Some(write_cidata(&dir, cli.user_data.as_deref(), cli.meta_data.as_deref())),
    };

    let append = if cloud_init.is_some() { "ds=nocloud" } else { "" };
    let cmdline = split_image(&disk, &dir, append);
    eprintln!("kernel command line: {cmdline}");

    let vmcore = find_vmcore();
    eprintln!("booting with {}", vmcore.display());
    if cloud_init.is_none() {
        eprintln!("no user-data: the generic image has no default login");
    }
    eprintln!("close the window to stop");

    let mut cmd = Command::new(&vmcore);
    cmd.arg(&disk)
        .arg(dir.join("vmlinuz"))
        .arg(dir.join("initrd"))
        .arg(&cmdline)
        .arg(cli.cpus.to_string())
        .arg(cli.mem_mb.to_string());
    if let Some(cloud_init) = &cloud_init {
        cmd.arg(cloud_init);
    }
    let status = cmd
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status();

    match status {
        Ok(s) if s.success() => {}
        Ok(s) => std::process::exit(s.code().unwrap_or(1)),
        Err(e) => die(&format!("failed to run {}: {e}", vmcore.display())),
    }
}

/// Pull vmlinuz, initrd, and the grub root= line out of the disk.
fn split_image(disk: &Path, dir: &Path, append: &str) -> String {
    let script = find_script();
    let out = Command::new("python3")
        .arg(&script)
        .arg(disk)
        .arg(dir)
        .arg("--append")
        .arg(append)
        .output()
        .unwrap_or_else(|e| die(&format!("cannot run {}: {e}", script.display())));
    if !out.status.success() {
        eprint!("{}", String::from_utf8_lossy(&out.stderr));
        die("failed to split kernel and initrd out of the image");
    }
    let line = String::from_utf8_lossy(&out.stdout);
    let line = line.trim();
    if line.is_empty() {
        die("split produced an empty command line");
    }
    line.to_string()
}

fn find_script() -> PathBuf {
    if let Some(p) = std::env::var_os("SPLIT_IMAGE") {
        return PathBuf::from(p);
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let next_to = dir.join("split-image.py");
            if next_to.is_file() {
                return next_to;
            }
        }
    }
    PathBuf::from("scripts/split-image.py")
}

/// Cloud-init config: an 8 MiB FAT image labeled `cidata` with user-data and meta-data.
/// Built with hdiutil so this stays a Mac tool and does not need mtools.
fn write_cidata(dir: &Path, user_data: Option<&Path>, meta_data: Option<&Path>) -> PathBuf {
    let user = match user_data {
        Some(p) => fs::read(p).unwrap_or_else(|e| die(&format!("cannot read {}: {e}", p.display()))),
        None => b"#cloud-config\n".to_vec(),
    };
    if !user.starts_with(b"#cloud-config") {
        die("user-data must start with #cloud-config");
    }
    let meta = match meta_data {
        Some(p) => fs::read(p).unwrap_or_else(|e| die(&format!("cannot read {}: {e}", p.display()))),
        None => b"instance-id: vmagent-1\nlocal-hostname: debian\n".to_vec(),
    };

    let staging = dir.join("cidata-src");
    if let Err(e) = fs::create_dir_all(&staging) {
        die(&format!("cannot create {}: {e}", staging.display()));
    }
    write_file(&staging.join("user-data"), &user);
    write_file(&staging.join("meta-data"), &meta);

    let img = dir.join("cidata.raw");
    let _ = fs::remove_file(&img);
    let status = Command::new("hdiutil")
        .args([
            "create",
            "-size",
            "8m",
            "-fs",
            "MS-DOS",
            "-volname",
            "cidata",
            "-format",
            "UDRW",
            "-srcfolder",
            &staging.display().to_string(),
            "-ov",
        ])
        .arg(&img)
        .status();
    match status {
        Ok(s) if s.success() => {}
        Ok(s) => die(&format!("hdiutil exited {}", s.code().unwrap_or(1))),
        Err(e) => die(&format!("hdiutil failed: {e}")),
    }
    if !img.is_file() {
        let dmg = dir.join("cidata.raw.dmg");
        if dmg.is_file() {
            if let Err(e) = fs::rename(&dmg, &img) {
                die(&format!("cannot rename {}: {e}", dmg.display()));
            }
        } else {
            die("hdiutil did not write cidata.raw");
        }
    }
    img
}

fn write_file(path: &Path, bytes: &[u8]) {
    let mut f = File::create(path).unwrap_or_else(|e| die(&format!("cannot write {}: {e}", path.display())));
    if let Err(e) = f.write_all(bytes) {
        die(&format!("cannot write {}: {e}", path.display()));
    }
}

fn tmp_dir() -> PathBuf {
    let n = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    PathBuf::from(format!("/tmp/vmagent-{n}"))
}

/// vmcore sits next to this binary, or at VMCORE=/path, or in ./vmcore after a local build.
fn find_vmcore() -> PathBuf {
    if let Some(p) = std::env::var_os("VMCORE") {
        return PathBuf::from(p);
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let next_to = dir.join("vmcore");
            if next_to.is_file() {
                return next_to;
            }
        }
    }
    PathBuf::from("bin/vmcore")
}

fn die(msg: &str) -> ! {
    eprintln!("vmagent: {msg}");
    std::process::exit(1);
}
