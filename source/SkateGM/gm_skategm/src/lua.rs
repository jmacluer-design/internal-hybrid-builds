//! Minimal Lua C API bindings, resolved at load time from the game's own
//! lua_shared library (the LuaJIT build Garry's Mod ships). Stable Rust, no
//! nightly features. Nothing here ever raises a Lua error (no longjmp through
//! Rust frames): functions return values, and bad arguments fall back to
//! defaults or produce an (nil, message) return from the caller.

use std::ffi::{c_char, c_int, c_void, CString};
use std::sync::OnceLock;

pub type State = *mut c_void;
pub type CFunction = unsafe extern "C" fn(State) -> c_int;

pub const GLOBALSINDEX: c_int = -10002;
const TNUMBER: c_int = 3;
const TSTRING: c_int = 4;
const TTABLE: c_int = 5;

#[allow(non_snake_case)]
pub struct Api {
    pub gettop: unsafe extern "C" fn(State) -> c_int,
    pub type_: unsafe extern "C" fn(State, c_int) -> c_int,
    pub pushnumber: unsafe extern "C" fn(State, f64),
    pub pushboolean: unsafe extern "C" fn(State, c_int),
    pub pushlstring: unsafe extern "C" fn(State, *const c_char, usize),
    pub pushnil: unsafe extern "C" fn(State),
    pub pushcclosure: unsafe extern "C" fn(State, CFunction, c_int),
    pub createtable: unsafe extern "C" fn(State, c_int, c_int),
    pub setfield: unsafe extern "C" fn(State, c_int, *const c_char),
    pub rawseti: unsafe extern "C" fn(State, c_int, c_int),
    pub tonumber: unsafe extern "C" fn(State, c_int) -> f64,
    pub toboolean: unsafe extern "C" fn(State, c_int) -> c_int,
    pub tolstring: unsafe extern "C" fn(State, c_int, *mut usize) -> *const c_char,
    pub rawgeti: unsafe extern "C" fn(State, c_int, c_int),
    pub objlen: unsafe extern "C" fn(State, c_int) -> usize,
    pub settop: unsafe extern "C" fn(State, c_int),
}

static API: OnceLock<Result<Api, String>> = OnceLock::new();

#[cfg(windows)]
unsafe fn symbol(name: &str) -> *mut c_void {
    extern "system" {
        fn GetModuleHandleA(name: *const c_char) -> *mut c_void;
        fn GetProcAddress(module: *mut c_void, name: *const c_char) -> *mut c_void;
    }
    // Garry's Mod's LuaJIT is lua_shared.dll; stock LuaJIT (used for testing
    // the module outside the game) is lua51.dll.
    let mut lib = GetModuleHandleA(c"lua_shared.dll".as_ptr());
    if lib.is_null() {
        lib = GetModuleHandleA(c"lua51.dll".as_ptr());
    }
    if lib.is_null() {
        return std::ptr::null_mut();
    }
    let n = CString::new(name).unwrap();
    GetProcAddress(lib, n.as_ptr())
}

#[cfg(not(windows))]
unsafe fn symbol(name: &str) -> *mut c_void {
    // Linux client: lua_shared_client.so is already loaded into the process
    extern "C" {
        fn dlsym(handle: *mut c_void, name: *const c_char) -> *mut c_void;
    }
    let n = CString::new(name).unwrap();
    dlsym(std::ptr::null_mut(), n.as_ptr()) // RTLD_DEFAULT
}

macro_rules! load {
    ($name:literal) => {{
        let p = symbol($name);
        if p.is_null() {
            return Err(concat!("lua_shared is missing ", $name).to_string());
        }
        std::mem::transmute(p)
    }};
}

/// Resolve the Lua API once. Called from gmod13_open.
pub fn init() -> Result<(), String> {
    let r = API.get_or_init(|| unsafe {
        Ok(Api {
            gettop: load!("lua_gettop"),
            type_: load!("lua_type"),
            pushnumber: load!("lua_pushnumber"),
            pushboolean: load!("lua_pushboolean"),
            pushlstring: load!("lua_pushlstring"),
            pushnil: load!("lua_pushnil"),
            pushcclosure: load!("lua_pushcclosure"),
            createtable: load!("lua_createtable"),
            setfield: load!("lua_setfield"),
            rawseti: load!("lua_rawseti"),
            tonumber: load!("lua_tonumber"),
            toboolean: load!("lua_toboolean"),
            tolstring: load!("lua_tolstring"),
            rawgeti: load!("lua_rawgeti"),
            objlen: load!("lua_objlen"),
            settop: load!("lua_settop"),
        })
    });
    r.as_ref().map(|_| ()).map_err(|e| e.clone())
}

fn api() -> &'static Api {
    // init() runs in gmod13_open before any function can be called
    API.get().and_then(|r| r.as_ref().ok()).expect("Lua API not initialised")
}

