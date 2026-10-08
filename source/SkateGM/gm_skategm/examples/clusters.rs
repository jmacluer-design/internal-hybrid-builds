//! How much work a wheel query does, the way the engine clusters triangles:
//! consecutive runs of 64, each culled by its bounding box.
use gmcl_skategm_win64::{coords, scene::Scene, world};
fn main() {
    let bytes = std::fs::read(std::env::args().nth(1).unwrap()).unwrap();
    let mut scene = Scene::new(world::from_bsp(&bytes).unwrap());
    let (tris, _, _) = scene.build_input(glam::Vec3::ZERO);
    let measure = |tris: &[[[f32; 3]; 3]], label: &str| {
        let boxes: Vec<([f32; 3], [f32; 3])> = tris.chunks(64).map(|c| {
            let mut lo = [f32::MAX; 3]; let mut hi = [f32::MIN; 3];
            for t in c { for v in t { for k in 0..3 { lo[k] = lo[k].min(v[k]); hi[k] = hi[k].max(v[k]); } } }
            (lo, hi)
        }).collect();
        // wheel-sized queries (a 0.5 m box) at triangle centres spread over the region
        let (mut tested, mut n) = (0usize, 0usize);
        for t in tris.iter().step_by(tris.len() / 500 + 1) {
            let c = [(t[0][0] + t[1][0] + t[2][0]) / 3.0, (t[0][1] + t[1][1] + t[2][1]) / 3.0, (t[0][2] + t[1][2] + t[2][2]) / 3.0];
            let hits = boxes.iter().filter(|(lo, hi)| (0..3).all(|k| c[k] + 0.25 >= lo[k] && c[k] - 0.25 <= hi[k])).count();
            tested += hits * 64;
            n += 1;
        }
        println!("{label}: {} triangles, a wheel query tests about {} of them", tris.len(), tested / n);
    };
    // the order before this fix: same triangles, but as they were made (unsorted)
    let mut s2 = Scene::new(world::from_bsp(&bytes).unwrap());
    let (_, _, _) = s2.build_input(glam::Vec3::ZERO);
    let unsorted: Vec<[[f32; 3]; 3]> = world::from_bsp(&bytes).unwrap().triangles.iter().map(|t| t.map(|v| coords::to_skate(v.to_array()))).collect();
    measure(&unsorted, "as made (before)");
    measure(&tris, "sorted (now)    ");
}
