//! Skate 3's English text, if the player has it: scoring data names tricks by
//! text IDs ("ID_POP_SHUVIT"); the game translates them through
//! metadata/languages/english_global.json (entries of { label, value }), which
//! the SK8-ENGINE HUD tool extracts from the owned game. We look for that file
//! near the data folder; without it the add-on shows readable IDs instead.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

const FILE: &str = "english_global.json";

/// A folder that is a drive or filesystem root (never walked).
fn is_root(p: &Path) -> bool {
    p.parent().is_none() || p.parent().is_some_and(|q| q.as_os_str().is_empty())
}

/// Look in the data folder and the folder containing it (direct locations
/// first, then a small bounded walk). Never walks a drive root.
pub fn find(root: &Path) -> Option<PathBuf> {
    let mut bases = vec![root.to_path_buf()];
    if let Some(p) = root.parent() {
        if !is_root(p) {
            bases.push(p.to_path_buf());
        }
    }
    for base in &bases {
        let direct = base.join("metadata").join("languages").join(FILE);
        if direct.is_file() {
            return Some(direct);
        }
    }
    // a small, bounded walk for anything named english_global.json
    let mut budget = 4_000;
    for base in bases.iter().filter(|b| !is_root(b)) {
        let mut stack = vec![(base.clone(), 0)];
        while let Some((dir, depth)) = stack.pop() {
            let Ok(entries) = std::fs::read_dir(&dir) else { continue };
            for e in entries.flatten() {
                budget -= 1;
                if budget == 0 {
                    return None;
                }
                let p = e.path();
                if p.is_dir() {
                    if depth < 3 {
                        stack.push((p, depth + 1));
                    }
                } else if p.file_name().is_some_and(|n| n.eq_ignore_ascii_case(FILE)) {
                    return Some(p);
                }
            }
        }
    }
    None
}

pub fn load(path: &Path) -> Result<HashMap<String, String>, String> {
    let text = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    let json: serde_json::Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let entries = json.get("entries").and_then(|e| e.as_array()).ok_or("no entries in the language file")?;
    let mut out = HashMap::new();
    for row in entries {
        if let (Some(label), Some(value)) = (row.get("label").and_then(|v| v.as_str()), row.get("value").and_then(|v| v.as_str())) {
            out.insert(label.trim().to_string(), value.to_string());
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    #[test]
    fn never_walks_a_drive_root() {
        assert!(super::is_root(std::path::Path::new("/")));
        assert!(!super::is_root(std::path::Path::new("/tmp")));
        // (in a folder of its own: /tmp itself can be huge and busy, which made
        // a timing check flaky without the search ever leaving its bounds)
        let dir = std::env::temp_dir().join(format!("sk8root{}", std::process::id())).join("data").join("assets");
        std::fs::create_dir_all(&dir).unwrap();
        let t = std::time::Instant::now();
        let _ = super::find(&dir);
        assert!(t.elapsed().as_secs_f32() < 5.0, "a search near a data folder must not walk the whole drive");
        let _ = std::fs::remove_dir_all(dir.parent().unwrap().parent().unwrap());
    }

    #[test]
    fn finds_and_reads_the_table() {
        let dir = std::env::temp_dir().join(format!("sk8lang{}", std::process::id()));
        let lang = dir.join("hud").join("metadata").join("languages");
        std::fs::create_dir_all(&lang).unwrap();
        std::fs::create_dir_all(dir.join("assets")).unwrap();
        std::fs::write(lang.join("english_global.json"), r#"{"entries":[{"label":"ID_POP_SHUVIT ","value":"Pop Shove-it"}]}"#).unwrap();
        let found = super::find(&dir.join("assets")).expect("found from the data folder");
        let table = super::load(&found).unwrap();
        assert_eq!(table.get("ID_POP_SHUVIT").map(String::as_str), Some("Pop Shove-it"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
