//! Case-insensitive fuzzy matching of what the user typed against a
//! completion's filter text. Three tiers, best first:
//!
//! - `Prefix`        `alp` → `alpha`
//! - `WordBoundary`  every typed character starts a word or continues the
//!                   previous matched character: `la` → `left-arrow`
//! - `Subsequence`   the characters appear in order: `lra` → `leftrightarrow`

use std::collections::HashSet;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default)]
pub enum Tier {
    #[default]
    Subsequence = 1,
    WordBoundary = 2,
    Prefix = 3,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Match {
    pub tier: Tier,
    pub matched_indices: Vec<usize>,
}

pub fn match_query(query: &str, candidate: &str) -> Option<Match> {
    let q: Vec<char> = query.to_lowercase().chars().collect();
    let original: Vec<char> = candidate.chars().collect();
    let c: Vec<char> = candidate.to_lowercase().chars().collect();
    if q.is_empty() {
        return Some(Match { tier: Tier::Prefix, matched_indices: vec![] });
    }
    let lower = if c.len() == original.len() { c } else { original.clone() };
    if q.len() > lower.len() {
        return None;
    }
    if lower.starts_with(&q) {
        return Some(Match { tier: Tier::Prefix, matched_indices: (0..q.len()).collect() });
    }
    if let Some(indices) = boundary_match(&q, &lower, &original) {
        return Some(Match { tier: Tier::WordBoundary, matched_indices: indices });
    }
    let mut indices = vec![];
    let mut qi = 0;
    for (ci, &ch) in lower.iter().enumerate() {
        if qi < q.len() && ch == q[qi] {
            indices.push(ci);
            qi += 1;
        }
    }
    (qi == q.len()).then_some(Match { tier: Tier::Subsequence, matched_indices: indices })
}

fn is_word_start(i: usize, original: &[char]) -> bool {
    if i == 0 {
        return true;
    }
    let previous = original[i - 1];
    let current = original[i];
    if !previous.is_alphanumeric() {
        return current.is_alphanumeric();
    }
    previous.is_lowercase() && current.is_uppercase()
}

fn boundary_match(q: &[char], c: &[char], original: &[char]) -> Option<Vec<usize>> {
    let mut failed = HashSet::new();
    let mut path = vec![];
    fn search(
        qi: usize,
        from: usize,
        q: &[char],
        c: &[char],
        original: &[char],
        failed: &mut HashSet<usize>,
        path: &mut Vec<usize>,
    ) -> bool {
        if qi == q.len() {
            return true;
        }
        let key = qi * (c.len() + 1) + from;
        if failed.contains(&key) {
            return false;
        }
        for ci in from..c.len() {
            if c[ci] != q[qi] {
                continue;
            }
            let contiguous = path.last().is_some_and(|&l| l + 1 == ci);
            if !(contiguous || is_word_start(ci, original)) {
                continue;
            }
            path.push(ci);
            if search(qi + 1, ci + 1, q, c, original, failed, path) {
                return true;
            }
            path.pop();
        }
        failed.insert(key);
        false
    }
    search(0, 0, q, c, original, &mut failed, &mut path).then_some(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tiers() {
        assert_eq!(match_query("alp", "alpha").unwrap().tier, Tier::Prefix);
        assert_eq!(match_query("la", "left-arrow").unwrap().tier, Tier::WordBoundary);
        assert_eq!(match_query("RA", "RightArrow").unwrap().tier, Tier::WordBoundary);
        assert_eq!(match_query("lra", "leftrightarrow").unwrap().tier, Tier::Subsequence);
        assert!(match_query("xyz", "alpha").is_none());
    }
}
