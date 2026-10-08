//! Offline adapter for the preservation-first University v15 package.
//!
//! Copyrighted payloads are never compiled into the project. The tracked
//! Python adapter reconstructs this module's deterministic cache under
//! `assets/private/university` from the user's legally owned game data.

use std::{
    collections::HashMap,
    fmt, fs,
    io::{Cursor, Read},
    path::{Path, PathBuf},
};

#[cfg(test)]
use bevy::camera::Exposure;
use bevy::{
    asset::RenderAssetUsages,
    image::{ImageAddressMode, ImageFilterMode, ImageSampler, ImageSamplerDescriptor},
    pbr::Lightmap,
    prelude::*,
    render::render_resource::{Extent3d, Face, PrimitiveTopology, TextureDimension, TextureFormat},
};
use flate2::read::ZlibDecoder;
use half::f16;
use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::{
    ground_provider::{GroundProvider, GroundVec3, ImportedCollisionTriangle, SurfaceId},
    sim::{SkateGround, SkateSim},
};

pub const CACHE_RELATIVE_PATH: &str = "assets/private/university/cache";
// Bevy's PBR pass multiplies lightmaps by the physical camera exposure after
// `StandardMaterial::lightmap_exposure`. Its default EV100 9.7 evaluates to
// roughly 0.001, but SK8's recovered world pass consumes the decoded
// `encoded²` lightmap at unit exposure before its own tone tail. This EV100
// makes Bevy's physical exposure multiplier exactly 1:
//     exp2(-ev100) / 1.2 = 1
pub const RETAIL_LIGHTMAP_VIEW_EV100: f32 = -0.263_034_4;
pub const UNIVERSITY_AMBIENT_BRIGHTNESS: f32 = 0.22;
const EXPECTED_MATERIALS: usize = 8_729;
const EXPECTED_TEXTURES: usize = 2_046;
const EXPECTED_VERTICES: usize = 2_120_046;
const EXPECTED_INDICES: usize = 4_936_851;
const EXPECTED_VISUAL_TRIANGLES: usize = 1_645_617;
const EXPECTED_COLLISION_TRIANGLES: usize = 1_133_643;
const EXPECTED_RAILS: usize = 4_201;
const EXPECTED_SEGMENTS: usize = 27_008;
const EXPECTED_LIGHTMAPPED_DRAWS: usize = 8_489;
const EXPECTED_SKY_VERTICES: usize = 230;
const EXPECTED_SKY_INDICES: usize = 1_140;
const EXPECTED_SKY_PANORAMA_WIDTH: u32 = 2_048;
const EXPECTED_SKY_PANORAMA_HEIGHT: u32 = 256;
const RETAIL_SKY_HEIGHT: f32 = 165.0;
const RETAIL_SKY_SCALE: f32 = 0.5;
const COLLISION_CELL_SIZE_METRES: f32 = 16.0;
const PACKAGE_SHA256: &str = "2328ede92a1546b4bd08adc4425cdb95769ff9bcd519df1909643a26e1c8633a";
const RETAIL_SKY_MODEL_SHA256: &str =
    "0f828116c1661a24e7fb1717fa3130b844bf2ae9536ba295e3977de394893dae";
const RETAIL_SKY_TEXTURES_SHA256: &str =
    "bee4275f7097f7fe41e6cdc83b6255864e7a15f304b2518a468b2c65a6c0431b";

#[derive(Resource, Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ActiveLevel {
    FlatParityFixture,
    #[default]
    University,
}

impl ActiveLevel {
    pub fn selected() -> Self {
        let arguments = std::env::args().collect::<Vec<_>>();
        let environment = std::env::var("SKATE3_LEVEL").ok();
        Self::selected_from(arguments.iter().map(String::as_str), environment.as_deref())
    }

    fn selected_from<'a>(
        arguments: impl IntoIterator<Item = &'a str>,
        environment: Option<&str>,
    ) -> Self {
        for argument in arguments {
            if let Some(level) = Self::from_selector(argument) {
                return level;
            }
        }
        environment
            .and_then(Self::from_selector)
            .unwrap_or_default()
    }

    fn from_selector(value: &str) -> Option<Self> {
        let value = value
            .strip_prefix("--level=")
            .or_else(|| value.strip_prefix("--"))
            .unwrap_or(value);
        if value.eq_ignore_ascii_case("university") {
            Some(Self::University)
        } else if value.eq_ignore_ascii_case("flat")
            || value.eq_ignore_ascii_case("parity")
            || value.eq_ignore_ascii_case("flat-parity-fixture")
        {
            Some(Self::FlatParityFixture)
        } else {
            None
        }
    }
}

#[derive(Debug)]
pub struct UniversityError(String);

impl fmt::Display for UniversityError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for UniversityError {}

impl From<std::io::Error> for UniversityError {
    fn from(error: std::io::Error) -> Self {
        Self(error.to_string())
    }
}

impl From<serde_json::Error> for UniversityError {
    fn from(error: serde_json::Error) -> Self {
        Self(error.to_string())
    }
}

fn failure(message: impl Into<String>) -> UniversityError {
    UniversityError(message.into())
}

#[derive(Clone, Debug, Deserialize)]
struct CacheFile {
    file: String,
    bytes: usize,
    sha256: String,
}

#[derive(Clone, Debug, Deserialize)]
struct SourcePackage {
    file: String,
    bytes: usize,
    sha256: String,
}

#[derive(Clone, Debug, Deserialize)]
struct RetailSkyboxRecord {
    model: RetailSourceFile,
    textures: RetailSourceFile,
    mesh_name: String,
    vertices: usize,
    indices: usize,
    triangles: usize,
    panorama_width: u32,
    panorama_height: u32,
    panorama_decoded_bytes: usize,
    panorama_decoded_sha256: String,
}

#[allow(dead_code)] // Absolute provenance path is reported by the cache builder.
#[derive(Clone, Debug, Deserialize)]
struct RetailSourceFile {
    path: String,
    bytes: usize,
    sha256: String,
}

#[derive(Clone, Debug, Deserialize)]
struct SpawnRecord {
    position: [f32; 3],
    heading_radians: f32,
    provenance: String,
}

#[derive(Clone, Debug, Deserialize)]
struct CountRecord {
    materials: usize,
    textures: usize,
    vertices: usize,
    indices: usize,
    visual_triangles: usize,
    collision_triangles: usize,
    grind_rails: usize,
    native_grind_segments: usize,
}

#[allow(dead_code)] // Preserved roles remain available to future family adapters.
#[derive(Clone, Debug, Deserialize)]
struct TextureRecord {
    id: u32,
    name: String,
    width: u32,
    height: u32,
    source_color_space: u32,
    decoded_sha256: String,
    compressed_sha256: String,
    decoded_bytes: usize,
    file: String,
    roles: Vec<String>,
}

