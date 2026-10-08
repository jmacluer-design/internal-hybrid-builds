//! Times the entity cleanup steps (scene.rs clean_entities) on one mesh: a
//! flat Lua list of numbers (harness/vc_chunks/*.lua), turned up-facing as
//! the add-on does (IM.Orient "up").
//!     cargo run --release --no-default-features --example entclean -- <chunk.lua>
use gmcl_skategm_win64::cleanup;
use glam::Vec3;
use std::time::Instant;

fn main() {
    let path = std::env::args().nth(1).expect("chunk.lua");
    let text = std::fs::read_to_string(&path).unwrap();
    let nums: Vec<f32> = text
        .split(|c: char| !(c.is_ascii_digit() || c == '.' || c == '-' || c == 'e'))
        .filter_map(|s| s.parse::<f32>().ok())
        .collect();
    let mut tris: Vec<[Vec3; 3]> = Vec::new();
    for c in nums.chunks_exact(9) {
        let (a, b, d) = (Vec3::new(c[0], c[1], c[2]), Vec3::new(c[3], c[4], c[5]), Vec3::new(c[6], c[7], c[8]));
        let n = (b - a).cross(d - a);
        let l = n.length();
        if l <= 0.0 || (n.z / l).abs() <= 0.2 {
            tris.push([a, b, d]);
            tris.push([a, d, b]);
        } else if n.z < 0.0 {
            tris.push([a, d, b]);
        } else {
            tris.push([a, b, d]);
        }
    }
    println!("{} triangles", tris.len());
    let mut t = Instant::now();
    let mut lap = |name: &str, n: usize| {
        println!("{name:>22}: {:8.0} ms  ({n} triangles)", t.elapsed().as_secs_f64() * 1000.0);
        t = Instant::now();
    };
    const MINE: u8 = 200;
    let n = tris.len();
    let (w, g, _, _) = cleanup::weld_and_dedupe(tris, vec![MINE; n], 0.15);
    lap("weld", w.len());
    let (h, g, _) = cleanup::remove_hidden_under_floor(w, g);
    lap("hidden", h.len());
    let n = h.len();
    let _ = g;
    let (mut e, _, _) = cleanup::fix_t_junctions(h, vec![MINE; n], 0.05);
    lap("t-junctions", e.len());
    let (rails, _) = gmcl_skategm_win64::rails::find(&e);
    lap("rails", rails.len());
    let ground = cleanup::Heights::new(&e);
    lap("heights", e.len());
    let (ramps, covered) = cleanup::step_ramps_spans(&e, &ground, 0.05, 8.0);
    lap("ledge ramps", ramps.len());
    let low = cleanup::low_undersides(&e, &ground, 3.0);
    lap("undersides", low.iter().filter(|x| x.is_some()).count());
    let clipped = cleanup::clip_covered_risers(&e, &covered);
    lap("covered risers", clipped.iter().filter(|x| x.is_some()).count());
    e.extend(ramps);
    let ground = cleanup::Heights::new(&e);
    let fillets = cleanup::transition_fillets(&e, &ground, 16.0);
    lap("curves (1 degree)", fillets.len());
    let coarse = vec![true; e.len()];
    let fillets = cleanup::transition_fillets_with(&e, Some(&coarse), &ground, 16.0, 5.0, &mut cleanup::FilletStats::default());
    lap("curves (as terrain)", fillets.len());
}
