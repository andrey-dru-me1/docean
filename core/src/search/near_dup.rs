//! Near-duplicate detection via MinHash + Locality-Sensitive Hashing (LSH).
//!
//! The search layer owns a shared index of per-document MinHash signatures so
//! that two *substantially the same* documents (minor edits) can be recognized
//! as related versions — not as unrelated files. This is the index the
//! [`crate::sync`] reconciliation layer consults to propose related versions
//! when content arrives under a different document id but almost-identical
//! bytes.
//!
//! # How it works
//!
//! 1. **Shingling** — a document (raw bytes lossily decoded to UTF-8 and
//!    normalized) is split into overlapping `k`-grams ("shingles").
//! 2. **MinHash** — `n` independent hash functions (seeded FNV-1a) are applied
//!    to every shingle; the minimum value of each becomes one row of the
//!    signature, so a signature is a compact `n`-row sketch of the shingle set.
//! 3. **LSH banding** — the signature is split into `num_bands` bands of `r`
//!    rows each; each band is hashed into a bucket. Two documents that share a
//!    bucket in *any* band are candidate near-duplicates.
//! 4. **Confirmation** — candidates are ranked by the Jaccard similarity
//!    estimated from the full signature and filtered by `threshold`.
//!
//! No external crates are required: the hashing is deterministic across runs.

use std::collections::{HashMap, HashSet};
use std::hash::{BuildHasherDefault, Hasher};

/// A fast, deterministic 64-bit hasher (splitmix64). Used for shingle hashing
/// and band bucketing, so results are reproducible.
#[derive(Default, Clone)]
pub struct Fx64(u64);

impl Hasher for Fx64 {
    fn finish(&self) -> u64 {
        self.0
    }

    fn write(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.write_u8(b);
        }
    }

    fn write_u8(&mut self, n: u8) {
        self.0 = splitmix64(self.0 ^ (n as u64));
    }

    fn write_u64(&mut self, n: u64) {
        self.0 = splitmix64(self.0 ^ n);
    }
}

#[inline]
fn splitmix64(mut z: u64) -> u64 {
    z = z.wrapping_add(0x9e37_79b9_7f4a_7c15);
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    z ^ (z >> 31)
}

type FastMap = BuildHasherDefault<Fx64>;

/// Split `text` into the set of unique lowercase `k`-grams (shingles). The text
/// is expected to already be normalized by the caller if desired; here we only
/// lowercase ASCII for stability across minor case edits.
pub fn shingles(text: &str, k: usize) -> Vec<String> {
    let flat: Vec<char> = text
        .chars()
        .filter(|c| !c.is_whitespace())
        .flat_map(|c| c.to_lowercase())
        .collect();
    if flat.len() < k || k == 0 {
        // Too short to shingle: fall back to a single whole-text shingle so the
        // document still gets a stable (if trivial) signature.
        return vec![flat.iter().collect()];
    }
    let mut seen = HashSet::with_hasher(FastMap::default());
    let mut out = Vec::new();
    for window in flat.windows(k) {
        let s: String = window.iter().collect();
        if seen.insert(s.clone()) {
            out.push(s);
        }
    }
    out
}

/// Compute a MinHash signature (an `n`-row sketch) of a shingle set.
///
/// Each row is an independent, seeded hash function applied to every shingle;
/// the row value is the minimum over the set.
pub fn minhash_signature(shingles: &[String], n: usize) -> Vec<u64> {
    // Pre-hash each shingle once to a 64-bit value for speed.
    let hashed: Vec<u64> = shingles
        .iter()
        .map(|s| {
            let mut h = Fx64::default();
            h.write(s.as_bytes());
            h.finish().max(1) // avoid a zero (indistinguishable from empty)
        })
        .collect();

    let mut sig = vec![u64::MAX; n];
    for (row, slot) in sig.iter_mut().enumerate() {
        let mut min = u64::MAX;
        for &hv in &hashed {
            let mixed = splitmix64(hv ^ ((row as u64).wrapping_mul(0x9e37_79b9_7f4a_7c15)));
            if mixed < min {
                min = mixed;
            }
        }
        *slot = min;
    }
    sig
}