#[allow(dead_code)] // Semantic/UV-set metadata is retained beyond stock PBR slots.
#[derive(Clone, Debug, Default, Deserialize)]
struct TextureBinding {
    semantic: String,
    texture: u32,
    uv_set: u32,
    address_u: u32,
    address_v: u32,
}

#[allow(dead_code)] // Exact retail fields intentionally outlive current rendering support.
#[derive(Clone, Debug, Deserialize)]
struct MaterialRecord {
    id: u32,
    name: String,
    display_color: [f32; 3],
    roughness: f32,
    emissive_intensity: f32,
    albedo_texture: u32,
    lightmap_texture: u32,
    baked_indirect_strength: f32,
    normal_texture: u32,
    orm_texture: u32,
    emissive_texture: u32,
    alpha_mode: u32,
    alpha_cutoff: f32,
    audio_surface: u32,
    physics_surface: u32,
    surface_pattern: u32,
    presentation_depth_layer: u32,
    #[serde(default)]
    retail_shader_family: Option<u32>,
    #[serde(default)]
    retail_render_flags: Option<u32>,
    #[serde(default)]
    retail_texture_bindings: Vec<TextureBinding>,
    #[serde(default)]
    secondary_albedo_texture: Option<u32>,
    #[serde(default)]
    blend_mask_texture: Option<u32>,
    #[serde(default)]
    blend_factor: Option<f32>,
    #[serde(default)]
    blend_mask_channel: Option<u32>,
    #[serde(default)]
    albedo_address_mode: Option<u32>,
    #[serde(default)]
    secondary_address_mode: Option<u32>,
    #[serde(default)]
    blend_mask_address_mode: Option<u32>,
    #[serde(default)]
    cull_mode: Option<u32>,
}

#[derive(Clone, Debug, Deserialize)]
struct RuntimeManifest {
    schema: u32,
    map_name: String,
    format_version: u32,
    source_package: SourcePackage,
    retail_skybox: RetailSkyboxRecord,
    spawn: SpawnRecord,
    bounds_min: [f32; 3],
    bounds_max: [f32; 3],
    counts: CountRecord,
    dynamic_lighting_enabled_by_default: bool,
    vertex_stride: usize,
    collision_stride: usize,
    draw_group_count: usize,
    cache_files: HashMap<String, CacheFile>,
    textures: Vec<TextureRecord>,
    materials: Vec<MaterialRecord>,
    preserved: Vec<String>,
    derived: Vec<String>,
    unsupported: Vec<String>,
}

#[derive(Clone, Copy, Debug)]
pub struct RetailSplineSegment {
    pub words: [u32; 30],
}

impl RetailSplineSegment {
    pub fn position(self, parameter: f32) -> Vec3 {
        let coefficient = |word: usize| f32::from_bits(self.words[word]);
        let a = Vec3::new(coefficient(0), coefficient(1), coefficient(2));
        let b = Vec3::new(coefficient(4), coefficient(5), coefficient(6));
        let c = Vec3::new(coefficient(8), coefficient(9), coefficient(10));
        let d = Vec3::new(coefficient(12), coefficient(13), coefficient(14));
        d + c * parameter + b * parameter.powi(2) + a * parameter.powi(3)
    }
}

#[allow(dead_code)] // Runtime acquisition thresholds are unresolved; data is still preserved.
#[derive(Clone, Debug)]
pub struct RetailGrindRail {
    pub name: String,
    pub closed: bool,
    pub spline_id: Option<u64>,
    pub type_signature: Option<u64>,
    pub retail_flags: Option<u32>,
    pub trailing_word: Option<u32>,
    pub authored_points: Vec<Vec3>,
    pub native_segments: Vec<RetailSplineSegment>,
}

#[derive(Resource, Clone, Debug)]
pub struct UniversityGrindRails {
    pub rails: Vec<RetailGrindRail>,
}

#[derive(Resource, Clone, Debug)]
pub struct UniversityLevel {
    cache_root: PathBuf,
    manifest: RuntimeManifest,
    pub grind_rails: UniversityGrindRails,
}

pub struct UniversityLoad {
    pub level: UniversityLevel,
    pub ground: SkateGround,
    pub sim: SkateSim,
}

impl UniversityLoad {
    pub fn load_and_validate() -> Result<Self, UniversityError> {
        let cache_root = Path::new(env!("CARGO_MANIFEST_DIR")).join(CACHE_RELATIVE_PATH);
        let manifest_path = cache_root.join("runtime_manifest.json");
        let manifest: RuntimeManifest =
            serde_json::from_slice(&fs::read(&manifest_path).map_err(|error| {
                failure(format!(
                    "University cache is unavailable at {}: {error}. Run \
                     \"LAUNCH UNIVERSITY MAP VISUAL TEST.bat\" to rebuild it.",
                    manifest_path.display()
                ))
            })?)?;
        validate_manifest_contract(&manifest)?;
        verify_cache_files(&cache_root, &manifest)?;
        let rails = parse_grind_rails(&fs::read(cache_file(
            &cache_root,
            &manifest,
            "grind_rails",
        )?)?)?;
        let collision = parse_collision(
            &fs::read(cache_file(&cache_root, &manifest, "collision")?)?,
            &manifest.materials,
        )?;
        let mut provider = GroundProvider::new();
        provider
            .add_indexed_triangle_mesh(collision, COLLISION_CELL_SIZE_METRES)
            .map_err(|error| failure(format!("University collision index: {error:?}")))?;

        let spawn = Vec3::from_array(manifest.spawn.position);
        let contact = provider
            .query_down(GroundVec3::new(spawn.x, spawn.y + 2.0, spawn.z), 4.0)
            .map_err(|error| failure(format!("University spawn query: {error:?}")))?
            .contact()
            .ok_or_else(|| failure("University spawn has no retail collision support"))?;
        let spawn_clearance = spawn.y - contact.point.y;
        if (spawn_clearance - 1.0).abs() > 0.02 {
            return Err(failure(format!(
                "University spawn/collision mismatch: marker y {}, collision y {}, \
                 clearance {}",
                spawn.y, contact.point.y, spawn_clearance
            )));
        }

        let mut sim = SkateSim::default();
        sim.position = Vec3::new(spawn.x, contact.point.y, spawn.z);
        sim.yaw = manifest.spawn.heading_radians;
        sim.view_yaw = manifest.spawn.heading_radians;
        sim.ground_normal = Vec3::new(contact.normal.x, contact.normal.y, contact.normal.z);
        sim.ground_surface_id = Some(contact.surface_id.0);
        Ok(Self {
            // Transition traversal is part of the main University simulation,
            // not a separate map mode. The runtime operates on University's
            // decoded collision provider directly.
            ground: SkateGround {
                provider,
                transition_test: true,
            },
            sim,
            level: UniversityLevel {
                cache_root,
                manifest,
                grind_rails: UniversityGrindRails { rails },
            },
        })
    }
}

