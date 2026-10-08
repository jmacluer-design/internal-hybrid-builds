use std::path::{Path, PathBuf};
use std::sync::Mutex;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Picked {
    Idle,
    Open,
    Cancelled,
    Done(String),
    Failed(String),
}

static STATE: Mutex<Picked> = Mutex::new(Picked::Idle);

fn set(p: Picked) {
    *STATE.lock().unwrap_or_else(|e| e.into_inner()) = p;
}

pub fn take() -> Picked {
    let mut s = STATE.lock().unwrap_or_else(|e| e.into_inner());
    match &*s {
        Picked::Open | Picked::Idle => s.clone(),
        _ => std::mem::replace(&mut *s, Picked::Idle),
    }
}

pub fn image_kind(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("png")
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some("jpg")
    } else {
        None
    }
}

pub fn clean_name(original: &str, kind: &str) -> String {
    let stem = Path::new(original).file_stem().and_then(|s| s.to_str()).unwrap_or("image");
    let mut out: String = stem
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || " _-()".contains(c) { c } else { '_' })
        .collect();
    out = out.trim().chars().take(48).collect();
    if out.is_empty() {
        out = "image".into();
    }
    format!("{out}.{kind}")
}

pub fn copy_into(source: &Path, dir: &Path) -> Result<String, String> {
    let bytes = std::fs::read(source).map_err(|e| format!("couldn't read {}: {e}", source.display()))?;
    let kind = image_kind(&bytes).ok_or("that isn't a PNG or JPG image")?;
    std::fs::create_dir_all(dir).map_err(|e| format!("couldn't make {}: {e}", dir.display()))?;
    let name = clean_name(&source.file_name().and_then(|s| s.to_str()).map(str::to_owned).unwrap_or_default(), kind);
    let (stem, ext) = name.rsplit_once('.').unwrap_or((&name, kind));
    for n in 1..1000 {
        let candidate = if n == 1 { name.clone() } else { format!("{stem} ({n}).{ext}") };
        let path = dir.join(&candidate);
        match std::fs::read(&path) {
            Ok(existing) if existing == bytes => return Ok(candidate),
            Ok(_) => continue,
            Err(_) => {
                std::fs::write(&path, &bytes).map_err(|e| format!("couldn't copy the image: {e}"))?;
                return Ok(candidate);
            }
        }
    }
    Err("too many images with that name".into())
}

#[cfg(windows)]
mod dialog {
    use std::ffi::c_void;

    #[repr(C)]
    struct OpenFileName {
        struct_size: u32,
        owner: *mut c_void,
        instance: *mut c_void,
        filter: *const u16,
        custom_filter: *mut u16,
        max_custom_filter: u32,
        filter_index: u32,
        file: *mut u16,
        max_file: u32,
        file_title: *mut u16,
        max_file_title: u32,
        initial_dir: *const u16,
        title: *const u16,
        flags: u32,
        file_offset: u16,
        file_extension: u16,
        def_ext: *const u16,
        cust_data: isize,
        hook: *mut c_void,
        template_name: *const u16,
        reserved_ptr: *mut c_void,
        reserved: u32,
        flags_ex: u32,
    }

    #[link(name = "comdlg32")]
    extern "system" {
        fn GetOpenFileNameW(ofn: *mut OpenFileName) -> i32;
        fn CommDlgExtendedError() -> u32;
    }
    #[link(name = "ole32")]
    extern "system" {
        fn CoInitializeEx(reserved: *mut c_void, flags: u32) -> i32;
        fn CoUninitialize();
    }
    extern "system" {
        fn GetForegroundWindow() -> *mut c_void;
    }

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(Some(0)).collect()
    }

    pub fn owner() -> usize {
        unsafe { GetForegroundWindow() as usize }
    }

    pub fn pick(owner: usize) -> Result<Option<std::path::PathBuf>, String> {
        use std::os::windows::ffi::OsStringExt;
        let filter: Vec<u16> = "Images (PNG, JPG)\0*.png;*.jpg;*.jpeg\0\0".encode_utf16().collect();
        let title = wide("Choose an image for under your deck");
        let mut file = vec![0u16; 4096];
        let mut ofn = OpenFileName {
            struct_size: std::mem::size_of::<OpenFileName>() as u32,
            owner: owner as *mut c_void,
            instance: std::ptr::null_mut(),
            filter: filter.as_ptr(),
            custom_filter: std::ptr::null_mut(),
            max_custom_filter: 0,
            filter_index: 1,
            file: file.as_mut_ptr(),
            max_file: file.len() as u32,
            file_title: std::ptr::null_mut(),
            max_file_title: 0,
            initial_dir: std::ptr::null(),
            title: title.as_ptr(),
            flags: 0x0008_0000 | 0x0000_1000 | 0x0000_0800 | 0x0000_0008,
            file_offset: 0,
            file_extension: 0,
            def_ext: std::ptr::null(),
            cust_data: 0,
            hook: std::ptr::null_mut(),
            template_name: std::ptr::null(),
            reserved_ptr: std::ptr::null_mut(),
            reserved: 0,
            flags_ex: 0,
        };
        unsafe {
            let com = CoInitializeEx(std::ptr::null_mut(), 0x2);
            let ok = GetOpenFileNameW(&mut ofn);
            let error = if ok == 0 { CommDlgExtendedError() } else { 0 };
            if com >= 0 {
                CoUninitialize();
            }
            if ok == 0 {
                return if error == 0 { Ok(None) } else { Err(format!("the file picker failed (error {error})")) };
            }
        }
        let len = file.iter().position(|&c| c == 0).unwrap_or(file.len());
        Ok(Some(std::path::PathBuf::from(std::ffi::OsString::from_wide(&file[..len]))))
    }
}

