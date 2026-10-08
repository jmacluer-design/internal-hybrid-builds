use gmcl_skategm_win64::{scene::Scene, world};
use std::time::Instant;
fn main() {
    let bytes = std::fs::read(std::env::args().nth(1).unwrap()).unwrap();
    let t = Instant::now();
    let w = world::from_bsp(&bytes).unwrap();
    println!("map conversion: {} ms", t.elapsed().as_millis());
    let i = w.summary.find('(').unwrap_or(0);
    let timings: String = w.summary.split("T-junctions").nth(1).and_then(|s| s.split('(').last()).unwrap_or("").to_string();
    println!("  pipeline steps (ms): {}", w.summary.rsplit_once("lips) (").map(|(_, r)| r).unwrap_or(&timings).split(')').next().unwrap_or(""));
    let _ = i;
    let names: Vec<String> = w.statics.iter().map(|p| p.model.clone()).collect::<std::collections::HashSet<_>>().into_iter().collect();
    let mut scene = Scene::new(w);
    // every static prop gets a 40-unit box, as if the game had sent the shapes
    let b = |x: f32, y: f32, z: f32| glam::Vec3::new(x, y, z);
    let cube: Vec<glam::Vec3> = {
        let v = [b(-20.,-20.,0.), b(20.,-20.,0.), b(20.,20.,0.), b(-20.,20.,0.), b(-20.,-20.,40.), b(20.,-20.,40.), b(20.,20.,40.), b(-20.,20.,40.)];
        let f = [[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,1,5],[0,5,4],[1,2,6],[1,6,5],[2,3,7],[2,7,6],[3,0,4],[3,4,7]];
        f.iter().flat_map(|t| t.iter().map(|&k| v[k])).collect()
    };
    for n in &names { scene.define(n.clone(), vec![cube.clone()]); }
    let t = Instant::now();
    let (tris, _, st) = scene.build_input(glam::Vec3::ZERO);
    println!("with {} static props: first region build {} ms ({} triangles)", st.statics_placed, t.elapsed().as_millis(), tris.len());
    println!("  {}", scene.layer_report);
}
