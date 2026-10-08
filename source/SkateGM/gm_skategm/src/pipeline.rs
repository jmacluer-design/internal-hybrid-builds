//! Making static geometry skateable, as one pass over everything static at
//! once: the map's brushes and terrain *and* the static props placed in it.
//! (Doing the map alone and adding props afterwards left every place a prop
//! meets the map - a wooden kicker against a concrete platform - untreated.)
//!
//! The steps, in order, and why:
//!  1. weld near-miss vertices, drop duplicates  - pieces that almost meet
//!     leave micro-steps; duplicate faces hide creases
//!  2. drop faces hidden just under a floor       - a buried front flush with
//!     the floor catches the wheels
//!  3. fix T-junctions                            - so neighbours share edges
//!     (the engine pairs edges by shared vertices to smooth its contacts)
//!  4. find rails                                 - on the cleaned surface,
//!     before anything is added, so none run along our own additions
//!  5. ramps over small ledges and curbs          - a board stops dead on a
//!     lip a player just steps over
//!  6. curves in concave creases and ramp feet    - Skate 3 treats a sudden
//!     change of direction as an impact
use crate::cleanup::{self, FilletStats, Heights};
use crate::world::{Smoothing, TAG_DISPLACEMENT, TAG_STEP_RAMP};
use glam::Vec3;
use std::time::Instant;