/// Estimated Jaccard similarity between two signatures: the fraction of rows
/// that agree. An unbiased estimator of the true Jaccard index of the
/// underlying shingle sets.
pub fn signature_similarity(a: &[u64], b: &[u64]) -> f32 {
    if a.len() != b.len() || a.is_empty() {
        return 0.0;
    }
    let agree = a.iter().zip(b.iter()).filter(|(x, y)| x == y).count();
    agree as f32 / a.len() as f32
}

/// Hash a band (a contiguous slice of signature rows) into a bucket key.
fn band_key(rows: &[u64]) -> u64 {
    let mut h = Fx64::default();
    for r in rows {
        h.write(&r.to_le_bytes());
    }
    h.finish()
}

/// A compact per-document sketch plus the LSH band-bucket membership used to
/// find candidate near-duplicates in sub-linear time.
#[derive(Debug, Clone)]
pub struct MinHashSignature {
    pub hashes: Vec<u64>,
}

/// A near-duplicate relationship to another document, with an estimated
/// similarity score in `[0, 1]`.
#[derive(Debug, Clone, PartialEq)]
pub struct NearDuplicateMatch {
    pub document_id: String,
    /// Estimated Jaccard similarity of the two documents' shingle sets.
    pub similarity: f32,
}

/// A shared, MinHash + LSH backed index of document similarity.
///
/// Owned by the search layer; handed (as an `Arc<Mutex<_>>`) to the sync layer
/// so reconciliation can recognize substantially-same documents as related
/// versions.
#[derive(Debug, Clone)]
pub struct NearDuplicateIndex {
    /// Number of MinHash rows (independent hash functions).
    num_hashes: usize,
    /// Number of LSH bands.
    num_bands: usize,
    /// document id -> signature.
    signatures: HashMap<String, MinHashSignature, FastMap>,
    /// band index -> bucket key -> document ids in that bucket.
    bands: Vec<HashMap<u64, Vec<String>, FastMap>>,
}

impl NearDuplicateIndex {
    /// Build an index with `num_hashes` MinHash rows partitioned into
    /// `num_bands` bands. `num_hashes` must be divisible by `num_bands`.
    pub fn new(num_hashes: usize, num_bands: usize) -> Self {
        assert!(num_hashes > 0 && num_bands > 0, "invalid MinHash shape");
        assert_eq!(
            num_hashes % num_bands,
            0,
            "num_hashes must be divisible by num_bands"
        );
        Self {
            num_hashes,
            num_bands,
            signatures: HashMap::with_hasher(FastMap::default()),
            bands: (0..num_bands)
                .map(|_| HashMap::with_hasher(FastMap::default()))
                .collect(),
        }
    }

    /// The default shape used by the sync layer (128 rows / 32 bands of 4),
    /// tuned for high recall on minor edits: a near-duplicate pair at ~0.68
    /// Jaccard collides in at least one band with probability near 1.
    pub fn default_index() -> Self {
        Self::new(128, 32)
    }

    /// Hash a signature's rows into band-bucket keys.
    fn band_keys(&self, hashes: &[u64]) -> Vec<u64> {
        let rows_per_band = self.num_hashes / self.num_bands;
        (0..self.num_bands)
            .map(|b| band_key(&hashes[b * rows_per_band..(b + 1) * rows_per_band]))
            .collect()
    }

    /// Index (or re-index) a document's text under `id`.
    pub fn index(&mut self, id: &str, text: &str) {
        let sig = minhash_signature(&shingles(text, 5), self.num_hashes);
        self.remove_from_bands(id);

        for (band, key) in self.band_keys(&sig).into_iter().enumerate() {
            self.bands[band].entry(key).or_default().push(id.to_owned());
        }
        self.signatures
            .insert(id.to_owned(), MinHashSignature { hashes: sig });
    }

    fn remove_from_bands(&mut self, id: &str) {
        for band in &mut self.bands {
            for bucket in band.values_mut() {
                bucket.retain(|d| d != id);
            }
        }
    }

    /// Drop a document from the index.
    pub fn remove(&mut self, id: &str) {
        self.remove_from_bands(id);
        self.signatures.remove(id);
    }

