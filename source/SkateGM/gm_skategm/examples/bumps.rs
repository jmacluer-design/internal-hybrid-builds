//! How rideable a map's collision is: random paths along rideable surfaces,
//! counting lips a board would hit (a rise of 0.75..3 units within half a unit).
use gmcl_skategm_win64::{cleanup::Heights, world};
use glam::Vec3;
fn main() {
    let bytes = std::fs::read(std::env::args().nth(1).unwrap()).unwrap();
    let w = world::from_bsp_with(&bytes, 1).unwrap();
    let tris = &w.triangles;
    let h = Heights::new(tris);
    // rideable starting points near the middle of the map (area-weighted)
    let floors: Vec<(usize, f32)> = tris.iter().enumerate().filter_map(|(i, t)| {
        let n = (t[1] - t[0]).cross(t[2] - t[0]);
        let a = n.length() / 2.0;
        let c = (t[0] + t[1] + t[2]) / 3.0;
        (n.normalize_or_zero().z > 0.9 && c.truncate().length() < 3000.0).then_some((i, a))
    }).collect();
    let total: f32 = floors.iter().map(|f| f.1).sum();
    let mut seed: u64 = 0x9e3779b97f4a7c15;
    let mut rnd = || { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; (seed >> 11) as f32 / (1u64 << 53) as f32 };
    let (mut lips, mut travelled, mut paths) = (0usize, 0.0f32, 0usize);
    for _ in 0..4000 {
        let mut pick = rnd() * total;
        let &(ti, _) = floors.iter().find(|f| { pick -= f.1; pick <= 0.0 }).unwrap_or(&floors[0]);
        let t = tris[ti];
        let (u, v) = (rnd(), rnd());
        let (u, v) = if u + v > 1.0 { (1.0 - u, 1.0 - v) } else { (u, v) };
        let mut p = t[0] + (t[1] - t[0]) * u + (t[2] - t[0]) * v;
        let ang = rnd() * std::f32::consts::TAU;
        let dir = Vec3::new(ang.cos(), ang.sin(), 0.0);
        paths += 1;
        for _ in 0..600 {
            let q = p + dir * 0.5;
            let Some((z, nz)) = h.below(q.x, q.y, p.z + 3.0) else { break };
            let rise = z - p.z;
            if rise < -12.0 || nz < 0.5 { break; } // off an edge, or up a wall
            if rise > 0.75 { lips += 1; }
            travelled += 0.5;
            p = Vec3::new(q.x, q.y, z);
        }
    }
    println!("{paths} paths, {:.0} units ridden, {lips} lips = {:.2} per 1000 units", travelled, lips as f32 * 1000.0 / travelled);
}
