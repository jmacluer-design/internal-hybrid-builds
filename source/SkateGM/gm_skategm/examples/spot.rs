//! The collision triangles near one spot, the rails passing it, and what the
//! ledge-ramp step finds there.
use glam::Vec3;
use gmcl_skategm_win64::{cleanup, coords, phy, scene::Scene, world};
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let bytes = std::fs::read(&a[1]).unwrap();
    let pak = std::path::PathBuf::from(&a[2]);
    let at = Vec3::new(a[3].parse().unwrap(), a[4].parse().unwrap(), a[5].parse().unwrap());
    let mut scene = Scene::new(world::from_bsp_with(&bytes, 1).unwrap());
    scene.background_layer = false;
    for name in scene.wanted() {
        let mdl = name.trim_end_matches("#bbox").to_string();
        let hulls = std::fs::read(pak.join(mdl.to_lowercase().replace(".mdl", ".phy"))).ok().and_then(|p| phy::hulls(&p).ok())
            .map(|h| h.into_iter().map(|piece| piece.into_iter().flatten().collect()).collect()).unwrap_or_default();
        scene.define(name, hulls);
    }
    let (tris, rails, _, tags) = scene.build_tagged(at);
    // (rails within 24 units of the spot, with how close each comes)
    for rail in &rails {
        let pts: Vec<Vec3> = rail.iter().map(|v| Vec3::from_array(coords::from_skate(*v))).collect();
        let near = pts.windows(2).map(|w| {
            let (a, b) = (w[0], w[1]);
            let ab = b - a;
            let t = ((at - a).dot(ab) / ab.length_squared().max(1e-6)).clamp(0.0, 1.0);
            ((a + ab * t) - at).length()
        }).fold(f32::MAX, f32::min);
        if near <= 24.0 {
            let fmt = |p: Vec3| format!("({:.1} {:.1} {:.1})", p.x, p.y, p.z);
            println!("rail {:.1} away: {} -> {} ({} points)", near, fmt(pts[0]), fmt(pts[pts.len() - 1]), pts.len());
        }
    }
    let tris: Vec<[Vec3; 3]> = tris.iter().map(|t| t.map(|v| Vec3::from_array(coords::from_skate(v)))).collect();
    // the ledge-ramp step on everything within 150 units, as the pipeline would
    let local: Vec<[Vec3; 3]> = tris.iter().zip(&tags).filter(|(t, g)| **g != 5 && **g != 6 && ((t[0] + t[1] + t[2]) / 3.0 - at).truncate().length() < 150.0).map(|(t, _)| *t).collect();
    let ramps = cleanup::step_ramps(&local, 0.05, 8.0);
    let here = ramps.iter().filter(|r| r.iter().any(|p| (p.truncate() - at.truncate()).length() < 40.0)).count();
    println!("ledge ramps on {} local triangles: {} (within 40 units of the spot: {here})", local.len(), ramps.len());
    for (t, g) in tris.iter().zip(&tags) {
        let c = (t[0] + t[1] + t[2]) / 3.0;
        let (lo, hi) = (t[0].min(t[1]).min(t[2]), t[0].max(t[1]).max(t[2]));
        if at.x < lo.x - 3.0 || at.x > hi.x + 3.0 || at.y < lo.y - 3.0 || at.y > hi.y + 3.0 || (c.z - at.z).abs() > 80.0 { continue; }
        let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize();
        println!("tag {g} up {:.3} z {:.2} {:.2} {:.2} | {:?}", n.z, t[0].z, t[1].z, t[2].z, t.map(|p| (p * 100.0).round() / 100.0));
    }
}
