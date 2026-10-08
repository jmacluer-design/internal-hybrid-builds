//! Solidity and area of the map along a vertical line: "probe map.bsp x y z_top z_bottom"
use glam::Vec3;
use gmcl_skategm_win64::{cleanup, world};
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let bytes = std::fs::read(&a[1]).unwrap();
    let n = |i: usize| a[i].parse::<f32>().unwrap();
    let bsp = vbsp::Bsp::read(&bytes).unwrap();
    let leaves = world::leaves_in_order(&bytes).unwrap();
    let all = cleanup::WorldSolid::new(&bsp, &leaves, 0xffff_ffff);
    let player = cleanup::WorldSolid::new(&bsp, &leaves, 0x1 | 0x2 | 0x8 | 0x10000);
    let (x, y) = (n(2), n(3));
    let mut z = n(4);
    while z >= n(5) {
        let p = Vec3::new(x, y, z);
        println!("z {z:8.1}: player-solid {} any-contents {} area {:?}", player.solid(p), all.solid(p), player.area_at(p));
        z -= 8.0;
    }
}
