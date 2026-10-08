//! The map's collision must not depend on how many cores made it.
use gmcl_skategm_win64::world;
fn main() {
    let bytes = std::fs::read(std::env::args().nth(1).unwrap()).unwrap();
    let t = std::time::Instant::now();
    let w = world::from_bsp_with(&bytes, 1).unwrap();
    let mut h: u64 = 1469598103934665603;
    for tri in &w.triangles { for v in tri { for x in v.to_array() { h = (h ^ x.to_bits() as u64).wrapping_mul(1099511628211); } } }
    for g in &w.tags { h = (h ^ *g as u64).wrapping_mul(1099511628211); }
    for r in &w.rails { for v in r { for x in v.to_array() { h = (h ^ x.to_bits() as u64).wrapping_mul(1099511628211); } } }
    // order-independent: the same set of triangles (and of rails)?
    let mut set: Vec<[u32; 9]> = w.triangles.iter().map(|t| { let mut k = [0u32; 9]; for (i, v) in t.iter().enumerate() { for j in 0..3 { k[i * 3 + j] = v.to_array()[j].to_bits(); } } k }).collect();
    set.sort_unstable();
    let mut hs: u64 = 1469598103934665603;
    for k in &set { for x in k { hs = (hs ^ *x as u64).wrapping_mul(1099511628211); } }
    let mut rs: Vec<Vec<u32>> = w.rails.iter().map(|r| r.iter().flat_map(|v| v.to_array().map(f32::to_bits)).collect()).collect();
    rs.sort_unstable();
    let mut hr: u64 = 1469598103934665603;
    for r in &rs { for x in r { hr = (hr ^ *x as u64).wrapping_mul(1099511628211); } }
    println!("triangle set {hs:016x}, rail set {hr:016x}");
    println!("{} triangles, {} rails, fingerprint {h:016x}, {} ms", w.triangles.len(), w.rails.len(), t.elapsed().as_millis());
}