/// A thin, safe-ish wrapper over one Lua call's state.
#[derive(Clone, Copy)]
pub struct Lua(pub State);

impl Lua {
    pub fn top(self) -> i32 {
        unsafe { (api().gettop)(self.0) }
    }
    pub fn number(self, i: i32, default: f64) -> f64 {
        unsafe {
            if i <= self.top() && (api().type_)(self.0, i) == TNUMBER {
                (api().tonumber)(self.0, i)
            } else {
                default
            }
        }
    }
    pub fn is_number(self, i: i32) -> bool {
        unsafe { i <= self.top() && (api().type_)(self.0, i) == TNUMBER }
    }
    pub fn boolean(self, i: i32) -> bool {
        unsafe { i <= self.top() && (api().toboolean)(self.0, i) != 0 }
    }
    pub fn string(self, i: i32) -> Option<String> {
        unsafe {
            if i > self.top() || (api().type_)(self.0, i) != TSTRING {
                return None;
            }
            let mut len = 0usize;
            let p = (api().tolstring)(self.0, i, &mut len);
            if p.is_null() {
                return None;
            }
            let bytes = std::slice::from_raw_parts(p as *const u8, len);
            Some(String::from_utf8_lossy(bytes).into_owned())
        }
    }
    /// A string argument as raw bytes (binary safe), e.g. a whole .bsp file.
    pub fn bytes(self, i: i32) -> Option<Vec<u8>> {
        unsafe {
            if i > self.top() || (api().type_)(self.0, i) != TSTRING {
                return None;
            }
            let mut len = 0usize;
            let p = (api().tolstring)(self.0, i, &mut len);
            if p.is_null() {
                return None;
            }
            Some(std::slice::from_raw_parts(p as *const u8, len).to_vec())
        }
    }
    pub fn is_table(self, i: i32) -> bool {
        unsafe { i <= self.top() && (api().type_)(self.0, i) == TTABLE }
    }
    /// #t for the table at index i (absolute index)
    pub fn len(self, i: i32) -> usize {
        unsafe { (api().objlen)(self.0, i) }
    }
    /// pushes t[n] for the table at index i (absolute index)
    pub fn geti(self, i: i32, n: i32) {
        unsafe { (api().rawgeti)(self.0, i, n) }
    }
    pub fn pop(self, n: i32) {
        unsafe { (api().settop)(self.0, -n - 1) }
    }
    /// Reads t[1..#t] of the table at absolute index i as numbers.
    pub fn numbers(self, i: i32) -> Vec<f64> {
        let n = self.len(i);
        let mut out = Vec::with_capacity(n);
        for k in 1..=n as i32 {
            self.geti(i, k);
            let top = self.top();
            out.push(self.number(top, 0.0));
            self.pop(1);
        }
        out
    }
    pub fn push_number(self, v: f64) {
        unsafe { (api().pushnumber)(self.0, v) }
    }
    pub fn push_bool(self, v: bool) {
        unsafe { (api().pushboolean)(self.0, v as c_int) }
    }
    pub fn push_str(self, s: &str) {
        unsafe { (api().pushlstring)(self.0, s.as_ptr() as *const c_char, s.len()) }
    }
    pub fn push_nil(self) {
        unsafe { (api().pushnil)(self.0) }
    }
    pub fn push_fn(self, f: CFunction) {
        unsafe { (api().pushcclosure)(self.0, f, 0) }
    }
    pub fn new_table(self, arr: i32, hash: i32) {
        unsafe { (api().createtable)(self.0, arr, hash) }
    }
    /// t[key] = value on top, where the table is just below it
    pub fn set(self, key: &str) {
        let k = CString::new(key).unwrap();
        unsafe { (api().setfield)(self.0, -2, k.as_ptr()) }
    }
    /// t[i] = value on top, where the table is just below it
    pub fn seti(self, i: i32) {
        unsafe { (api().rawseti)(self.0, -2, i) }
    }
    pub fn set_global(self, name: &str) {
        let k = CString::new(name).unwrap();
        unsafe { (api().setfield)(self.0, GLOBALSINDEX, k.as_ptr()) }
    }

    // conveniences for building result tables
    pub fn field_num(self, key: &str, v: f64) {
        self.push_number(v);
        self.set(key);
    }
    pub fn field_str(self, key: &str, v: &str) {
        self.push_str(v);
        self.set(key);
    }
    pub fn field_bool(self, key: &str, v: bool) {
        self.push_bool(v);
        self.set(key);
    }
    pub fn push_vec(self, v: [f32; 3]) {
        self.new_table(3, 0);
        for (i, c) in v.iter().enumerate() {
            self.push_number(*c as f64);
            self.seti(i as i32 + 1);
        }
    }
    pub fn field_vec(self, key: &str, v: [f32; 3]) {
        self.push_vec(v);
        self.set(key);
    }
}
