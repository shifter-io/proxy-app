//! Small C ABI around pinned Velopack. Network access is deliberately absent:
//! Dart authenticates the feed, and this bridge rehashes bytes before Velopack
//! can inspect or extract any package.
use fs2::FileExt;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    ffi::{c_char, CStr, CString},
    fs::{self, File, OpenOptions},
    io::Read,
    path::{Path, PathBuf},
};
use velopack::{
    locator::{auto_locate_app_manifest, LocationContext, VelopackLocatorConfig},
    sources::FileSource,
    UpdateCheck, UpdateManager, UpdateOptions, VelopackApp,
};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
fn private_dir(path: &Path) -> Result<()> {
    if let Ok(m) = fs::symlink_metadata(path) {
        if !m.is_dir() || m.file_type().is_symlink() {
            return Err("Unsafe staging directory".into());
        }
    }
    fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}
fn config() -> Result<VelopackLocatorConfig> {
    let l = auto_locate_app_manifest(LocationContext::FromCurrentExe)?;
    let root = l.get_root_dir();
    let bins = l.get_current_bin_dir();
    let mut manifest = bins.join("sq.version");
    if !manifest.exists() {
        manifest = root.join("Contents/Resources/sq.version");
    }
    #[cfg(not(target_os = "linux"))]
    let packages = l.get_packages_dir().join("shifter-verified-v1");
    #[cfg(target_os = "linux")]
    let packages = root
        .parent()
        .ok_or("No AppImage parent")?
        .join(".shifter-updates");
    private_dir(&packages)?;
    Ok(VelopackLocatorConfig {
        RootAppDir: root,
        UpdateExePath: l.get_update_path(),
        PackagesDir: packages,
        ManifestPath: manifest,
        CurrentBinaryDir: bins,
        IsPortable: l.get_is_portable(),
    })
}
fn verify(path: &Path, length: u64, hash: &str) -> Result<()> {
    let meta = fs::symlink_metadata(path)?;
    if !meta.is_file() || meta.file_type().is_symlink() || meta.len() != length {
        return Err("Invalid package length or path".into());
    }
    let mut f = File::open(path)?;
    let mut digest = Sha256::new();
    let mut buf = [0; 65536];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        digest.update(&buf[..n]);
    }
    if format!("{:x}", digest.finalize()) != hash {
        return Err("Invalid package checksum".into());
    }
    Ok(())
}

