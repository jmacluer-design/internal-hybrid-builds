//! cargo run --release --no-default-features --example mapcheck -- map.bsp
use gmcl_skategm_win64::{scene::Scene, world};
fn main() {
    let path = std::env::args().nth(1).expect("path to a .bsp");
    let bytes = std::fs::read(&path).expect("read map");
    let t = std::time::Instant::now();
    let smooth: u32 = std::env::args().nth(2).and_then(|s| s.parse().ok()).unwrap_or(1);
    let w = world::from_bsp_with(&bytes, smooth).expect("parse");
    println!("{path}: {} ({} ms)", w.summary, t.elapsed().as_millis());
    let mut scene = Scene::new(w);
    scene.background_layer = false;
    println!("shapes Lua will be asked for: {}", scene.wanted().len());
    for centre in [glam::Vec3::ZERO, glam::Vec3::new(3000.0, 3000.0, 0.0)] {
        let t = std::time::Instant::now();
        let (tris, rails, st) = scene.build_input(centre);
        println!("region at {:?}: {} tris, {} rails, {} degenerate slivers left out, in {} ms", centre.to_array(), tris.len(), rails.len(), st.dropped, t.elapsed().as_millis());
    }
}
