//! Displacements that lie on top of each other: "dispdups map.bsp"
use glam::Vec3;
fn main() {
    let bytes = std::fs::read(std::env::args().nth(1).unwrap()).unwrap();
    let bsp = vbsp::Bsp::read(&bytes).unwrap();
    let grids: Vec<(usize, Vec<Vec3>)> = (0..bsp.displacements.len()).filter_map(|n| {
        let d = bsp.displacement(n)?;
        Some((n, d.displaced_vertices().map(|v| Vec3::new(v.x, v.y, v.z)).collect()))
    }).collect();
    for (i, (a, ga)) in grids.iter().enumerate() {
        for (b, gb) in grids.iter().skip(i + 1) {
            if ga.len() != gb.len() { continue; }
            // same points, in any order of corners: the nearest point of b for each point of a
            let worst = ga.iter().map(|p| gb.iter().map(|q| p.distance(*q)).fold(f32::MAX, f32::min)).fold(0.0f32, f32::max);
            let mean = ga.iter().map(|p| gb.iter().map(|q| p.distance(*q)).fold(f32::MAX, f32::min)).sum::<f32>() / ga.len() as f32;
            if worst < 64.0 { println!("displacements {a} and {b}: {} points each, farthest point {worst:.3} units from the other, mean {mean:.3}", ga.len()); }
        }
    }
}
