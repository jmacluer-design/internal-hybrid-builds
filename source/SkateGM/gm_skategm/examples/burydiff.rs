//! Faces the dense buried test keeps that the 4-sample one dropped, near a point,
//! with the BSP's solidity just in front of and behind each: "burydiff map.bsp x y r"
use glam::Vec3;
use gmcl_skategm_win64::{cleanup, world};
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let n = |i: usize| a[i].parse::<f32>().unwrap();
    let bytes = std::fs::read(&a[1]).unwrap();
    let (x, y, r) = (n(2), n(3), n(4));
    let base = std::env::var("SK8_OFF").unwrap_or_default();
    let get = |off: String| {
        gmcl_skategm_win64::cleanup::set_env("SK8_OFF", Some(&off));
        world::from_bsp_with(&bytes, 1).unwrap().triangles
    };
    let key = |t: &[Vec3; 3]| t.map(|v| v.to_array().map(|c| (c * 8.0).round() as i32));
    let old: std::collections::HashSet<_> = get(format!("{base},densebury")).iter().map(key).collect();
    let new = get(base.clone());
    let bsp = vbsp::Bsp::read(&bytes).unwrap();
    let leaves = world::leaves_in_order(&bytes).unwrap();
    let solid = cleanup::WorldSolid::new(&bsp, &leaves, 0x1 | 0x2 | 0x8 | 0x10000);
    for t in new.iter().filter(|t| !old.contains(&key(t))) {
        let c = (t[0] + t[1] + t[2]) / 3.0;
        if (c.x - x).abs() > r || (c.y - y).abs() > r { continue; }
        let nrm = (t[1] - t[0]).cross(t[2] - t[0]).normalize();
        let mut front = String::new();
        for k in 0..=4 {
            for j in 0..=(4 - k) {
                let p = t[0] + (t[1] - t[0]) * (k as f32 / 4.0) + (t[2] - t[0]) * (j as f32 / 4.0);
                let p = c + (p - c) * 0.95;
                front.push(if solid.solid(p + nrm * 0.5) { '#' } else { '.' });
            }
        }
        let behind = solid.solid(c - nrm * 0.5);
        println!("n {:+.2},{:+.2},{:+.2} | {:?} | in front (15 points): {front} | behind solid: {behind}", nrm.x, nrm.y, nrm.z, t.map(|v| v.to_array().map(|q| q.round())));
    }
}
