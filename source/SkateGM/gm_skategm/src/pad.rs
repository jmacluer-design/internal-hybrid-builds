const XINPUT_BUTTONS: [u16; 15] = [
    0x1000, 0x2000, 0x4000, 0x8000, 0x0020, 0x0000, 0x0010, 0x0040, 0x0080, 0x0100, 0x0200, 0x0001, 0x0002, 0x0004,
    0x0008,
];

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct State {
    pub buttons: u16,
    pub triggers: [u8; 2],
    pub left: [i16; 2],
    pub right: [i16; 2],
}

pub fn from_sdl(buttons: &[bool; 15], axes: &[i16; 6]) -> State {
    let mut bits = 0;
    for (i, &down) in buttons.iter().enumerate() {
        if down {
            bits |= XINPUT_BUTTONS[i];
        }
    }
    let up = |v: i16| (-(v as i32)).clamp(-32768, 32767) as i16;
    let trigger = |v: i16| ((v.max(0) as i32 * 255 + 16383) / 32767) as u8;
    State {
        buttons: bits,
        triggers: [trigger(axes[4]), trigger(axes[5])],
        left: [axes[0], up(axes[1])],
        right: [axes[2], up(axes[3])],
    }
}

pub fn kind(sdl_type: i32) -> &'static str {
    match sdl_type {
        3 | 4 | 7 => "playstation",
        5 | 11 | 12 | 13 => "nintendo",
        _ => "xbox",
    }
}

#[derive(Default)]
pub struct Chooser {
    numbers: [Option<u32>; 4],
    touched: [u64; 4],
    clock: u64,
}

impl Chooser {
    pub fn choose(&mut self, numbers: [Option<u32>; 4]) -> Option<usize> {
        self.clock += 1;
        for i in 0..4 {
            match (self.numbers[i], numbers[i]) {
                (_, None) => self.touched[i] = 0,
                (Some(a), Some(b)) if a == b => {}
                (None, Some(_)) => self.touched[i] = self.touched[i].max(1),
                (Some(_), Some(_)) => self.touched[i] = self.clock + 1,
            }
        }
        self.numbers = numbers;
        (0..4).filter(|&i| numbers[i].is_some()).max_by_key(|&i| (self.touched[i], std::cmp::Reverse(i)))
    }
}

#[cfg(windows)]
pub fn module_dir() -> Option<std::path::PathBuf> {
    use std::ffi::c_void;
    use std::os::windows::ffi::OsStringExt;
    extern "system" {
        fn GetModuleHandleExW(flags: u32, name: *const u16, module: *mut *mut c_void) -> i32;
        fn GetModuleFileNameW(module: *mut c_void, name: *mut u16, size: u32) -> u32;
    }
    const FROM_ADDRESS: u32 = 0x4;
    const UNCHANGED_REFCOUNT: u32 = 0x2;
    let mut handle = std::ptr::null_mut();
    let mut buf = vec![0u16; 1024];
    unsafe {
        if GetModuleHandleExW(FROM_ADDRESS | UNCHANGED_REFCOUNT, module_dir as *const () as *const u16, &mut handle) == 0 {
            return None;
        }
        let n = GetModuleFileNameW(handle, buf.as_mut_ptr(), buf.len() as u32) as usize;
        if n == 0 {
            return None;
        }
        buf.truncate(n);
    }
    std::path::PathBuf::from(std::ffi::OsString::from_wide(&buf)).parent().map(|p| p.to_path_buf())
}

#[cfg(not(windows))]
pub fn module_dir() -> Option<std::path::PathBuf> {
    None
}

#[cfg(windows)]
mod sdl {
    use super::State;
    use std::ffi::{c_char, c_int, c_void, CStr};

    type Ctrl = *mut c_void;
    struct Api {
        update: unsafe extern "C" fn(),
        num_joysticks: unsafe extern "C" fn() -> c_int,
        is_controller: unsafe extern "C" fn(c_int) -> c_int,
        open: unsafe extern "C" fn(c_int) -> Ctrl,
        close: unsafe extern "C" fn(Ctrl),
        attached: unsafe extern "C" fn(Ctrl) -> c_int,
        button: unsafe extern "C" fn(Ctrl, c_int) -> u8,
        axis: unsafe extern "C" fn(Ctrl, c_int) -> i16,
        name: unsafe extern "C" fn(Ctrl) -> *const c_char,
        kind: Option<unsafe extern "C" fn(Ctrl) -> c_int>,
        joystick_name: unsafe extern "C" fn(c_int) -> *const c_char,
    }

