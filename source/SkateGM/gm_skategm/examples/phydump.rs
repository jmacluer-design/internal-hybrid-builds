//! A .phy file's convex pieces: vertex bounds of each (model space)
use gmcl_skategm_win64::phy;
fn main() {
    let bytes = std::fs::read(std::env::args().nth(1).unwrap()).unwrap();
    let hulls = phy::hulls(&bytes).unwrap();
    println!("{} pieces", hulls.len());
    for (i, h) in hulls.iter().enumerate() {
        let pts: Vec<[f32; 3]> = h.iter().flatten().map(|v| [v[0], v[1], v[2]]).collect();
        let lo = pts.iter().fold([f32::MAX; 3], |a, p| [a[0].min(p[0]), a[1].min(p[1]), a[2].min(p[2])]);
        let hi = pts.iter().fold([f32::MIN; 3], |a, p| [a[0].max(p[0]), a[1].max(p[1]), a[2].max(p[2])]);
        println!("piece {i}: {} triangles, min {:?} max {:?}", h.len(), lo.map(|x| x.round()), hi.map(|x| x.round()));
    }
}
