//! Rails a switch removes or adds: "railsdiff map.bsp switch" compares SK8_OFF with and without it.
use gmcl_skategm_win64::world;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let bytes = std::fs::read(&a[1]).unwrap();
    let base = std::env::var("SK8_OFF").unwrap_or_default();
    let get = |off: &str| {
        gmcl_skategm_win64::cleanup::set_env("SK8_OFF", Some(&off));
        let w = world::from_bsp_with(&bytes, 1).unwrap();
        w.rails.iter().map(|r| r.iter().map(|v| [v.x.round() as i32, v.y.round() as i32, v.z.round() as i32]).collect::<Vec<_>>()).collect::<std::collections::BTreeSet<_>>()
    };
    let with = get(&base);
    let without = get(&format!("{base},{}", a[2]));
    for r in without.difference(&with) { println!("removed (len {} pts): {:?} .. {:?}", r.len(), r[0], r[r.len() - 1]); }
    for r in with.difference(&without) { println!("added: {:?} .. {:?}", r[0], r[r.len() - 1]); }
}