    extern "system" {
        fn LoadLibraryW(name: *const u16) -> *mut c_void;
        fn GetProcAddress(module: *mut c_void, name: *const c_char) -> *mut c_void;
    }

    fn wide(p: &std::path::Path) -> Vec<u16> {
        use std::os::windows::ffi::OsStrExt;
        p.as_os_str().encode_wide().chain(Some(0)).collect()
    }

    fn text(p: *const c_char) -> String {
        if p.is_null() {
            String::new()
        } else {
            unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
        }
    }

    pub struct Sdl {
        api: Api,
        ctrl: Ctrl,
        number: u32,
        last: State,
        pub name: String,
        pub kind: &'static str,
        pub others: Vec<String>,
    }

    unsafe impl Send for Sdl {}

    impl Sdl {
        pub fn load() -> Result<Sdl, String> {
            let dir = super::module_dir().ok_or("can't find the module's folder")?;
            let dll = dir.join("skategm_sdl2.dll");
            let lib = unsafe { LoadLibraryW(wide(&dll).as_ptr()) };
            if lib.is_null() {
                return Err(format!("{} not found", dll.display()));
            }
            macro_rules! f {
                ($name:literal) => {{
                    let p = unsafe { GetProcAddress(lib, concat!($name, "\0").as_ptr() as *const c_char) };
                    if p.is_null() {
                        return Err(format!("{} lacks {}", dll.display(), $name));
                    }
                    unsafe { std::mem::transmute::<*mut c_void, _>(p) }
                }};
            }
            let set_hint: unsafe extern "C" fn(*const c_char, *const c_char) -> c_int = f!("SDL_SetHint");
            let init: unsafe extern "C" fn(u32) -> c_int = f!("SDL_Init");
            let rw_from_file: unsafe extern "C" fn(*const c_char, *const c_char) -> *mut c_void = f!("SDL_RWFromFile");
            let add_mappings: unsafe extern "C" fn(*mut c_void, c_int) -> c_int = f!("SDL_GameControllerAddMappingsFromRW");
            let api = Api {
                update: f!("SDL_GameControllerUpdate"),
                num_joysticks: f!("SDL_NumJoysticks"),
                is_controller: f!("SDL_IsGameController"),
                open: f!("SDL_GameControllerOpen"),
                close: f!("SDL_GameControllerClose"),
                attached: f!("SDL_GameControllerGetAttached"),
                button: f!("SDL_GameControllerGetButton"),
                axis: f!("SDL_GameControllerGetAxis"),
                name: f!("SDL_GameControllerName"),
                joystick_name: f!("SDL_JoystickNameForIndex"),
                kind: {
                    let p = unsafe { GetProcAddress(lib, c"SDL_GameControllerGetType".as_ptr()) };
                    (!p.is_null()).then(|| unsafe { std::mem::transmute::<*mut c_void, unsafe extern "C" fn(Ctrl) -> c_int>(p) })
                },
            };
            for (k, v) in [
                ("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS", "1"),
                ("SDL_XINPUT_ENABLED", "0"),
                ("SDL_JOYSTICK_HIDAPI_XBOX", "0"),
                ("SDL_JOYSTICK_RAWINPUT", "0"),
                ("SDL_JOYSTICK_WGI", "0"),
            ] {
                let (k, v) = (std::ffi::CString::new(k).unwrap(), std::ffi::CString::new(v).unwrap());
                unsafe { set_hint(k.as_ptr(), v.as_ptr()) };
            }
            const JOYSTICK: u32 = 0x200;
            const GAMECONTROLLER: u32 = 0x2000;
            if unsafe { init(JOYSTICK | GAMECONTROLLER) } != 0 {
                return Err("SDL couldn't start its controller support".into());
            }
            let mut files = vec![dir.join("skategm_gamecontrollerdb.txt")];
            if let Some(garrysmod) = dir.parent().and_then(|p| p.parent()) {
                files.push(garrysmod.join("data").join("skategm").join("gamecontrollerdb.txt"));
            }
            for file in files {
                if let Some(path) = file.to_str().and_then(|s| std::ffi::CString::new(s).ok()) {
                    if file.exists() {
                        let rw = unsafe { rw_from_file(path.as_ptr(), c"rb".as_ptr()) };
                        if !rw.is_null() {
                            unsafe { add_mappings(rw, 1) };
                        }
                    }
                }
            }
            Ok(Sdl { api, ctrl: std::ptr::null_mut(), number: 0, last: State::default(), name: String::new(), kind: "xbox", others: Vec::new() })
        }

