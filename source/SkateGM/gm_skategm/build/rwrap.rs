use std::process::{exit, Command};

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let rustc = args.remove(0);
    let name = args
        .windows(2)
        .find(|w| w[0] == "--crate-name")
        .map(|w| w[1].clone());
    let gates = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.join("gates")))
        .and_then(|p| std::fs::read_to_string(p).ok())
        .unwrap_or_default();
    if let Some(name) = name {
        for line in gates.lines() {
            let mut it = line.split_whitespace();
            if it.next() == Some(name.as_str()) {
                if let Some(feats) = it.next() {
                    args.push(format!("-Zcrate-attr=feature({feats})"));
                    args.push("-Astable_features".into());
                }
            }
        }
    }
    let status = Command::new(rustc).args(&args).status().expect("rustc");
    exit(status.code().unwrap_or(1));
}
