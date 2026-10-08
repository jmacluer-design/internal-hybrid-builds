//! A top-down map of the collision's ground heights: "heightmap map.bsp x0 y0 x1 y1 step"
//! (each character is the highest walkable surface there, in steps of 16 units
//! against the most common height; '.' = level with it, digits above, letters below)
use gmcl_skategm_win64::{cleanup, world};
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let n = |i: usize| a[i].parse::<f32>().unwrap();
    let w = world::from_bsp_with(&std::fs::read(&a[1]).unwrap(), 1).unwrap();
    let h = cleanup::Heights::new(&w.triangles);
    let (x0, y0, x1, y1, step) = (n(2), n(3), n(4), n(5), n(6));
    let mut rows = Vec::new();
    let mut all = Vec::new();
    let mut y = y1;
    while y >= y0 {
        let mut row = Vec::new();
        let mut x = x0;
        while x <= x1 {
            let z = h.below(x, y, std::env::var("SK8_TOP").ok().and_then(|v| v.parse().ok()).unwrap_or(2000.0)).map(|(z, _)| z);
            if let Some(z) = z { all.push((z / 4.0).round() as i32); }
            row.push(z);
            x += step;
        }
        rows.push((y, row));
        y -= step;
    }
    all.sort();
    let mut best = (0, 0);
    let mut i = 0;
    while i < all.len() { let j = all[i..].iter().take_while(|v| **v == all[i]).count(); if j > best.1 { best = (all[i], j); } i += j; }
    let base = best.0 as f32 * 4.0;
    println!("base height {base}; x {x0}..{x1}, y {y1} (top) .. {y0}, step {step}");
    for (y, row) in rows {
        let s: String = row.iter().map(|z| match z {
            None => ' ',
            Some(z) => { let d = ((z - base) / std::env::var("SK8_ZSTEP").ok().and_then(|v| v.parse::<f32>().ok()).unwrap_or(16.0)).round() as i32; if d == 0 { '.' } else if d > 0 { std::char::from_digit(d.min(9) as u32, 10).unwrap() } else { (b'a' + ((-d - 1).min(25) as u8)) as char } }
        }).collect();
        println!("{y:7.0} {s}");
    }
}