    /// Number of indexed documents.
    pub fn len(&self) -> usize {
        self.signatures.len()
    }

    pub fn is_empty(&self) -> bool {
        self.signatures.is_empty()
    }

    /// Find indexed documents whose content is near-duplicate of `text`, i.e.
    /// with estimated Jaccard similarity `>= threshold`. LSH generates
    /// candidates; similarity confirms and ranks them.
    pub fn query(&self, text: &str, threshold: f32) -> Vec<NearDuplicateMatch> {
        let sig = minhash_signature(&shingles(text, 5), self.num_hashes);
        self.query_signature(&sig, threshold)
    }

    /// Query by a precomputed signature.
    fn query_signature(&self, sig: &[u64], threshold: f32) -> Vec<NearDuplicateMatch> {
        let mut candidates: HashSet<String, FastMap> = HashSet::with_hasher(FastMap::default());
        for (band, key) in self.band_keys(sig).into_iter().enumerate() {
            if let Some(bucket) = self.bands[band].get(&key) {
                for id in bucket {
                    candidates.insert(id.clone());
                }
            }
        }

        let mut matches: Vec<NearDuplicateMatch> = candidates
            .into_iter()
            .filter_map(|id| {
                let other = self.signatures.get(&id)?;
                let sim = signature_similarity(sig, &other.hashes);
                (sim >= threshold).then_some(NearDuplicateMatch {
                    document_id: id,
                    similarity: sim,
                })
            })
            .collect();
        matches.sort_by(|a, b| {
            b.similarity
                .partial_cmp(&a.similarity)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        matches
    }

    /// Direct signature access for testing/inspection.
    pub fn signature(&self, id: &str) -> Option<&MinHashSignature> {
        self.signatures.get(id)
    }
}

impl Default for NearDuplicateIndex {
    fn default() -> Self {
        Self::default_index()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn docs() -> (&'static str, &'static str, &'static str) {
        let a = "The quick brown fox jumps over the lazy dog.";
        let b = "The quick brown fox jumps over the lazy dog and then runs away.";
        let c = "Completely unrelated text about quantum chromodynamics and lattice gauge theory.";
        (a, b, c)
    }

    #[test]
    fn identical_text_has_similarity_one() {
        let (a, _, _) = docs();
        let sig_a = minhash_signature(&shingles(a, 5), 128);
        let sig_a2 = minhash_signature(&shingles(a, 5), 128);
        assert!((signature_similarity(&sig_a, &sig_a2) - 1.0).abs() < 1e-6);
    }

    #[test]
    fn minor_edits_are_more_similar_than_unrelated() {
        let (a, b, c) = docs();
        let sig_a = minhash_signature(&shingles(a, 5), 128);
        let sim_ab = signature_similarity(&sig_a, &minhash_signature(&shingles(b, 5), 128));
        let sim_ac = signature_similarity(&sig_a, &minhash_signature(&shingles(c, 5), 128));
        assert!(
            sim_ab > sim_ac,
            "minor edit ({sim_ab}) should beat unrelated ({sim_ac})"
        );
        assert!(
            sim_ab > 0.5,
            "minor edit similarity should be high: {sim_ab}"
        );
    }

    #[test]
    fn index_finds_near_duplicate_and_omits_unrelated() {
        let (a, b, c) = docs();
        let mut idx = NearDuplicateIndex::default();
        idx.index("doc-original", a);
        idx.index("doc-unrelated", c);

        let matches = idx.query(b, 0.5);
        assert!(
            matches.iter().any(|m| m.document_id == "doc-original"),
            "should match the near-duplicate: {matches:?}"
        );
        assert!(
            !matches.iter().any(|m| m.document_id == "doc-unrelated"),
            "should not match unrelated: {matches:?}"
        );
    }

    #[test]
    fn reindex_and_remove_update_membership() {
        let (a, _, c) = docs();
        let mut idx = NearDuplicateIndex::default();
        idx.index("d", a);
        assert_eq!(idx.len(), 1);
        idx.index("d", c);
        assert!(!idx.query(a, 0.5).iter().any(|m| m.document_id == "d"));
        idx.remove("d");
        assert!(idx.is_empty());
    }
}