/// Called by each native runner before Flutter. Use an empty package directory
/// so even metadata parsing never touches an unauthenticated pending package.
#[no_mangle]
pub extern "C" fn shifter_update_bootstrap() {
    let _ = std::panic::catch_unwind(|| {
        if let Ok(mut c) = config() {
            c.PackagesDir = c.PackagesDir.join("bootstrap-empty");
            if private_dir(&c.PackagesDir).is_err() {
                return;
            }
            if fs::read_dir(&c.PackagesDir)
                .map(|mut d| d.next().is_some())
                .unwrap_or(true)
            {
                return;
            }
            VelopackApp::build()
                .set_auto_apply_on_startup(false)
                .set_locator(c)
                .run();
        }
        // Unpackaged or unsafe installations never fall back to inspecting
        // Velopack's default cache. Ordinary application startup may continue.
    });
}
fn execute(v: Value) -> Result<Value> {
    let method = v["method"].as_str().ok_or("Missing method")?;
    let c = config()?;
    if method == "identity" {
        let m = c.load_manifest()?;
        return Ok(
            json!({"version": m.version.to_string(), "packageId": m.id, "install": !cfg!(target_os = "linux")}),
        );
    }
    if cfg!(target_os = "linux") {
        return Err("Linux automatic installation awaits no-elevation qualification. Install the new AppImage manually.".into());
    }
    let lock_path = c.PackagesDir.join("shifter-install.lock");
    if fs::symlink_metadata(&lock_path)
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false)
    {
        return Err("Unsafe lock file".into());
    }
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(lock_path)?;
    lock.try_lock_exclusive()?;
    let release = &v["release"];
    let artifact = &release["artifact"];
    let path = PathBuf::from(v["path"].as_str().ok_or("Missing package path")?);
    let length = artifact["byteLength"].as_u64().ok_or("Invalid size")?;
    let hash = artifact["sha256"].as_str().ok_or("Missing hash")?;
    if hash.len() != 64 || !hash.bytes().all(|c| c.is_ascii_hexdigit()) {
        return Err("Invalid hash".into());
    }
    verify(&path, length, hash)?;
    if method == "prepare" {
        return Ok(json!({}));
    }
    if method != "install" {
        return Err("Unknown operation".into());
    }
    let current = c.load_manifest()?;
    let version = release["displayVersion"]
        .as_str()
        .ok_or("Missing version")?;
    if !current
        .id
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-' || c == '_')
        || !version.chars().all(|c| c.is_ascii_digit() || c == '.')
    {
        return Err("Unsafe package identity".into());
    }
    let source = c.PackagesDir.join("authenticated-source");
    private_dir(&source)?;
    let name = format!("{}-{}-full.nupkg", current.id, version);
    let source_file = source.join(&name);
    if source_file.exists() {
        fs::remove_file(&source_file)?;
    }
    fs::copy(&path, &source_file)?;
    verify(&source_file, length, hash)?;
    let asset = json!({"PackageId":current.id,"Version":version,"Type":"Full","FileName":name,"SHA256":hash,"SHA1":"","Size":length,"NotesMarkdown":"","NotesHtml":""});
    fs::write(
        source.join("releases.stable.json"),
        serde_json::to_vec(&json!({"Assets":[asset]}))?,
    )?;
    let destination = c.PackagesDir.join(&name);
    // Never let the library's existing-file shortcut trust an unverified cache.
    if destination.exists() {
        verify(&destination, length, hash)?;
    }
    let options = UpdateOptions {
        ExplicitChannel: Some("stable".into()),
        MaximumDeltasBeforeFallback: -1,
        AllowVersionDowngrade: false,
    };
    let manager = UpdateManager::new(FileSource::new(&source), Some(options), Some(c))?;
    let UpdateCheck::UpdateAvailable(update) = manager.check_for_updates()? else {
        return Err("No strictly newer package".into());
    };
    manager.download_updates(&update, None)?;
    verify(&destination, length, hash)?;
    // The Dart caller has already restored OS routing and persisted recovery state.
    // This call arms the helper and exits; the process lock lives until exit.
    manager.apply_updates_and_restart(&*update)?;
    Ok(json!({}))
}

/// # Safety
/// `input` must be a non-null NUL-terminated UTF-8 JSON string. The caller owns
/// input and must free the returned allocation using shifter_update_free.
#[no_mangle]
pub unsafe extern "C" fn shifter_update_call(input: *const c_char) -> *mut c_char {
    let response = std::panic::catch_unwind(|| {
        if input.is_null() { return json!({"error":"Missing request"}); }
        let result = CStr::from_ptr(input).to_str().map_err(|e| e.into())
            .and_then(|s| serde_json::from_str(s).map_err(|e| e.into())).and_then(execute);
        match result { Ok(value) => json!({"result":value}), Err(_) => json!({"error":"Native update validation failed. Check installation permissions and retry."}) }
    }).unwrap_or_else(|_| json!({"error":"Native updater failed safely."}));
    CString::new(response.to_string()).unwrap().into_raw()
}
/// # Safety
/// `value` must be a pointer returned by shifter_update_call and freed only once.
#[no_mangle]
pub unsafe extern "C" fn shifter_update_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_corruption_and_symlinks() {
        let dir = std::env::temp_dir().join(format!("shifter-hash-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let file = dir.join("pkg");
        fs::write(&file, b"abc").unwrap();
        let hash = format!("{:x}", Sha256::digest(b"abc"));
        assert!(verify(&file, 3, &hash).is_ok());
        assert!(verify(&file, 4, &hash).is_err());
        fs::write(&file, b"def").unwrap();
        assert!(verify(&file, 3, &hash).is_err());
        #[cfg(unix)]
        {
            let link = dir.join("link");
            std::os::unix::fs::symlink(&file, &link).unwrap();
            assert!(verify(&link, 3, &hash).is_err());
        }
        fs::remove_dir_all(dir).unwrap();
    }
}
