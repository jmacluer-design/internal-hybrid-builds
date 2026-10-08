//! trench_width's walk at one edge point: "trenchdbg map.bsp x y z outx outy"
use glam::Vec3;
use gmcl_skategm_win64::{cleanup, world};
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let n = |i: usize| a[i].parse::<f32>().unwrap();
    gmcl_skategm_win64::cleanup::set_env("SK8_OFF", Some("ledges,curves,trenches"));
    let w = world::from_bsp_with(&std::fs::read(&a[1]).unwrap(), 1).unwrap();
    let h = cleanup::Heights::new(&w.triangles);
    let p = Vec3::new(n(2), n(3), n(4));
    let out = Vec3::new(n(5), n(6), 0.0).normalize();
    for k in 0..14 {
        let d = 1.0 + 2.0 * k as f32;
        println!("d {d:4.1}: {:?}", h.below(p.x + out.x * d, p.y + out.y * d, p.z + 3.0).map(|(z, nz)| (z - p.z, nz)));
    }
    println!("trench_width: {:?}", cleanup::trench_width(&h, p, out, 24.0));
}
