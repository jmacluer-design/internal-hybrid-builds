use gmcl_skategm_win64::world;
fn main() {
    let bytes = std::fs::read(std::env::args().nth(1).unwrap()).unwrap();
    let w = world::from_bsp_with(&bytes, 0).unwrap();
    let s = w.solid.unwrap();
    for (name, p) in [("sky_camera", glam::Vec3::new(-2715., -165., -3174.69)), ("info_player_start", glam::Vec3::new(-1278.33, 499.333, 423.)), ("the ramp from the trace", glam::Vec3::new(-2491., -814., 420.))] {
        println!("{name}: area {:?}", s.area_at(p));
    }
    let mut counts = std::collections::BTreeMap::new();
    for a in &s.leaf_areas { *counts.entry(*a).or_insert(0) += 1; }
    println!("leaves per area: {counts:?}");
}