fn validate_manifest_contract(manifest: &RuntimeManifest) -> Result<(), UniversityError> {
    let expected = [
        ("materials", manifest.counts.materials, EXPECTED_MATERIALS),
        ("textures", manifest.counts.textures, EXPECTED_TEXTURES),
        ("vertices", manifest.counts.vertices, EXPECTED_VERTICES),
        ("indices", manifest.counts.indices, EXPECTED_INDICES),
        (
            "visual triangles",
            manifest.counts.visual_triangles,
            EXPECTED_VISUAL_TRIANGLES,
        ),
        (
            "collision triangles",
            manifest.counts.collision_triangles,
            EXPECTED_COLLISION_TRIANGLES,
        ),
        ("grind rails", manifest.counts.grind_rails, EXPECTED_RAILS),
        (
            "grind segments",
            manifest.counts.native_grind_segments,
            EXPECTED_SEGMENTS,
        ),
    ];
    for (label, actual, expected) in expected {
        if actual != expected {
            return Err(failure(format!(
                "University {label} count is {actual}; expected {expected}"
            )));
        }
    }
    if manifest.schema != 2
        || manifest.format_version != 15
        || manifest.map_name != "University District"
        || manifest.vertex_stride != 56
        || manifest.collision_stride != 48
        || manifest.dynamic_lighting_enabled_by_default
        || manifest.source_package.sha256.to_ascii_lowercase() != PACKAGE_SHA256
        || manifest.materials.len() != EXPECTED_MATERIALS
        || manifest.textures.len() != EXPECTED_TEXTURES
        || manifest.retail_skybox.vertices != EXPECTED_SKY_VERTICES
        || manifest.retail_skybox.indices != EXPECTED_SKY_INDICES
        || manifest.retail_skybox.triangles * 3 != EXPECTED_SKY_INDICES
        || manifest.retail_skybox.panorama_width != EXPECTED_SKY_PANORAMA_WIDTH
        || manifest.retail_skybox.panorama_height != EXPECTED_SKY_PANORAMA_HEIGHT
        || manifest.retail_skybox.panorama_decoded_bytes
            != EXPECTED_SKY_PANORAMA_WIDTH as usize * EXPECTED_SKY_PANORAMA_HEIGHT as usize * 4
        || manifest.retail_skybox.model.sha256.to_ascii_lowercase() != RETAIL_SKY_MODEL_SHA256
        || manifest.retail_skybox.textures.sha256.to_ascii_lowercase() != RETAIL_SKY_TEXTURES_SHA256
    {
        return Err(failure("University runtime manifest contract is stale"));
    }
    if manifest
        .bounds_min
        .into_iter()
        .chain(manifest.bounds_max)
        .chain(manifest.spawn.position)
        .any(|value| !value.is_finite())
    {
        return Err(failure(
            "University manifest contains non-finite coordinates",
        ));
    }
    Ok(())
}

fn cache_file(
    root: &Path,
    manifest: &RuntimeManifest,
    key: &str,
) -> Result<PathBuf, UniversityError> {
    manifest
        .cache_files
        .get(key)
        .map(|record| root.join(&record.file))
        .ok_or_else(|| failure(format!("University cache omits {key}")))
}

fn verify_cache_files(root: &Path, manifest: &RuntimeManifest) -> Result<(), UniversityError> {
    let source = root.join(&manifest.source_package.file);
    verify_file(
        &source,
        manifest.source_package.bytes,
        &manifest.source_package.sha256,
    )?;
    for record in manifest.cache_files.values() {
        verify_file(&root.join(&record.file), record.bytes, &record.sha256)?;
    }
    for texture in &manifest.textures {
        verify_file(
            &root.join(&texture.file),
            fs::metadata(root.join(&texture.file))?.len() as usize,
            &texture.compressed_sha256,
        )?;
    }
    Ok(())
}

fn verify_file(path: &Path, bytes: usize, expected_hash: &str) -> Result<(), UniversityError> {
    let payload = fs::read(path).map_err(|error| {
        failure(format!(
            "University cache file {} is missing: {error}",
            path.display()
        ))
    })?;
    if payload.len() != bytes {
        return Err(failure(format!(
            "University cache file {} has {} bytes; expected {}",
            path.display(),
            payload.len(),
            bytes
        )));
    }
    let actual = format!("{:x}", Sha256::digest(&payload));
    if actual != expected_hash.to_ascii_lowercase() {
        return Err(failure(format!(
            "University cache file {} is stale (SHA-256 {})",
            path.display(),
            actual
        )));
    }
    Ok(())
}

fn f32_at(bytes: &[u8], offset: usize) -> f32 {
    f32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap())
}

fn u32_at(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap())
}

fn parse_collision(
    bytes: &[u8],
    materials: &[MaterialRecord],
) -> Result<Vec<ImportedCollisionTriangle>, UniversityError> {
    if bytes.len() != EXPECTED_COLLISION_TRIANGLES * 48 {
        return Err(failure("University collision block has an invalid size"));
    }
    let mut triangles = Vec::with_capacity(EXPECTED_COLLISION_TRIANGLES);
    let mut surfaces = std::collections::BTreeSet::new();
    for (index, record) in bytes.chunks_exact(48).enumerate() {
        let point = |offset| {
            GroundVec3::new(
                f32_at(record, offset),
                f32_at(record, offset + 4),
                f32_at(record, offset + 8),
            )
        };
        let source_surface = u32_at(record, 36);
        let material = u32_at(record, 40);
        let material_record = materials
            .get(material as usize - 1)
            .filter(|record| record.id == material)
            .ok_or_else(|| {
                failure(format!(
                    "University collision triangle {index} references material {material}"
                ))
            })?;
        let surface = material_record.audio_surface
            | (material_record.physics_surface << 7)
            | (material_record.surface_pattern << 12);
        let edge_codes = (record[47] != 0).then_some([record[44], record[45], record[46]]);
        surfaces.insert(surface);
        triangles.push(
            ImportedCollisionTriangle::new(
                point(0),
                point(12),
                point(24),
                SurfaceId(surface),
                material,
                source_surface,
                edge_codes,
            )
            .map_err(|error| {
                failure(format!(
                    "University collision triangle {index} is invalid: {error:?}"
                ))
            })?,
        );
    }
    if surfaces.len() != 183 {
        return Err(failure(format!(
            "University collision has {} surface IDs; expected 183",
            surfaces.len()
        )));
    }
    Ok(triangles)
}

struct ByteReader<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> ByteReader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    fn take(&mut self, count: usize) -> Result<&'a [u8], UniversityError> {
        let end = self
            .offset
            .checked_add(count)
            .ok_or_else(|| failure("University binary offset overflow"))?;
        let value = self
            .bytes
            .get(self.offset..end)
            .ok_or_else(|| failure("University binary is truncated"))?;
        self.offset = end;
        Ok(value)
    }

    fn u32(&mut self) -> Result<u32, UniversityError> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }

    fn u64(&mut self) -> Result<u64, UniversityError> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }

    fn string(&mut self) -> Result<String, UniversityError> {
        let count = self.u32()? as usize;
        String::from_utf8(self.take(count)?.to_vec())
            .map_err(|_| failure("University rail name is not UTF-8"))
    }
}