        pub fn read(&mut self) -> Option<(u32, State)> {
            let a = &self.api;
            unsafe {
                (a.update)();
                if !self.ctrl.is_null() && (a.attached)(self.ctrl) == 0 {
                    (a.close)(self.ctrl);
                    self.ctrl = std::ptr::null_mut();
                    self.name.clear();
                }
                if self.ctrl.is_null() {
                    self.others.clear();
                    for i in 0..(a.num_joysticks)() {
                        if (a.is_controller)(i) != 0 {
                            self.ctrl = (a.open)(i);
                            if !self.ctrl.is_null() {
                                self.name = text((a.name)(self.ctrl));
                                self.kind = super::kind(a.kind.map_or(0, |f| f(self.ctrl)));
                                break;
                            }
                        } else {
                            self.others.push(text((a.joystick_name)(i)));
                        }
                    }
                }
                if self.ctrl.is_null() {
                    return None;
                }
                let buttons: [bool; 15] = std::array::from_fn(|i| (a.button)(self.ctrl, i as c_int) != 0);
                let axes: [i16; 6] = std::array::from_fn(|i| (a.axis)(self.ctrl, i as c_int));
                let state = super::from_sdl(&buttons, &axes);
                if state != self.last {
                    self.last = state;
                    self.number = self.number.wrapping_add(1);
                }
                Some((self.number, state))
            }
        }
    }
}

#[derive(Default)]
pub struct Pads {
    chooser: Chooser,
    #[cfg(windows)]
    sdl: Option<Result<sdl::Sdl, String>>,
    pub name: String,
    pub kind: &'static str,
}

impl Pads {
    pub fn pick(&mut self, numbers: [Option<u32>; 4]) -> (Option<usize>, Option<(u32, State)>) {
        let numbers = if crate::cleanup::on("sdlonly") { [None; 4] } else { numbers };
        let slot = self.chooser.choose(numbers);
        if let Some(i) = slot {
            self.name = format!("Xbox controller (XInput slot {})", i + 1);
            self.kind = "xbox";
            return (slot, None);
        }
        if crate::cleanup::off("sdlpads") {
            self.name = "none (SDL pads off)".into();
            return (None, None);
        }
        #[cfg(windows)]
        {
            let sdl = self.sdl.get_or_insert_with(sdl::Sdl::load);
            match sdl {
                Ok(s) => {
                    let read = s.read();
                    self.kind = if read.is_some() { s.kind } else { "xbox" };
                    self.name = if read.is_some() {
                        s.name.clone()
                    } else if s.others.is_empty() {
                        "none".into()
                    } else {
                        format!("none usable (not recognised as a gamepad: {})", s.others.join(", "))
                    };
                    return (None, read);
                }
                Err(e) => self.name = format!("none (no SDL: {e})"),
            }
        }
        #[cfg(not(windows))]
        {
            self.name = "none".into();
        }
        (None, None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sdl_state_becomes_xinput_state() {
        let mut b = [false; 15];
        b[0] = true;
        b[9] = true;
        b[11] = true;
        let s = from_sdl(&b, &[100, -32768, -5, 32767, 32767, 0]);
        assert_eq!(s.buttons, 0x1000 | 0x0100 | 0x0001);
        assert_eq!(s.left, [100, 32767], "SDL up is negative, XInput up is positive");
        assert_eq!(s.right, [-5, -32767]);
        assert_eq!(s.triggers, [255, 0]);
        assert_eq!(from_sdl(&[false; 15], &[0, 0, 0, 0, 16384, -100]).triggers, [128, 0]);
    }

    #[test]
    fn pad_types() {
        assert_eq!([kind(4), kind(7), kind(3), kind(5), kind(1), kind(0)], ["playstation", "playstation", "playstation", "nintendo", "xbox", "xbox"]);
    }

    #[test]
    fn the_pad_touched_last_drives_the_skater() {
        let mut c = Chooser::default();
        assert_eq!(c.choose([None; 4]), None);
        assert_eq!(c.choose([Some(5), Some(9), None, None]), Some(0), "nothing touched yet: the first");
        assert_eq!(c.choose([Some(5), Some(10), None, None]), Some(1), "slot 2 moved");
        assert_eq!(c.choose([Some(5), Some(10), None, None]), Some(1), "it stays while nothing changes");
        assert_eq!(c.choose([Some(6), Some(10), None, None]), Some(0), "back to slot 1 when it's used");
        assert_eq!(c.choose([None, Some(10), None, None]), Some(1), "unplugged: the other");
        assert_eq!(c.choose([Some(1), Some(10), None, None]), Some(1), "plugged back in, untouched: not taken over");
    }
}
