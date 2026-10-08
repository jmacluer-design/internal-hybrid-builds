//! Source .phy collision models: the convex pieces a model collides with.
//!
//! Used when GMod won't build a model's physics for us (it refuses some models,
//! e.g. custom ones packed inside a map): Lua reads the .phy file itself and we
//! turn it into hulls. Layout as parsed by TAServers/source-parsers (MIT):
//!
//!   header { size, id, solidCount, checksum(8) }            (size bytes)
//!   per solid: { size, "VPHY", version(2), modelType(2), surfaceSize,
//!                compact surface header, ledge tree ... }
//!   a ledge tree's leaves ("ledges") are convex pieces: triangles whose
//!   edges index a vertex buffer of Vector4s (IVP space: metres, Y/Z swapped)

use glam::Vec3;

/// IVP space to Source units: x stays, IVP y is minus Source z, IVP z is Source y.
fn to_source(v: [f32; 3]) -> Vec3 {
    const INCHES_PER_METRE: f32 = 1.0 / 0.0254;
    Vec3::new(v[0], v[2], -v[1]) * INCHES_PER_METRE
}

struct Reader<'a>(&'a [u8]);
impl Reader<'_> {
    fn i32(&self, o: usize) -> Option<i32> { self.0.get(o..o + 4).map(|b| i32::from_le_bytes([b[0], b[1], b[2], b[3]])) }
    fn u32(&self, o: usize) -> Option<u32> { self.i32(o).map(|v| v as u32) }
    fn u16(&self, o: usize) -> Option<u16> { self.0.get(o..o + 2).map(|b| u16::from_le_bytes([b[0], b[1]])) }
    fn i16(&self, o: usize) -> Option<i16> { self.u16(o).map(|v| v as i16) }
    fn f32(&self, o: usize) -> Option<f32> { self.u32(o).map(f32::from_bits) }
}

// sizes of the packed structures
const SURFACE_HEADER: usize = 16;         // size, vphysicsId, version(2), modelType(2), surfaceSize
const COMPACT_SURFACE_HEADER: usize = 64;
const LEDGE_NODE: usize = 28;             // right(4) compact(4) centre(12) radius(4) boxSizes(3) unused(1)
const LEDGE: usize = 16;                  // pointOffset(4) boneIndex(4) flags(4) trianglesCount(2) unknown(2)
const TRIANGLE: usize = 16;               // data(4) + 3 edges(4)

/// Convex pieces as triangle lists in Source units, model space.
pub fn hulls(data: &[u8]) -> Result<Vec<Vec<[Vec3; 3]>>, String> {
    let r = Reader(data);
    let header_size = r.i32(0).ok_or("truncated header")? as usize;
    let solids = r.i32(8).ok_or("truncated header")?;
    if !(1..=128).contains(&solids) || header_size < 16 || header_size > data.len() {
        return Err(format!("not a .phy (solids {solids}, header {header_size})"));
    }
    let mut out = Vec::new();
    let mut offset = header_size;
    for _ in 0..solids {
        let size = r.i32(offset).ok_or("truncated solid")? as usize;
        let id = data.get(offset + 4..offset + 8).ok_or("truncated solid")?;
        let model_type = r.i16(offset + 10).ok_or("truncated solid")?;
        if id != b"VPHY" {
            return Err("old-style .phy (no VPHY header) is not supported".into());
        }
        if model_type != 0 {
            return Err(format!("unsupported collision model type {model_type}"));
        }
        let surface = offset + SURFACE_HEADER;
        // the compact surface header: the ledge-tree root offset is relative to massCentre
        let mass_centre = surface + 16;
        let root_rel = r.i32(surface + 16 + 12 + 12 + 4 + 4).ok_or("truncated surface")?;
        // dragAxisAreas(12) axisMapSize(4) massCentre(12) inertia(12) radius(4)
        // flags(4) ledgetreeRoot(4) unused(8) "IVPS"(4): the tag is at +60
        let ivps = data.get(surface + 60..surface + 64).ok_or("truncated surface")?;
        if ivps != b"IVPS" {
            return Err("compact surface without IVPS tag".into());
        }
        let root = (mass_centre as i64 + root_rel as i64) as usize;
        let mut stack = vec![root];
        let mut guard = 0;
        while let Some(node) = stack.pop() {
            guard += 1;
            if guard > 100_000 || node + LEDGE_NODE > data.len() {
                return Err("bad ledge tree".into());
            }
            let right = r.i32(node).ok_or("bad node")?;
            let compact = r.i32(node + 4).ok_or("bad node")?;
            if right == 0 {
                let ledge = (node as i64 + compact as i64) as usize;
                out.push(ledge_triangles(&r, ledge)?);
            } else {
                stack.push((node as i64 + right as i64) as usize);
                stack.push(node + LEDGE_NODE);
            }
        }
        offset += size + 4;
    }
    let _ = COMPACT_SURFACE_HEADER;
    Ok(out)
}

