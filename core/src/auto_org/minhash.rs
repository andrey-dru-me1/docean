//! MinHash + LSH de-duplication.
//!
//! Detects near-duplicate documents to avoid storing redundant copies. MinHash
//! estimates Jaccard similarity between shingle sets; banding buckets documents
//! by band signature (LSH) so candidates can be found without an O(n) scan.
//!
//! Hand-rolled and fully deterministic: hashing uses FNV-1a with a fixed basis,
//! so signatures are identical across runs (and testable against fixtures).

use std::collections::{BTreeSet, HashMap};

/// Number of hash permutations in a MinHash signature.
pub const NUM_PERM: usize = 64;
/// Number of rows per band (and thus number of bands) for LSH.
pub const BAND_ROWS: usize = 8;
/// Number of bands = NUM_PERM / BAND_ROWS.
pub const NUM_BANDS: usize = NUM_PERM / BAND_ROWS;

const FNV_BASIS: u64 = 0xcbf2_9ce4_8422_2325;
const FNV_PRIME: u64 = 0x0000_0100_0000_01B3;

fn fnv1a(bytes: &[u8], seed: u64) -> u64 {
    let mut hash = FNV_BASIS ^ seed;
    for &b in bytes {
        hash ^= b as u64;
        hash = hash.wrapping_mul(FNV_PRIME);
    }
    hash
}

/// A MinHash signature: `NUM_PERM` hash values (min-hashes) of a document.
pub type Signature = [u64; NUM_PERM];

fn shingles(text: &str, k: usize) -> Vec<u64> {
    let chars: Vec<char> = text.chars().collect();
    if chars.len() < k {
        return vec![fnv1a(text.to_lowercase().as_bytes(), 0)];
    }
    (0..=chars.len() - k)
        .map(|i| {
            let s: String = chars[i..i + k].iter().collect();
            fnv1a(s.to_lowercase().as_bytes(), 0)
        })
        .collect()
}

/// Compute a document's MinHash signature from its text.
pub fn signature(text: &str, k: usize) -> Signature {
    let shingles = shingles(text, k);
    let mut sig = [u64::MAX; NUM_PERM];
    for s in shingles {
        for (i, slot) in sig.iter_mut().enumerate() {
            let h = fnv1a(&s.to_le_bytes(), (i as u64).wrapping_add(1));
            if h < *slot {
                *slot = h;
            }
        }
    }
    sig
}

/// Estimated Jaccard similarity between two signatures.
pub fn jaccard(a: &Signature, b: &Signature) -> f64 {
    let matches = a.iter().zip(b.iter()).filter(|(x, y)| x == y).count();
    matches as f64 / NUM_PERM as f64
}

/// Band a signature into `NUM_BANDS` band keys (a deterministic hash of each
/// band's rows). Documents sharing a band key are LSH candidates.
pub fn band_keys(sig: &Signature) -> [u64; NUM_BANDS] {
    let mut keys = [0u64; NUM_BANDS];
    for (band, key) in keys.iter_mut().enumerate() {
        let start = band * BAND_ROWS;
        let mut buf = Vec::with_capacity(BAND_ROWS * 8);
        for row in &sig[start..start + BAND_ROWS] {
            buf.extend_from_slice(&row.to_le_bytes());
        }
        *key = fnv1a(&buf, (band as u64).wrapping_add(1));
    }
    keys
}

/// An LSH index mapping band key → list of document ids in that bucket.
pub struct LshIndex {
    bands: HashMap<u64, Vec<String>>,
}

impl LshIndex {
    /// Build an index from `(id, signature)` pairs.
    pub fn build<'a, I>(items: I) -> Self
    where
        I: IntoIterator<Item = (&'a str, &'a Signature)>,
    {
        let mut bands: HashMap<u64, Vec<String>> = HashMap::new();
        for (id, sig) in items {
            for key in band_keys(sig) {
                bands.entry(key).or_default().push(id.to_owned());
            }
        }
        Self { bands }
    }

    /// Candidate document ids that share at least one band with `sig`.
    pub fn candidates(&self, sig: &Signature) -> Vec<String> {
        let mut ids = BTreeSet::new();
        for key in band_keys(sig) {
            if let Some(bucket) = self.bands.get(&key) {
                for id in bucket {
                    ids.insert(id.clone());
                }
            }
        }
        ids.into_iter().collect()
    }
}

/// Find whether `text` is a near-duplicate of any existing document, given a
/// Jaccard threshold. Returns the best-matching id + score.
pub fn find_duplicate(
    text: &str,
    k: usize,
    threshold: f64,
    index: &LshIndex,
    signatures: &HashMap<String, Signature>,
) -> Option<(String, f64)> {
    let sig = signature(text, k);
    let mut best: Option<(String, f64)> = None;
    for id in index.candidates(&sig) {
        if let Some(other) = signatures.get(&id) {
            let sim = jaccard(&sig, other);
            if sim >= threshold {
                match &best {
                    Some((_, best_sim)) if *best_sim >= sim => {}
                    _ => best = Some((id, sim)),
                }
            }
        }
    }
    best
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signature_is_deterministic() {
        let a = signature("invoice for office supplies", 3);
        let b = signature("invoice for office supplies", 3);
        assert_eq!(a, b);
    }

    #[test]
    fn jaccard_high_for_duplicates_low_for_distinct() {
        let a = signature("the quick brown fox jumps over the lazy dog", 3);
        let b = signature("the quick brown fox jumps over the lazy dog", 3);
        let c = signature("invoice payable to acme corporation", 3);
        assert!((jaccard(&a, &b) - 1.0).abs() < 1e-9);
        assert!(jaccard(&a, &c) < 0.5);
    }

    #[test]
    fn lsh_finds_duplicate_among_distinct_docs() {
        let mut signatures = HashMap::new();
        signatures.insert(
            "d1".to_owned(),
            signature("recipe for chocolate cake with frosting", 3),
        );
        signatures.insert(
            "d2".to_owned(),
            signature("quarterly financial report 2026", 3),
        );

        let sigs: Vec<(&str, &Signature)> = signatures
            .iter()
            .map(|(id, sig)| (id.as_str(), sig))
            .collect();
        let index = LshIndex::build(sigs);

        // An exact duplicate of d2 (same text) must be found above any threshold.
        let found = find_duplicate(
            "quarterly financial report 2026",
            3,
            0.5,
            &index,
            &signatures,
        );
        assert_eq!(found.unwrap().0, "d2");
    }

    #[test]
    fn no_duplicate_returns_none_when_below_threshold() {
        let mut signatures = HashMap::new();
        signatures.insert("d1".to_owned(), signature("completely unrelated topic", 3));
        let sigs: Vec<(&str, &Signature)> = signatures
            .iter()
            .map(|(id, sig)| (id.as_str(), sig))
            .collect();
        let index = LshIndex::build(sigs);

        assert!(find_duplicate(
            "a very different subject matter entirely",
            3,
            0.5,
            &index,
            &signatures
        )
        .is_none());
    }
}
