//! Deterministic k-means clustering over TF-IDF vectors.
//!
//! Surfaces emergent topic/tag groups from the corpus. Hand-rolled in place of
//! `linfa`/`linfa-clustering` (rationale in README): linfa's k-means/GMM use
//! randomized initialization (breaks determinism), and GMM needs native BLAS
//! (breaks the self-contained, no-C/FFI build goal).

use std::collections::HashMap;

/// A flattened, dense feature vector aligned to a fixed vocabulary order.
pub type Dense = Vec<f64>;

/// Map a sparse (term &rarr; weight) TF-IDF vector into a dense vector over the
/// canonical vocabulary order.
pub fn vectorize_dense(sparse: &HashMap<String, f64>, vocab: &[String]) -> Dense {
    vocab
        .iter()
        .map(|term| sparse.get(term).copied().unwrap_or(0.0))
        .collect()
}

/// Clustering result: document assignments, centroids, and members.
#[derive(Debug, Clone)]
pub struct Clusters {
    /// `assignments[i]` = cluster index of the i-th document.
    pub assignments: Vec<usize>,
    /// `centroids[c]` = dense centroid vector of cluster `c`.
    pub centroids: Vec<Dense>,
    /// `members[c]` = indices (into the original document list) of cluster `c`.
    pub members: Vec<Vec<usize>>,
}

impl Clusters {
    /// The top terms (by centroid weight) characterizing each cluster.
    pub fn topics(&self, vocab: &[String], top_n: usize) -> Vec<Vec<String>> {
        self.centroids
            .iter()
            .map(|centroid| top_terms(centroid, vocab, top_n))
            .collect()
    }
}

/// Deterministic k-means with farthest-first seeding.
///
/// * `k` — number of clusters (capped at the number of non-empty vectors).
/// * `max_iters` — cap on EM iterations (deterministic, no random restarts).
///
/// Returns `None` if there are no documents or all vectors are empty.
pub fn kmeans(vectors: &[Dense], vocab: &[String], k: usize, max_iters: usize) -> Option<Clusters> {
    let n = vectors.len();
    if n == 0 || k == 0 {
        return None;
    }
    let dims = vocab.len();
    if dims == 0 {
        return None;
    }

    let non_empty: Vec<usize> = (0..n)
        .filter(|&i| squared_norm(&vectors[i]) > 0.0)
        .collect();
    if non_empty.is_empty() {
        return None;
    }

    let actual_k = k.min(non_empty.len());

    // Farthest-first initialization.
    let mut centroids: Vec<Dense> = Vec::with_capacity(actual_k);
    let first = *non_empty
        .iter()
        .max_by(|&&a, &&b| squared_norm(&vectors[a]).total_cmp(&squared_norm(&vectors[b])))
        .unwrap();
    centroids.push(vectors[first].clone());

    while centroids.len() < actual_k {
        let mut best_idx = 0usize;
        let mut best_dist = f64::NEG_INFINITY;
        for &i in &non_empty {
            let d = min_sq_dist(&vectors[i], &centroids);
            if d > best_dist {
                best_dist = d;
                best_idx = i;
            }
        }
        if best_dist <= 0.0 {
            break;
        }
        centroids.push(vectors[best_idx].clone());
    }

    while centroids.len() < actual_k && centroids.len() < non_empty.len() {
        centroids.push(vectors[non_empty[centroids.len()]].clone());
    }

    let mut assignments = vec![0usize; n];

    for _ in 0..max_iters {
        let mut changed = false;
        for i in 0..n {
            let (c, _) = nearest(&vectors[i], &centroids);
            if assignments[i] != c {
                assignments[i] = c;
                changed = true;
            }
        }

        let mut sums: Vec<Dense> = vec![vec![0.0; dims]; centroids.len()];
        let mut counts = vec![0usize; centroids.len()];
        for i in 0..n {
            let c = assignments[i];
            counts[c] += 1;
            for d in 0..dims {
                sums[c][d] += vectors[i][d];
            }
        }
        for c in 0..centroids.len() {
            if counts[c] > 0 {
                for d in 0..dims {
                    centroids[c][d] = sums[c][d] / counts[c] as f64;
                }
            }
        }

        if !changed {
            break;
        }
    }

    let mut members = vec![Vec::new(); centroids.len()];
    for i in 0..n {
        members[assignments[i]].push(i);
    }

    Some(Clusters {
        assignments,
        centroids,
        members,
    })
}