fn ledge_triangles(r: &Reader, ledge: usize) -> Result<Vec<[Vec3; 3]>, String> {
    let point_offset = r.i32(ledge).ok_or("bad ledge")?;
    let count = r.u16(ledge + 12).ok_or("bad ledge")? as usize;
    if count > 65_535 {
        return Err("bad ledge".into());
    }
    let points = (ledge as i64 + point_offset as i64) as usize;
    let vertex = |i: u32| -> Result<Vec3, String> {
        let o = points + i as usize * 16;
        Ok(to_source([r.f32(o).ok_or("bad vertex")?, r.f32(o + 4).ok_or("bad vertex")?, r.f32(o + 8).ok_or("bad vertex")?]))
    };
    let mut tris = Vec::with_capacity(count);
    for t in 0..count {
        let base = ledge + LEDGE + t * TRIANGLE;
        let mut v = [Vec3::ZERO; 3];
        for (e, slot) in v.iter_mut().enumerate() {
            let edge = r.u32(base + 4 + e * 4).ok_or("bad triangle")?;
            *slot = vertex(edge & 0xffff)?;
        }
        if v.iter().all(|p| p.is_finite()) {
            tris.push(v);
        }
    }
    Ok(tris)
}

/// The .mdl's collision box (studiohdr hull_min / hull_max), for fallback and checks.
pub fn mdl_hull(data: &[u8]) -> Option<(Vec3, Vec3)> {
    if data.get(0..4)? != b"IDST" {
        return None;
    }
    let r = Reader(data);
    let v = |o: usize| Some(Vec3::new(r.f32(o)?, r.f32(o + 4)?, r.f32(o + 8)?));
    Some((v(104)?, v(116)?))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn load(name: &str) -> Option<Vec<u8>> {
        std::fs::read(format!("/tmp/phy/{name}")).ok()
    }

    #[test]
    fn real_models_parse_and_fit_their_bounds() {
        let models = [
            "w_hammer", "w_sledgehammer",
            "a0fw_1lt_left_0pg_+0416x-0064x0000", "a0fw_1lt_left_-379pg_+0416x-0064x-016dn",
        ];
        let mut tested = 0;
        for m in models {
            let (Some(phy), Some(mdl)) = (load(&format!("{m}.phy")), load(&format!("{m}.mdl"))) else { continue };
            let hulls = hulls(&phy).unwrap_or_else(|e| panic!("{m}: {e}"));
            assert!(!hulls.is_empty(), "{m}: no pieces");
            let (lo, hi) = hulls.iter().flatten().flatten().fold((Vec3::MAX, Vec3::MIN), |(a, b), p| (a.min(*p), b.max(*p)));
            let (mlo, mhi) = mdl_hull(&mdl).expect("mdl hull");
            eprintln!("PHY {m}: {} pieces, {} triangles, bounds {:.1?}..{:.1?}, mdl hull {:.1?}..{:.1?}",
                hulls.len(), hulls.iter().map(|h| h.len()).sum::<usize>(), lo.to_array(), hi.to_array(), mlo.to_array(), mhi.to_array());
            // the collision model sits inside the model's hull box (with a little slack)
            let slack = (mhi - mlo).length() * 0.1 + 2.0;
            assert!(lo.cmpge(mlo - Vec3::splat(slack)).all() && hi.cmple(mhi + Vec3::splat(slack)).all(), "{m}: shape outside the model's box");
            // and fills most of it
            let (a, b) = ((hi - lo).max_element(), (mhi - mlo).max_element());
            assert!(a > b * 0.5, "{m}: shape much smaller than the model ({a} vs {b})");
            tested += 1;
        }
        if tested == 0 { eprintln!("PHY: no test models in /tmp/phy (skipped)"); }
    }

    #[test]
    fn a_ragdoll_with_many_solids_parses() {
        let Some(phy) = load("fatty.phy") else { return };
        let h = hulls(&phy).expect("parses");
        assert!(h.len() > 5, "one piece per body part");
    }

    #[test]
    fn junk_is_rejected_not_panicking() {
        assert!(hulls(b"not a phy file at all").is_err());
        assert!(hulls(&[0u8; 4]).is_err());
        let mut bad = vec![16u8, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0];
        bad.extend_from_slice(&[200, 0, 0, 0]);
        assert!(hulls(&bad).is_err());
    }
}