pub struct Output {
    pub tris: Vec<[Vec3; 3]>,
    pub tags: Vec<u8>,
    pub rails: Vec<Vec<Vec3>>,
    pub report: String,
    /// (step, ms)
    pub timings: Vec<(&'static str, f64)>,
}

pub fn fillet_reach(opts: &Smoothing) -> f32 {
    if !opts.creases { 0.0 } else if opts.terrain >= 2 { 24.0 } else { 16.0 }
}

pub fn run(tris: Vec<[Vec3; 3]>, tags: Vec<u8>, opts: &Smoothing) -> Output {
    let mut timings = Vec::new();
    let mut t = Instant::now();
    let lap = |name: &'static str, t: &mut Instant, timings: &mut Vec<(&'static str, f64)>| {
        timings.push((name, t.elapsed().as_secs_f64() * 1000.0));
        *t = Instant::now();
    };
    let (tris, tags, welded, deduped) = if cleanup::off("weld") { let n = tris.len(); (tris, tags, 0, n - n) } else { cleanup::weld_and_dedupe(tris, tags, 0.15) };
    lap("weld", &mut t, &mut timings);
    let (tris, tags, hidden) = if cleanup::off("hidden") { (tris, tags, 0) } else { cleanup::remove_hidden_under_floor(tris, tags) };
    lap("hidden faces", &mut t, &mut timings);
    let (tris, tags, tjunctions) = cleanup::fix_t_junctions(tris, tags, 0.05);
    lap("seams", &mut t, &mut timings);
    let ground = Heights::new(&tris);
    lap("height index", &mut t, &mut timings);
    let (rails, census) = crate::rails::find_with(&tris, (!cleanup::off("trenches")).then_some(&ground));
    lap("rails", &mut t, &mut timings);
    let (ramps, covered) = if cleanup::off("ledges") { (Vec::new(), Vec::new()) } else { cleanup::step_ramps_spans(&tris, &ground, 0.05, opts.max_step.clamp(0.0, 12.0)) };
    lap("ledge ramps", &mut t, &mut timings);
    // the faces under the steps the ramps now cover go (cut where a ramp
    // covers only part of one); SK8_OFF=coverrisers to compare, SK8_ON=
    // riserswhole for the earlier whole-face-only version
    let drop = if !cleanup::off("coverrisers") && cleanup::on("riserswhole") { cleanup::covered_risers(&tris, &covered) } else { Vec::new() };
    let clipped = if !cleanup::off("coverrisers") && !cleanup::on("riserswhole") { cleanup::clip_covered_risers(&tris, &covered) } else { Vec::new() };
    let risers = drop.iter().filter(|&&d| d).count() + clipped.iter().filter(|c| c.is_some()).count();
    // undersides lower than a wheel can get under go (SK8_OFF=undersides)
    let low = if cleanup::off("undersides") { Vec::new() } else { cleanup::low_undersides(&tris, &ground, 3.0) };
    let undersides = low.iter().filter(|c| c.is_some()).count();
    let under_pieces: usize = low.iter().filter_map(|c| c.as_ref().map(|v| v.len())).sum();
    let mut fs = FilletStats::default();
    let coarse: Vec<bool> = tags.iter().map(|&g| g == TAG_DISPLACEMENT).collect();
    let fillets = if cleanup::off("curves") { Vec::new() } else { cleanup::transition_fillets_with(&tris, Some(&coarse), &ground, fillet_reach(opts), 5.0, &mut fs) };
    lap("curves", &mut t, &mut timings);
    let report = format!(
        "{welded} near-miss joints welded ({deduped} duplicates dropped), {hidden} faces hidden under floors removed, \
         {tjunctions} T-junctions fixed, {} ledges ramped, {} of {} creases rounded + {} ramp feet + {} lips at ramp feet bridged \
         ({} triangles), {} rails ({} lips){}",
        ramps.len() / 2, fs.rounded, fs.creases, fs.feet, fs.lips, fillets.len(), census.rails, census.lips,
        format!("{}{}", if risers > 0 { format!(", {risers} faces under ramps removed") } else { String::new() },
            if undersides > 0 { format!(", {undersides} low undersides removed ({under_pieces} pieces kept)") } else { String::new() })
    );
    let (tris, tags) = if undersides > 0 {
        let mut t2 = Vec::with_capacity(tris.len());
        let mut g2 = Vec::with_capacity(tags.len());
        for ((t, g), c) in tris.into_iter().zip(tags).zip(low) {
            match c {
                None => { t2.push(t); g2.push(g); }
                Some(pieces) => { for pc in pieces { t2.push(pc); g2.push(g); } }
            }
        }
        // (the riser masks below were made for the full list: re-made for this one)
        (t2, g2)
    } else { (tris, tags) };
    let (drop, clipped) = if undersides > 0 && (!drop.is_empty() || !clipped.is_empty()) {
        let d = if drop.is_empty() { Vec::new() } else { cleanup::covered_risers(&tris, &covered) };
        let c = if clipped.is_empty() { Vec::new() } else { cleanup::clip_covered_risers(&tris, &covered) };
        (d, c)
    } else { (drop, clipped) };
    let (mut tris, mut tags) = if !clipped.is_empty() && risers > 0 {
        let mut t2 = Vec::with_capacity(tris.len());
        let mut g2 = Vec::with_capacity(tags.len());
        for ((t, g), c) in tris.into_iter().zip(tags).zip(clipped) {
            match c {
                None => { t2.push(t); g2.push(g); }
                Some(pieces) => { for pc in pieces { t2.push(pc); g2.push(g); } }
            }
        }
        (t2, g2)
    } else if risers > 0 {
        let mut keep = drop.iter().map(|d| !d);
        let mut keep2 = drop.iter().map(|d| !d);
        let t: Vec<_> = tris.into_iter().filter(|_| keep.next().unwrap_or(true)).collect();
        let g: Vec<_> = tags.into_iter().filter(|_| keep2.next().unwrap_or(true)).collect();
        (t, g)
    } else { (tris, tags) };
    tags.extend(std::iter::repeat(TAG_STEP_RAMP).take(ramps.len()));
    tags.extend(std::iter::repeat(crate::world::TAG_CURVE).take(fillets.len()));
    let base = tris.len();
    tris.extend(ramps);
    // (SK8_ON=rampcurves) curves where a ramp meets the ground it runs onto:
    // the curves pass ran before the ramps, so a ledge ramp onto rising
    // terrain - a slope's foot standing a hair above the floor - met it at a
    // bare crease (tl_skatepark -1780 -1060: 25 degrees, 5.6 -> 3.9 m/s)
    let ramp_curves = if cleanup::on("rampcurves") && !cleanup::off("curves") && tris.len() > base {
        let only: Vec<bool> = (0..tris.len()).map(|k| k >= base).collect();
        let coarse: Vec<bool> = tags[..tris.len()].iter().map(|&g| g == TAG_DISPLACEMENT).collect();
        let ground = Heights::new(&tris);
        cleanup::transition_fillets_only(&tris, Some(&coarse), &only, &ground, fillet_reach(opts), 5.0)
    } else { Vec::new() };
    if !ramp_curves.is_empty() {
        lap("ramp curves", &mut t, &mut timings);
    }
    tris.extend(fillets);
    tags.extend(std::iter::repeat(crate::world::TAG_CURVE).take(ramp_curves.len()));
    tris.extend(ramp_curves);
    let (tris, tags) = if cleanup::on("tjramps") { let (t, g, _) = cleanup::fix_t_junctions(tris, tags, 0.05); (t, g) } else { (tris, tags) };
    lap("seams after ramps", &mut t, &mut timings);
    // (SK8_ON=railsafter: rails found on the smoothed collision, so a lip a
    // ledge ramp now rolls over is no longer a rail)
    let rails = if cleanup::on("railsafter") { crate::rails::find(&tris).0 } else { rails };
    Output { tris, tags, rails, report, timings }
}

pub fn timing_line(timings: &[(&'static str, f64)]) -> String {
    timings.iter().map(|(n, ms)| format!("{n} {ms:.0}")).collect::<Vec<_>>().join(", ")
}
