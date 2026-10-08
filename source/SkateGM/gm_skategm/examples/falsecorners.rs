//! Fake corners: visible faces whose edge the engine would pair with a buried
//! face (so it sees a sharp convex corner that isn't there in the game).
use glam::Vec3;
use gmcl_skategm_win64::{cleanup, coords, world::{self, leaves_in_order}};
use std::collections::HashMap;
fn main() {
    let path = std::env::args().nth(1).unwrap();
    let bytes = std::fs::read(&path).unwrap();
    let bsp = vbsp::Bsp::read(&bytes).unwrap();
    let leaves = leaves_in_order(&bytes).unwrap();
    let test = cleanup::WorldSolid::new(&bsp, &leaves, 0x1 | 0x2 | 0x8 | 0x10000);
    // all world brush triangles, as before the cleanup
    let mut raw = Vec::new();
    let w = world::brush_triangles_for_tests(&bytes).unwrap();
    raw.extend(w);
    let buried: Vec<bool> = raw.iter().map(|t| {
        let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize();
        let c = (t[0] + t[1] + t[2]) / 3.0;
        [c, c + (t[0] - c) * 0.8, c + (t[1] - c) * 0.8, c + (t[2] - c) * 0.8].iter().all(|&p| test.solid(p + n * 0.5))
    }).collect();
    let weld = |v: Vec3| coords::to_skate(v.to_array()).map(|x| (f64::from(x) * 1000.0).round() as i64);
    let mut owner: HashMap<([i64; 3], [i64; 3]), Vec<usize>> = HashMap::new();
    for (i, t) in raw.iter().enumerate() { for e in 0..3 { owner.entry((weld(t[e]), weld(t[(e + 1) % 3]))).or_default().push(i); } }
    let mut fake = 0;
    for (i, t) in raw.iter().enumerate() {
        if buried[i] { continue; }
        let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize();
        for e in 0..3 {
            let Some(others) = owner.get(&(weld(t[(e + 1) % 3]), weld(t[e]))) else { continue };
            // paired with a buried face at a sharp convex angle
            if others.iter().any(|&j| buried[j] && { let m = (raw[j][1] - raw[j][0]).cross(raw[j][2] - raw[j][0]).normalize(); n.dot(m) < 0.5 }) { fake += 1; }
        }
    }
    println!("{path}: {} visible brush faces had {fake} edges the engine saw as sharp corners against hidden faces (all removed now)",
        buried.iter().filter(|b| !**b).count());
}