fn squared_norm(v: &Dense) -> f64 {
    v.iter().map(|x| x * x).sum()
}

fn min_sq_dist(v: &Dense, centroids: &[Dense]) -> f64 {
    centroids
        .iter()
        .map(|c| sq_dist(v, c))
        .fold(f64::INFINITY, f64::min)
}

fn sq_dist(a: &Dense, b: &Dense) -> f64 {
    a.iter().zip(b.iter()).map(|(x, y)| (x - y) * (x - y)).sum()
}

fn nearest(v: &Dense, centroids: &[Dense]) -> (usize, f64) {
    let mut best = (0usize, f64::INFINITY);
    for (c, centroid) in centroids.iter().enumerate() {
        let d = sq_dist(v, centroid);
        if d < best.1 {
            best = (c, d);
        }
    }
    best
}

fn top_terms(centroid: &Dense, vocab: &[String], n: usize) -> Vec<String> {
    let mut indexed: Vec<(usize, f64)> = centroid
        .iter()
        .copied()
        .enumerate()
        .filter(|(_, w)| *w > 0.0)
        .collect();
    indexed.sort_by(|a, b| b.1.total_cmp(&a.1).then(a.0.cmp(&b.0)));
    indexed
        .into_iter()
        .take(n)
        .map(|(i, _)| vocab[i].clone())
        .collect()
}

/// Determine a reasonable number of clusters from the corpus size (a mild
/// `sqrt(n)` heuristic, deterministic).
pub fn default_k(num_docs: usize) -> usize {
    let k = (num_docs as f64).sqrt().round() as usize;
    k.clamp(2, 16)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kmeans_groups_obvious_topics() {
        let vocab: Vec<String> = ["finance", "invoice", "receipt", "recipe", "cake", "credit"]
            .iter()
            .map(|s| s.to_string())
            .collect();

        let mut v1 = vec![0.0; 6];
        v1[0] = 1.0;
        v1[1] = 1.0;
        v1[2] = 1.0;
        let mut v2 = vec![0.0; 6];
        v2[0] = 1.0;
        v2[1] = 1.0;
        v2[5] = 1.0;
        let mut v3 = vec![0.0; 6];
        v3[2] = 1.0;
        v3[3] = 1.0;
        v3[4] = 1.0;
        let mut v4 = vec![0.0; 6];
        v4[3] = 1.0;
        v4[4] = 1.0;
        v4[5] = 1.0;

        let clusters = kmeans(&[v1, v2, v3, v4], &vocab, 2, 100).unwrap();
        assert_eq!(clusters.assignments[0], clusters.assignments[1]);
        assert_eq!(clusters.assignments[2], clusters.assignments[3]);
        assert_ne!(clusters.assignments[0], clusters.assignments[2]);
    }

    #[test]
    fn kmeans_is_deterministic_across_runs() {
        let vocab: Vec<String> = (0..8).map(|i| format!("t{i}")).collect();
        let vectors: Vec<Dense> = (0..10)
            .map(|i| {
                let mut v = vec![0.0; 8];
                v[i % 4] = 1.0;
                v[i % 3] = 0.5;
                v
            })
            .collect();

        let first = kmeans(&vectors, &vocab, 3, 50).unwrap();
        let second = kmeans(&vectors, &vocab, 3, 50).unwrap();
        assert_eq!(first.assignments, second.assignments);
        assert_eq!(first.topics(&vocab, 3), second.topics(&vocab, 3));
    }

    #[test]
    fn kmeans_returns_none_for_empty_input() {
        let vocab: Vec<String> = vec!["a".to_owned()];
        assert!(kmeans(&[], &vocab, 2, 10).is_none());
    }
}