pub fn start(dir: PathBuf) -> bool {
    let mut s = STATE.lock().unwrap_or_else(|e| e.into_inner());
    if *s == Picked::Open {
        return false;
    }
    #[cfg(windows)]
    {
        *s = Picked::Open;
        let owner = dialog::owner();
        std::thread::spawn(move || {
            let result = std::panic::catch_unwind(move || match dialog::pick(owner) {
                Ok(None) => Picked::Cancelled,
                Ok(Some(path)) => match copy_into(&path, &dir) {
                    Ok(name) => Picked::Done(name),
                    Err(e) => Picked::Failed(e),
                },
                Err(e) => Picked::Failed(e),
            });
            set(result.unwrap_or_else(|_| Picked::Failed("the file picker crashed".into())));
        });
        true
    }
    #[cfg(not(windows))]
    {
        let _ = dir;
        *s = Picked::Failed("the file picker needs Windows".into());
        true
    }
}

pub fn folder(garrysmod: &Path, name: &str) -> Option<PathBuf> {
    match name {
        "videos" => Some(garrysmod.join("videos")),
        "replays" => Some(garrysmod.join("data").join("skategm").join("replays")),
        "boards" => Some(garrysmod.join("data").join("skategm").join("boards")),
        _ => None,
    }
}

#[cfg(windows)]
pub fn open_folder(path: &Path) -> bool {
    use std::ffi::c_void;
    use std::os::windows::ffi::OsStrExt;
    #[link(name = "shell32")]
    extern "system" {
        fn ShellExecuteW(hwnd: *mut c_void, op: *const u16, file: *const u16, params: *const u16, dir: *const u16, show: i32) -> isize;
    }
    let _ = std::fs::create_dir_all(path);
    let file: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    let op: Vec<u16> = "open".encode_utf16().chain(Some(0)).collect();
    unsafe { ShellExecuteW(std::ptr::null_mut(), op.as_ptr(), file.as_ptr(), std::ptr::null(), std::ptr::null(), 1) > 32 }
}

#[cfg(not(windows))]
pub fn open_folder(_path: &Path) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_known_folders_open() {
        let g = Path::new("C:/gmod/garrysmod");
        assert_eq!(folder(g, "videos"), Some(g.join("videos")));
        assert!(folder(g, "../..").is_none() && folder(g, "cfg").is_none());
    }

    #[test]
    fn names_are_cleaned_and_typed_by_content() {
        assert_eq!(clean_name("My Deck!.PNG", "png"), "My Deck_.png");
        assert_eq!(clean_name("../../evil.jpeg", "jpg"), "evil.jpg");
        assert_eq!(clean_name("", "png"), "image.png");
        assert_eq!(image_kind(b"\x89PNG\r\n\x1a\nrest"), Some("png"));
        assert_eq!(image_kind(&[0xFF, 0xD8, 0xFF, 0xE0]), Some("jpg"));
        assert_eq!(image_kind(b"GIF89a"), None);
    }

    #[test]
    fn copies_without_overwriting_another_image() {
        let dir = std::env::temp_dir().join(format!("skategm_picker_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let src = std::env::temp_dir().join(format!("skategm_pick_{}.png", std::process::id()));
        std::fs::write(&src, b"\x89PNG\r\n\x1a\none").unwrap();
        let first = copy_into(&src, &dir).unwrap();
        assert_eq!(copy_into(&src, &dir).unwrap(), first, "the same picture again: the same file");
        std::fs::write(&src, b"\x89PNG\r\n\x1a\ntwo").unwrap();
        let second = copy_into(&src, &dir).unwrap();
        assert_ne!(second, first, "a different picture with the same name gets its own file");
        assert!(second.ends_with("(2).png"));
        std::fs::write(&src, b"not an image").unwrap();
        assert!(copy_into(&src, &dir).is_err());
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_file(&src);
    }
}
