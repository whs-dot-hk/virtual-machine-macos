//! Boot Debian on macOS.
//!
//! Apple's Virtualization.framework has no C API, so the VM itself is a tiny
//! Swift program (`vmcore`). This binary does everything else: it copies the
//! cloud image into a working directory, starts that helper, and waits until
//! the window is closed or the guest powers off.
//!
//!   vmagent --image debian.raw
//!
//! Apple silicon, macOS 13+.

use std::fs;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use clap::Parser;

#[derive(Parser)]
#[command(name = "vmagent", version, about = "Boot a Debian cloud image on macOS")]
struct Cli {
    /// Path to a Debian nocloud raw image (arm64 on Apple silicon).
    #[arg(long)]
    image: PathBuf,

    /// Where the working copy of the disk and NVRAM go.
    /// Defaults to a new directory under /tmp.
    #[arg(long)]
    dir: Option<PathBuf>,

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

    let vmcore = find_vmcore();
    eprintln!("booting with {}", vmcore.display());
    eprintln!("login is the cloud image default, usually debian / debian");
    eprintln!("close the window to stop");

    let status = Command::new(&vmcore)
        .arg(disk)
        .arg(dir.join("NVRAM"))
        .arg(cli.cpus.to_string())
        .arg(cli.mem_mb.to_string())
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