fn parse_grind_rails(bytes: &[u8]) -> Result<Vec<RetailGrindRail>, UniversityError> {
    let mut reader = ByteReader::new(bytes);
    let mut rails = Vec::with_capacity(EXPECTED_RAILS);
    let mut segments = 0;
    for _ in 0..EXPECTED_RAILS {
        let name = reader.string()?;
        let closed = reader.u32()? != 0;
        let representation = reader.u32()?;
        let rail = if representation == 0 {
            let count = reader.u32()? as usize;
            let mut authored_points = Vec::with_capacity(count);
            for _ in 0..count {
                let bytes = reader.take(12)?;
                authored_points.push(Vec3::new(
                    f32_at(bytes, 0),
                    f32_at(bytes, 4),
                    f32_at(bytes, 8),
                ));
            }
            RetailGrindRail {
                name,
                closed,
                spline_id: None,
                type_signature: None,
                retail_flags: None,
                trailing_word: None,
                authored_points,
                native_segments: Vec::new(),
            }
        } else if representation == 1 {
            let spline_id = reader.u64()?;
            let type_signature = reader.u64()?;
            let flags = reader.u32()?;
            let trailing = reader.u32()?;
            let count = reader.u32()? as usize;
            let mut native_segments = Vec::with_capacity(count);
            for _ in 0..count {
                let mut words = [0_u32; 30];
                for word in &mut words {
                    *word = reader.u32()?;
                }
                let segment = RetailSplineSegment { words };
                if !segment.position(0.0).is_finite() || !segment.position(1.0).is_finite() {
                    return Err(failure("University rail has non-finite endpoints"));
                }
                native_segments.push(segment);
            }
            segments += count;
            RetailGrindRail {
                name,
                closed,
                spline_id: Some(spline_id),
                type_signature: Some(type_signature),
                retail_flags: Some(flags),
                trailing_word: Some(trailing),
                authored_points: Vec::new(),
                native_segments,
            }
        } else {
            return Err(failure(format!(
                "University rail uses unsupported representation {representation}"
            )));
        };
        rails.push(rail);
    }
    if reader.offset != bytes.len() || segments != EXPECTED_SEGMENTS {
        return Err(failure(format!(
            "University grind inventory mismatch: {} rails, {segments} segments, \
             {} trailing bytes",
            rails.len(),
            bytes.len().saturating_sub(reader.offset)
        )));
    }
    Ok(rails)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum TextureDecode {
    EncodedSquared,
    LinearData,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct TextureKey {
    id: u32,
    decode: TextureDecode,
    address_u: u32,
    address_v: u32,
    mip_zero: bool,
}

fn texture_addresses(material: &MaterialRecord, texture_id: u32, lightmap: bool) -> (u32, u32) {
    if lightmap {
        return (1, 1);
    }
    material
        .retail_texture_bindings
        .iter()
        .find(|binding| binding.texture == texture_id)
        .map(|binding| (binding.address_u, binding.address_v))
        .unwrap_or((
            material.albedo_address_mode.unwrap_or(0),
            material.albedo_address_mode.unwrap_or(0),
        ))
}

fn image_handle(
    key: TextureKey,
    level: &UniversityLevel,
    cache: &mut HashMap<TextureKey, Handle<Image>>,
    images: &mut Assets<Image>,
) -> Result<Handle<Image>, UniversityError> {
    if key.id == 0 {
        return Ok(Handle::default());
    }
    if let Some(handle) = cache.get(&key) {
        return Ok(handle.clone());
    }
    let record = level
        .manifest
        .textures
        .get(key.id as usize - 1)
        .filter(|record| record.id == key.id)
        .ok_or_else(|| failure(format!("University texture {} is absent", key.id)))?;
    let compressed = fs::read(level.cache_root.join(&record.file))?;
    let mut rgba = Vec::with_capacity(record.decoded_bytes);
    ZlibDecoder::new(Cursor::new(compressed)).read_to_end(&mut rgba)?;
    if rgba.len() != record.decoded_bytes
        || format!("{:x}", Sha256::digest(&rgba)) != record.decoded_sha256
    {
        return Err(failure(format!(
            "University texture {} ({}) did not decode byte-exactly",
            record.id, record.name
        )));
    }
    let (upload_bytes, format, mip_level_count) = if key.mip_zero {
        let (bytes, format) = if key.decode == TextureDecode::EncodedSquared {
            (encoded_squared_half_rgba(&rgba), TextureFormat::Rgba16Float)
        } else {
            (rgba, TextureFormat::Rgba8Unorm)
        };
        (bytes, format, 1)
    } else if key.decode == TextureDecode::EncodedSquared {
        let (bytes, mip_level_count) =
            encoded_squared_half_rgba_mips(&rgba, record.width, record.height);
        (bytes, TextureFormat::Rgba16Float, mip_level_count)
    } else {
        let (bytes, mip_level_count) = linear_rgba8_mips(&rgba, record.width, record.height);
        (bytes, TextureFormat::Rgba8Unorm, mip_level_count)
    };
    let mut image = Image::new_uninit(
        Extent3d {
            width: record.width,
            height: record.height,
            depth_or_array_layers: 1,
        },
        TextureDimension::D2,
        format,
        RenderAssetUsages::all(),
    );
    image.data = Some(upload_bytes);
    image.texture_descriptor.mip_level_count = mip_level_count;
    let address = |value| match value {
        0 => ImageAddressMode::Repeat,
        1 => ImageAddressMode::ClampToEdge,
        3 => ImageAddressMode::MirrorRepeat,
        _ => ImageAddressMode::ClampToEdge,
    };
    image.sampler = ImageSampler::Descriptor(ImageSamplerDescriptor {
        address_mode_u: address(key.address_u),
        address_mode_v: address(key.address_v),
        address_mode_w: ImageAddressMode::ClampToEdge,
        mag_filter: ImageFilterMode::Linear,
        min_filter: ImageFilterMode::Linear,
        mipmap_filter: if key.mip_zero {
            ImageFilterMode::Nearest
        } else {
            ImageFilterMode::Linear
        },
        lod_min_clamp: 0.0,
        lod_max_clamp: (mip_level_count - 1) as f32,
        anisotropy_clamp: if key.mip_zero { 1 } else { 8 },
        ..default()
    });
    let handle = images.add(image);
    cache.insert(key, handle.clone());
    Ok(handle)
}

fn encoded_squared_half_rgba(rgba: &[u8]) -> Vec<u8> {
    let mut linear = Vec::with_capacity(rgba.len() * 2);
    for texel in rgba.chunks_exact(4) {
        for channel in &texel[..3] {
            let encoded = f32::from(*channel) / 255.0;
            linear.extend_from_slice(&f16::from_f32(encoded * encoded).to_le_bytes());
        }
        linear.extend_from_slice(&f16::from_f32(f32::from(texel[3]) / 255.0).to_le_bytes());
    }
    linear
}

fn next_mip_extent(width: u32, height: u32) -> (u32, u32) {
    ((width / 2).max(1), (height / 2).max(1))
}

fn downsample_rgba_f32(source: &[[f32; 4]], width: u32, height: u32) -> Vec<[f32; 4]> {
    let (next_width, next_height) = next_mip_extent(width, height);
    let mut target = Vec::with_capacity((next_width * next_height) as usize);
    for y in 0..next_height {
        for x in 0..next_width {
            let mut sum = [0.0; 4];
            for offset_y in 0..2 {
                for offset_x in 0..2 {
                    let source_x = (x * 2 + offset_x).min(width - 1);
                    let source_y = (y * 2 + offset_y).min(height - 1);
                    let texel = source[(source_y * width + source_x) as usize];
                    for channel in 0..4 {
                        sum[channel] += texel[channel];
                    }
                }
            }
            target.push(sum.map(|channel| channel * 0.25));
        }
    }
    target
}

fn encoded_squared_half_rgba_mips(rgba: &[u8], width: u32, height: u32) -> (Vec<u8>, u32) {
    let mut level = rgba
        .chunks_exact(4)
        .map(|texel| {
            [
                (f32::from(texel[0]) / 255.0).powi(2),
                (f32::from(texel[1]) / 255.0).powi(2),
                (f32::from(texel[2]) / 255.0).powi(2),
                f32::from(texel[3]) / 255.0,
            ]
        })
        .collect::<Vec<_>>();
    let mut output = Vec::with_capacity(rgba.len() * 8 / 3);
    let mut level_width = width;
    let mut level_height = height;
    let mut mip_level_count = 0;
    loop {
        for texel in &level {
            for channel in texel {
                output.extend_from_slice(&f16::from_f32(*channel).to_le_bytes());
            }
        }
        mip_level_count += 1;
        if level_width == 1 && level_height == 1 {
            break;
        }
        level = downsample_rgba_f32(&level, level_width, level_height);
        (level_width, level_height) = next_mip_extent(level_width, level_height);
    }
    (output, mip_level_count)
}

fn linear_rgba8_mips(rgba: &[u8], width: u32, height: u32) -> (Vec<u8>, u32) {
    let mut level = rgba.to_vec();
    let mut output = Vec::with_capacity(rgba.len() * 4 / 3);
    let mut level_width = width;
    let mut level_height = height;
    let mut mip_level_count = 0;
    loop {
        output.extend_from_slice(&level);
        mip_level_count += 1;
        if level_width == 1 && level_height == 1 {
            break;
        }
        let (next_width, next_height) = next_mip_extent(level_width, level_height);
        let mut target = Vec::with_capacity((next_width * next_height * 4) as usize);
        for y in 0..next_height {
            for x in 0..next_width {
                for channel in 0..4 {
                    let mut sum = 0_u32;
                    for offset_y in 0..2 {
                        for offset_x in 0..2 {
                            let source_x = (x * 2 + offset_x).min(level_width - 1);
                            let source_y = (y * 2 + offset_y).min(level_height - 1);
                            let index =
                                ((source_y * level_width + source_x) * 4) as usize + channel;
                            sum += u32::from(level[index]);
                        }
                    }
                    target.push(((sum + 2) / 4) as u8);
                }
            }
        }
        level = target;
        level_width = next_width;
        level_height = next_height;
    }
    (output, mip_level_count)
}

fn material_handle(
    material: &MaterialRecord,
    level: &UniversityLevel,
    texture_cache: &mut HashMap<TextureKey, Handle<Image>>,
    material_cache: &mut [Option<Handle<StandardMaterial>>],
    images: &mut Assets<Image>,
    materials: &mut Assets<StandardMaterial>,
) -> Result<Handle<StandardMaterial>, UniversityError> {
    let slot = material.id as usize - 1;
    if let Some(handle) = &material_cache[slot] {
        return Ok(handle.clone());
    }
    let texture = |id, decode, lightmap| {
        let (address_u, address_v) = texture_addresses(material, id, lightmap);
        TextureKey {
            id,
            decode,
            address_u,
            address_v,
            mip_zero: lightmap,
        }
    };
    let optional = |handle: Handle<Image>, id| (id != 0).then_some(handle);
    let albedo = image_handle(
        texture(
            material.albedo_texture,
            TextureDecode::EncodedSquared,
            false,
        ),
        level,
        texture_cache,
        images,
    )?;
    let normal = image_handle(
        texture(material.normal_texture, TextureDecode::LinearData, false),
        level,
        texture_cache,
        images,
    )?;
    let orm = image_handle(
        texture(material.orm_texture, TextureDecode::LinearData, false),
        level,
        texture_cache,
        images,
    )?;
    let emissive = image_handle(
        texture(
            material.emissive_texture,
            TextureDecode::EncodedSquared,
            false,
        ),
        level,
        texture_cache,
        images,
    )?;
    let alpha_mode = match material.alpha_mode {
        0 => AlphaMode::Opaque,
        1 => AlphaMode::Mask(material.alpha_cutoff),
        2 => AlphaMode::Blend,
        value => return Err(failure(format!("invalid University alpha mode {value}"))),
    };
    let intensity = material.emissive_intensity.max(0.0);
    let standard = StandardMaterial {
        base_color: Color::linear_rgb(
            material.display_color[0],
            material.display_color[1],
            material.display_color[2],
        ),
        base_color_texture: optional(albedo, material.albedo_texture),
        perceptual_roughness: material.roughness.clamp(0.0, 1.0),
        metallic_roughness_texture: optional(orm, material.orm_texture),
        normal_map_texture: optional(normal, material.normal_texture),
        emissive: LinearRgba::new(intensity, intensity, intensity, 1.0),
        emissive_texture: optional(emissive, material.emissive_texture),
        alpha_mode,
        cull_mode: if material.cull_mode == Some(1) {
            None
        } else {
            Some(Face::Back)
        },
        lightmap_exposure: 1.0,
        // Unbaked water/ocean/special-family draws remain visible without
        // substituting a guessed sun. Their exact family shader is retained
        // in the preservation manifest but unsupported by StandardMaterial.
        unlit: material.lightmap_texture == 0,
        ..default()
    };
    let handle = materials.add(standard);
    material_cache[slot] = Some(handle.clone());
    Ok(handle)
}

struct DecodedVertex {
    position: [f32; 3],
    normal: [f32; 3],
    uv0: [f32; 2],
    uv1: [f32; 2],
    tangent: [f32; 4],
    material_id: u32,
}

fn decode_vertex(bytes: &[u8]) -> Result<DecodedVertex, UniversityError> {
    let position = [f32_at(bytes, 0), f32_at(bytes, 4), f32_at(bytes, 8)];
    let normal = Vec3::new(f32_at(bytes, 12), f32_at(bytes, 16), f32_at(bytes, 20));
    let uv0 = [f32_at(bytes, 24), f32_at(bytes, 28)];
    let uv1 = [f32_at(bytes, 32), f32_at(bytes, 36)];
    let material_id = u32_at(bytes, 40);
    let binormal = Vec3::new(
        bytes[52] as i8 as f32 / 127.0,
        bytes[53] as i8 as f32 / 127.0,
        bytes[54] as i8 as f32 / 127.0,
    );
    let handedness = if bytes[55] as i8 >= 0 { 1.0 } else { -1.0 };
    let tangent = (binormal.cross(normal) * handedness)
        .try_normalize()
        .unwrap_or(Vec3::X);
    if position
        .into_iter()
        .chain(normal.to_array())
        .chain(uv0)
        .chain(uv1)
        .chain(tangent.to_array())
        .any(|value| !value.is_finite())
    {
        return Err(failure(
            "University visual vertex contains a NaN or infinity",
        ));
    }
    Ok(DecodedVertex {
        position,
        normal: normal.to_array(),
        uv0,
        uv1,
        tangent: [tangent.x, tangent.y, tangent.z, handedness],
        material_id,
    })
}

fn for_each_visual_group(
    bytes: &[u8],
    mut callback: impl FnMut(u32, Vec<DecodedVertex>, Vec<u32>) -> Result<(), UniversityError>,
) -> Result<(usize, usize, usize), UniversityError> {
    let mut reader = ByteReader::new(bytes);
    if reader.take(8)? != b"UNIVVIS1" {
        return Err(failure("University visual group cache has invalid magic"));
    }
    let group_count = reader.u32()? as usize;
    if reader.u32()? != 56 {
        return Err(failure("University visual group cache has invalid stride"));
    }
    let mut vertices = 0;
    let mut indices = 0;
    for _ in 0..group_count {
        let material_id = reader.u32()?;
        let vertex_count = reader.u32()? as usize;
        let index_count = reader.u32()? as usize;
        let records = reader.take(vertex_count * 56)?;
        let mut decoded = Vec::with_capacity(vertex_count);
        for record in records.chunks_exact(56) {
            let vertex = decode_vertex(record)?;
            if vertex.material_id != material_id {
                return Err(failure("University draw group crosses material IDs"));
            }
            decoded.push(vertex);
        }
        let index_bytes = reader.take(index_count * 4)?;
        let local_indices = index_bytes
            .chunks_exact(4)
            .map(|value| u32::from_le_bytes(value.try_into().unwrap()))
            .collect::<Vec<_>>();
        if local_indices
            .iter()
            .any(|index| *index as usize >= vertex_count)
        {
            return Err(failure("University draw group index is out of range"));
        }
        vertices += vertex_count;
        indices += index_count;
        callback(material_id, decoded, local_indices)?;
    }
    if reader.offset != bytes.len() {
        return Err(failure("University visual group cache has trailing bytes"));
    }
    Ok((group_count, vertices, indices))
}

fn retail_sky_mesh(bytes: &[u8]) -> Result<Mesh, UniversityError> {
    let mut reader = ByteReader::new(bytes);
    if reader.take(8)? != b"UNIVSKY1" {
        return Err(failure("retail sky mesh cache has an invalid magic"));
    }
    let vertex_count = reader.u32()? as usize;
    let index_count = reader.u32()? as usize;
    if vertex_count != EXPECTED_SKY_VERTICES || index_count != EXPECTED_SKY_INDICES {
        return Err(failure(format!(
            "retail sky inventory is {vertex_count} vertices/{index_count} indices"
        )));
    }
    let mut positions = Vec::with_capacity(vertex_count);
    let mut normals = Vec::with_capacity(vertex_count);
    let mut uvs = Vec::with_capacity(vertex_count);
    for _ in 0..vertex_count {
        let vertex = reader.take(32)?;
        let position = [f32_at(vertex, 0), f32_at(vertex, 4), f32_at(vertex, 8)];
        let normal = [f32_at(vertex, 12), f32_at(vertex, 16), f32_at(vertex, 20)];
        let uv = [f32_at(vertex, 24), f32_at(vertex, 28)];
        if position
            .into_iter()
            .chain(normal)
            .chain(uv)
            .any(|value| !value.is_finite())
        {
            return Err(failure("retail sky mesh contains non-finite values"));
        }
        positions.push(position);
        normals.push(normal);
        uvs.push(uv);
    }
    let indices = reader
        .take(index_count * 4)?
        .chunks_exact(4)
        .map(|bytes| u32::from_le_bytes(bytes.try_into().unwrap()))
        .collect::<Vec<_>>();
    if reader.offset != bytes.len() || indices.iter().any(|index| *index as usize >= vertex_count) {
        return Err(failure(
            "retail sky mesh has invalid indices or trailing bytes",
        ));
    }
    Ok(
        Mesh::new(PrimitiveTopology::TriangleList, RenderAssetUsages::all())
            .with_inserted_attribute(Mesh::ATTRIBUTE_POSITION, positions)
            .with_inserted_attribute(Mesh::ATTRIBUTE_NORMAL, normals)
            .with_inserted_attribute(Mesh::ATTRIBUTE_UV_0, uvs)
            .with_inserted_indices(bevy::mesh::Indices::U32(indices)),
    )
}

fn retail_sky_image(level: &UniversityLevel) -> Result<Image, UniversityError> {
    let compressed = fs::read(cache_file(
        &level.cache_root,
        &level.manifest,
        "retail_sky_panorama",
    )?)?;
    let mut rgba = Vec::with_capacity(level.manifest.retail_skybox.panorama_decoded_bytes);
    ZlibDecoder::new(Cursor::new(compressed)).read_to_end(&mut rgba)?;
    let skybox = &level.manifest.retail_skybox;
    if rgba.len() != skybox.panorama_decoded_bytes
        || format!("{:x}", Sha256::digest(&rgba)) != skybox.panorama_decoded_sha256
    {
        return Err(failure("retail sky panorama did not decode byte-exactly"));
    }
    let (data, mip_level_count) =
        encoded_squared_half_rgba_mips(&rgba, skybox.panorama_width, skybox.panorama_height);
    let mut image = Image::new_uninit(
        Extent3d {
            width: skybox.panorama_width,
            height: skybox.panorama_height,
            depth_or_array_layers: 1,
        },
        TextureDimension::D2,
        TextureFormat::Rgba16Float,
        RenderAssetUsages::all(),
    );
    image.data = Some(data);
    image.texture_descriptor.mip_level_count = mip_level_count;
    image.sampler = ImageSampler::Descriptor(ImageSamplerDescriptor {
        address_mode_u: ImageAddressMode::Repeat,
        address_mode_v: ImageAddressMode::ClampToEdge,
        address_mode_w: ImageAddressMode::ClampToEdge,
        mag_filter: ImageFilterMode::Linear,
        min_filter: ImageFilterMode::Linear,
        mipmap_filter: ImageFilterMode::Linear,
        lod_min_clamp: 0.0,
        lod_max_clamp: (mip_level_count - 1) as f32,
        anisotropy_clamp: 8,
        ..default()
    });
    Ok(image)
}

#[derive(Component)]
pub struct UniversitySky;

pub fn follow_university_sky(
    camera: Query<&Transform, (With<Camera3d>, Without<UniversitySky>)>,
    mut sky: Query<&mut Transform, With<UniversitySky>>,
) {
    let Ok(camera) = camera.single() else {
        return;
    };
    for mut transform in &mut sky {
        transform.translation.x = camera.translation.x;
        transform.translation.z = camera.translation.z;
    }
}

pub fn spawn_university_world(
    mut commands: Commands,
    level: Res<UniversityLevel>,
    mut meshes: ResMut<Assets<Mesh>>,
    mut materials: ResMut<Assets<StandardMaterial>>,
    mut images: ResMut<Assets<Image>>,
) {
    let result = (|| -> Result<(), UniversityError> {
        let bytes = fs::read(cache_file(
            &level.cache_root,
            &level.manifest,
            "visual_groups",
        )?)?;
        let mut texture_cache = HashMap::new();
        let mut material_cache = vec![None; level.manifest.materials.len()];
        let mut lightmapped_draws = 0;
        let (groups, _, indices) =
            for_each_visual_group(&bytes, |material_id, vertices, indices| {
                let material = level
                    .manifest
                    .materials
                    .get(material_id as usize - 1)
                    .filter(|material| material.id == material_id)
                    .ok_or_else(|| {
                        failure(format!("University material {material_id} is absent"))
                    })?;
                let material_handle = material_handle(
                    material,
                    &level,
                    &mut texture_cache,
                    &mut material_cache,
                    &mut images,
                    &mut materials,
                )?;
                let mut positions = Vec::with_capacity(vertices.len());
                let mut normals = Vec::with_capacity(vertices.len());
                let mut uv0 = Vec::with_capacity(vertices.len());
                let mut uv1 = Vec::with_capacity(vertices.len());
                let mut tangents = Vec::with_capacity(vertices.len());
                for vertex in vertices {
                    positions.push(vertex.position);
                    normals.push(vertex.normal);
                    uv0.push(vertex.uv0);
                    uv1.push(vertex.uv1);
                    tangents.push(vertex.tangent);
                }
                let mesh = Mesh::new(PrimitiveTopology::TriangleList, RenderAssetUsages::all())
                    .with_inserted_attribute(Mesh::ATTRIBUTE_POSITION, positions)
                    .with_inserted_attribute(Mesh::ATTRIBUTE_NORMAL, normals)
                    .with_inserted_attribute(Mesh::ATTRIBUTE_UV_0, uv0)
                    .with_inserted_attribute(Mesh::ATTRIBUTE_UV_1, uv1)
                    .with_inserted_attribute(Mesh::ATTRIBUTE_TANGENT, tangents)
                    .with_inserted_indices(bevy::mesh::Indices::U32(indices));
                let mut entity = commands.spawn((
                    Name::new(format!(
                        "University draw {:04} {}",
                        material_id, material.name
                    )),
                    Mesh3d(meshes.add(mesh)),
                    MeshMaterial3d(material_handle),
                ));
                if material.lightmap_texture != 0 {
                    let (address_u, address_v) =
                        texture_addresses(material, material.lightmap_texture, true);
                    let lightmap = image_handle(
                        TextureKey {
                            id: material.lightmap_texture,
                            decode: TextureDecode::EncodedSquared,
                            address_u,
                            address_v,
                            mip_zero: true,
                        },
                        &level,
                        &mut texture_cache,
                        &mut images,
                    )?;
                    entity.insert(Lightmap {
                        image: lightmap,
                        bicubic_sampling: false,
                        ..default()
                    });
                    lightmapped_draws += 1;
                }
                Ok(())
            })?;
        if groups != level.manifest.draw_group_count
            || indices != EXPECTED_INDICES
            || lightmapped_draws != EXPECTED_LIGHTMAPPED_DRAWS
        {
            return Err(failure(format!(
                "University render inventory mismatch: {groups} groups, \
                 {indices} indices, {lightmapped_draws} lightmapped draws"
            )));
        }
        let sky_mesh = retail_sky_mesh(&fs::read(cache_file(
            &level.cache_root,
            &level.manifest,
            "retail_sky_mesh",
        )?)?)?;
        let sky_texture = images.add(retail_sky_image(&level)?);
        let sky_material = materials.add(StandardMaterial {
            base_color_texture: Some(sky_texture),
            unlit: true,
            // The retail dome's authored winding and normals face inward.
            // Back-face culling therefore preserves the surface seen from
            // inside the dome.
            cull_mode: Some(Face::Back),
            fog_enabled: false,
            ..default()
        });
        commands.spawn((
            Name::new(format!(
                "Retail Skate 3 skybox {}",
                level.manifest.retail_skybox.mesh_name
            )),
            UniversitySky,
            Mesh3d(meshes.add(sky_mesh)),
            MeshMaterial3d(sky_material),
            Transform::from_translation(Vec3::new(
                level.manifest.spawn.position[0],
                RETAIL_SKY_HEIGHT,
                level.manifest.spawn.position[2],
            ))
            .with_scale(Vec3::splat(RETAIL_SKY_SCALE)),
        ));
        info!(
            "University loaded: {} draw groups, {} textures resident, {} rails, retail sky",
            groups,
            texture_cache.len(),
            level.grind_rails.rails.len()
        );
        Ok(())
    })();
    if let Err(error) = result {
        error!("University render load failed: {error}");
        panic!("University render load failed: {error}");
    }
}

pub fn verify_headless() -> Result<(), UniversityError> {
    let load = UniversityLoad::load_and_validate()?;
    let visual = fs::read(cache_file(
        &load.level.cache_root,
        &load.level.manifest,
        "visual_groups",
    )?)?;
    let mut lightmapped_draws = 0;
    let mut lightmap_uv_out_of_bounds = 0;
    let (groups, vertices, indices) =
        for_each_visual_group(&visual, |material_id, vertices, _| {
            let material = &load.level.manifest.materials[material_id as usize - 1];
            if material.lightmap_texture != 0 {
                lightmapped_draws += 1;
                lightmap_uv_out_of_bounds += vertices
                    .iter()
                    .filter(|vertex| {
                        !(0.0..=1.0).contains(&vertex.uv1[0])
                            || !(0.0..=1.0).contains(&vertex.uv1[1])
                    })
                    .count();
            }
            Ok(())
        })?;
    if groups != load.level.manifest.draw_group_count
        || vertices != EXPECTED_VERTICES
        || indices != EXPECTED_INDICES
        || lightmapped_draws != EXPECTED_LIGHTMAPPED_DRAWS
        || lightmap_uv_out_of_bounds != 0
    {
        return Err(failure(format!(
            "University visual validation mismatch: {groups} groups, {vertices} \
             vertices, {indices} indices, {lightmapped_draws} lightmapped draws, \
             {lightmap_uv_out_of_bounds} invalid lightmap UVs"
        )));
    }
    let sky_mesh = retail_sky_mesh(&fs::read(cache_file(
        &load.level.cache_root,
        &load.level.manifest,
        "retail_sky_mesh",
    )?)?)?;
    let sky_image = retail_sky_image(&load.level)?;
    if sky_mesh.count_vertices() != EXPECTED_SKY_VERTICES
        || sky_mesh.indices().map(|indices| indices.len()) != Some(EXPECTED_SKY_INDICES)
        || sky_image.texture_descriptor.size.width != EXPECTED_SKY_PANORAMA_WIDTH
        || sky_image.texture_descriptor.size.height != EXPECTED_SKY_PANORAMA_HEIGHT
        || sky_image.texture_descriptor.mip_level_count != 12
    {
        return Err(failure("University retail sky runtime adapter is stale"));
    }
    println!(
        "University headless verification passed\n\
         package: {}\n\
         spawn: {:?}, heading {}\n\
         visual: {} groups / {} triangles\n\
         collision: {} triangles / 183 surfaces\n\
         grinds: {} rails / {} native segments\n\
         sky: {} vertices / {} triangles / {}x{} panorama / {} mips\n\
         provenance: {}\n\
         preserved fields: {}\n\
         derived fields: {}\n\
         unresolved/unsupported fields: {}",
        load.level.manifest.source_package.sha256,
        load.level.manifest.spawn.position,
        load.level.manifest.spawn.heading_radians,
        groups,
        indices / 3,
        EXPECTED_COLLISION_TRIANGLES,
        EXPECTED_RAILS,
        EXPECTED_SEGMENTS,
        EXPECTED_SKY_VERTICES,
        EXPECTED_SKY_INDICES / 3,
        EXPECTED_SKY_PANORAMA_WIDTH,
        EXPECTED_SKY_PANORAMA_HEIGHT,
        sky_image.texture_descriptor.mip_level_count,
        load.level.manifest.spawn.provenance,
        load.level.manifest.preserved.join(", "),
        load.level.manifest.derived.join(", "),
        load.level.manifest.unsupported.join(", "),
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn packed_binormal_reconstructs_tangent_and_handedness() {
        let mut bytes = [0_u8; 56];
        bytes[12..16].copy_from_slice(&0.0_f32.to_le_bytes());
        bytes[16..20].copy_from_slice(&1.0_f32.to_le_bytes());
        bytes[20..24].copy_from_slice(&0.0_f32.to_le_bytes());
        bytes[40..44].copy_from_slice(&7_u32.to_le_bytes());
        bytes[52] = 0;
        bytes[53] = 0;
        bytes[54] = 127;
        bytes[55] = (-127_i8) as u8;
        let vertex = decode_vertex(&bytes).unwrap();
        assert_eq!(vertex.material_id, 7);
        assert_eq!(vertex.tangent, [1.0, 0.0, 0.0, -1.0]);
    }

    #[test]
    fn retail_cubic_uses_d_plus_c_t_plus_b_t2_plus_a_t3() {
        let mut words = [0_u32; 30];
        for (offset, value) in [(0, 1.0_f32), (4, 2.0), (8, 3.0), (12, 4.0)] {
            words[offset] = value.to_bits();
        }
        let segment = RetailSplineSegment { words };
        assert_eq!(segment.position(2.0), Vec3::new(26.0, 0.0, 0.0));
    }

    #[test]
    fn color_and_lightmap_decode_square_rgb_but_not_alpha() {
        let decoded = encoded_squared_half_rgba(&[0, 128, 255, 64]);
        let channel = |index: usize| {
            f16::from_le_bytes(decoded[index * 2..index * 2 + 2].try_into().unwrap()).to_f32()
        };
        assert_eq!(channel(0), 0.0);
        assert!((channel(1) - (128.0_f32 / 255.0).powi(2)).abs() < 0.0003);
        assert_eq!(channel(2), 1.0);
        assert!((channel(3) - 64.0 / 255.0).abs() < 0.0003);
    }

    #[test]
    fn ordinary_color_mips_are_linear_and_complete() {
        let source = [0, 0, 0, 0, 255, 0, 0, 64, 0, 255, 0, 128, 0, 0, 255, 255];
        let (encoded, encoded_levels) = encoded_squared_half_rgba_mips(&source, 2, 2);
        assert_eq!(encoded_levels, 2);
        assert_eq!(encoded.len(), 40);
        let final_texel = encoded[32..]
            .chunks_exact(2)
            .map(|bytes| f16::from_le_bytes([bytes[0], bytes[1]]).to_f32())
            .collect::<Vec<_>>();
        assert!((final_texel[0] - 0.25).abs() < 0.001);
        assert!((final_texel[1] - 0.25).abs() < 0.001);
        assert!((final_texel[2] - 0.25).abs() < 0.001);
        assert!((final_texel[3] - 447.0 / (4.0 * 255.0)).abs() < 0.001);

        let (linear, linear_levels) = linear_rgba8_mips(&source, 2, 2);
        assert_eq!(linear_levels, 2);
        assert_eq!(linear.len(), 20);
        assert_eq!(&linear[16..], &[64, 64, 64, 112]);
    }

    #[test]
    fn requested_university_ambient_is_a_low_energy_fill() {
        assert!(UNIVERSITY_AMBIENT_BRIGHTNESS > 0.0);
        assert!(UNIVERSITY_AMBIENT_BRIGHTNESS <= 0.25);
    }

    #[test]
    fn retail_lightmap_view_ev100_has_unit_exposure() {
        let exposure = Exposure {
            ev100: RETAIL_LIGHTMAP_VIEW_EV100,
        }
        .exposure();
        assert!((exposure - 1.0).abs() < 0.000_001);
        assert!(Exposure::default().exposure() < 0.002);
    }

    #[test]
    fn university_is_the_default_level_and_flat_remains_explicitly_selectable() {
        assert_eq!(ActiveLevel::default(), ActiveLevel::University);
        assert_eq!(
            ActiveLevel::selected_from(std::iter::empty(), None),
            ActiveLevel::University
        );
        assert_eq!(
            ActiveLevel::selected_from(["--level=flat"], Some("university")),
            ActiveLevel::FlatParityFixture
        );
        assert_eq!(
            ActiveLevel::selected_from(std::iter::empty(), Some("parity")),
            ActiveLevel::FlatParityFixture
        );
    }
}
