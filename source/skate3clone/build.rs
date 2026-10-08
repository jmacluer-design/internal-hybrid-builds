use std::env;
use std::path::{Path, PathBuf};

fn owned_data_root(manifest_dir: &Path) -> PathBuf {
    env::var_os("SKATE3_OWNED_DATA_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            manifest_dir
                .join("work")
                .join("private-assets")
                .join("owned-game")
        })
}

fn publish_source(root: &Path, variable: &str, relative: &str) {
    let path = root.join(relative);
    if !path.is_file() {
        panic!(
            "required ISO-derived source is missing: {}\n\
             Run `SETUP FROM OWNED ISO.bat` with your legally owned Skate 3 ISO first.",
            path.display()
        );
    }
    println!("cargo:rerun-if-changed={}", path.display());
    println!("cargo:rustc-env={variable}={}", path.display());
}

fn main() {
    let manifest_dir = PathBuf::from(
        env::var_os("CARGO_MANIFEST_DIR").expect("Cargo always supplies CARGO_MANIFEST_DIR"),
    );
    let root = owned_data_root(&manifest_dir);

    for (variable, file) in [
        ("SKATE3_SKATER_PAT", "skater.pat"),
        ("SKATE3_SKATER90_PAT", "skater90.pat"),
        ("SKATE3_SKATERN90_PAT", "skaterN90.pat"),
        ("SKATE3_SKATER_AIR_PAT", "skater_air.pat"),
        ("SKATE3_SKATER_FINGERFLIP_PAT", "skater_fingerflip.pat"),
        ("SKATE3_SKATER_LS_PAT", "skaterls.pat"),
        ("SKATE3_SKATER_STEP_PAT", "skaterstep.pat"),
    ] {
        publish_source(
            &root,
            variable,
            &format!("data/joystick/{file}"),
        );
    }
    publish_source(
        &manifest_dir,
        "SKATE3_GESTURE_TRICK_MAPPING_JSON",
        "research/fixtures/gesture-trick-mapping-records.json",
    );
}
