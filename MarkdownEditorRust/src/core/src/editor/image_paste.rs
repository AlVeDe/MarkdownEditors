//! Pasted or dropped images and files become Markdown links.
//!
//! - Image *data* (a screenshot on the clipboard) is written as PNG into
//!   `<doc>.assets/` next to the document and linked relatively. That needs
//!   a saved document.
//! - Image *files* outside the document's folder are copied into the same
//!   assets folder; files already inside the folder tree are linked in place.
//! - Other dropped files get a plain `[name](path)` link, never a copy.

use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use super::{u16len, Editor};
use crate::text::Range;

pub const IMAGE_EXTENSIONS: &[&str] =
    &["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff", "heic", "heif", "avif", "ico"];

pub fn is_image_file(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| IMAGE_EXTENSIONS.contains(&e.to_lowercase().as_str()))
}

/// `<doc dir>/<doc base name>.assets`
pub fn assets_folder(document: &Path) -> PathBuf {
    let base = document.file_stem().and_then(|s| s.to_str()).unwrap_or("document");
    document.parent().unwrap_or(Path::new(".")).join(format!("{base}.assets"))
}

/// `yyyyMMdd-HHmmss` (UTC) for a time.
pub fn timestamp(time: SystemTime) -> String {
    let secs = time.duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0) as i64;
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    // Civil-from-days (Howard Hinnant).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{:04}{:02}{:02}-{:02}{:02}{:02}", y, m, d, rem / 3600, rem % 3600 / 60, rem % 60)
}

/// `base.ext`, or `base-1.ext`, `base-2.ext`… whichever does not exist.
pub fn unique_path(folder: &Path, base: &str, ext: &str) -> PathBuf {
    let make = |name: &str| if ext.is_empty() { folder.join(name) } else { folder.join(format!("{name}.{ext}")) };
    let mut candidate = make(base);
    let mut counter = 1;
    while candidate.exists() {
        candidate = make(&format!("{base}-{counter}"));
        counter += 1;
    }
    candidate
}

/// Writes PNG bytes as `image-<timestamp>[-n].png` into the assets folder.
pub fn write_png(png: &[u8], document: &Path, time: SystemTime) -> io::Result<PathBuf> {
    if !png.starts_with(&[0x89, 0x50, 0x4E, 0x47]) {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "Unsupported image data."));
    }
    let folder = assets_folder(document);
    fs::create_dir_all(&folder)?;
    let file = unique_path(&folder, &format!("image-{}", timestamp(time)), "png");
    fs::write(&file, png)?;
    Ok(file)
}

/// The file a link should point at: the original when it already lives in
/// the document's folder tree, else a copy in the assets folder.
pub fn image_file_for_linking(file: &Path, document: &Path) -> io::Result<PathBuf> {
    let directory = document.parent().unwrap_or(Path::new("."));
    if is_file_inside(file, directory) {
        return Ok(file.to_path_buf());
    }
    let folder = assets_folder(document);
    fs::create_dir_all(&folder)?;
    let base = file.file_stem().and_then(|s| s.to_str()).unwrap_or("image");
    let ext = file.extension().and_then(|s| s.to_str()).unwrap_or("");
    let target = unique_path(&folder, base, ext);
    fs::copy(file, &target)?;
    Ok(target)
}

fn canonical_components(path: &Path) -> Vec<String> {
    let resolved = if path.exists() {
        fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
    } else {
        let parent = path.parent().map(|p| fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf()));
        match (parent, path.file_name()) {
            (Some(p), Some(n)) => p.join(n),
            _ => path.to_path_buf(),
        }
    };
    resolved
        .components()
        .filter_map(|c| match c {
            Component::Normal(s) => Some(s.to_string_lossy().into_owned()),
            Component::Prefix(p) => Some(p.as_os_str().to_string_lossy().to_lowercase()),
            _ => None,
        })
        .collect()
}

pub fn is_file_inside(file: &Path, directory: &Path) -> bool {
    let f = canonical_components(file);
    let d = canonical_components(directory);
    f.len() > d.len() && f[..d.len()] == d[..]
}

/// POSIX path from `directory` to `file`, with `..` for parents.
pub fn relative_path(directory: &Path, file: &Path) -> String {
    let from = canonical_components(directory);
    let to = canonical_components(file);
    let mut common = 0;
    while common < from.len() && common < to.len() && from[common] == to[common] {
        common += 1;
    }
    let mut parts: Vec<String> = vec!["..".into(); from.len() - common];
    parts.extend(to[common..].iter().cloned());
    parts.join("/")
}

/// Percent-encodes what would break a Markdown link destination.
pub fn markdown_path(path: &str) -> String {
    let mut out = String::new();
    for c in path.chars() {
        match c {
            '%' => out.push_str("%25"),
            ' ' => out.push_str("%20"),
            '(' => out.push_str("%28"),
            ')' => out.push_str("%29"),
            '<' => out.push_str("%3C"),
            '>' => out.push_str("%3E"),
            _ => out.push(c),
        }
    }
    out
}

fn escape_link_text(text: &str) -> String {
    text.replace('[', "\\[").replace(']', "\\]")
}

/// A `file://` URL for an absolute path.
pub fn file_url(path: &Path) -> String {
    let s = path.to_string_lossy().replace('\\', "/");
    let s = if s.starts_with('/') { s } else { format!("/{s}") };
    format!("file://{}", markdown_path(&s))
}

fn link(file: &Path, document: Option<&Path>) -> String {
    match document {
        Some(doc) => markdown_path(&relative_path(doc.parent().unwrap_or(Path::new(".")), file)),
        None => file_url(file),
    }
}

/// Why a paste could not be completed; shown to the user.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PasteError {
    NeedsSavedDocument,
    Failed(String),
}

impl std::fmt::Display for PasteError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PasteError::NeedsSavedDocument => write!(f, "Save the document first to paste images"),
            PasteError::Failed(m) => write!(f, "{m}"),
        }
    }
}

impl Editor<'_> {
    /// Pasted image data (PNG bytes) at the selection.
    pub fn insert_image_data(&mut self, png: &[u8], document: Option<&Path>) -> Result<(), PasteError> {
        let document = document.ok_or(PasteError::NeedsSavedDocument)?;
        let file = write_png(png, document, SystemTime::now())
            .map_err(|e| PasteError::Failed(format!("The image could not be saved: {e}")))?;
        let path = link(&file, Some(document));
        let range = self.selection;
        self.insert_items(&[(String::new(), path)], &[], range);
        Ok(())
    }

    /// Dropped or pasted files at `range`.
    pub fn insert_file_links(&mut self, files: &[PathBuf], document: Option<&Path>, range: Range) -> Result<(), PasteError> {
        let mut images = vec![];
        let mut links = vec![];
        for file in files {
            if is_image_file(file) {
                let target = match document {
                    Some(doc) => image_file_for_linking(file, doc)
                        .map_err(|e| PasteError::Failed(format!("The image could not be copied: {e}")))?,
                    None => file.clone(),
                };
                let alt = escape_link_text(file.file_stem().and_then(|s| s.to_str()).unwrap_or(""));
                images.push((alt, link(&target, document)));
            } else {
                let name = file.file_name().and_then(|s| s.to_str()).unwrap_or("").to_string();
                links.push((name, link(file, document)));
            }
        }
        self.insert_items(&images, &links, range);
        Ok(())
    }

    fn insert_items(&mut self, images: &[(String, String)], links: &[(String, String)], range: Range) {
        let mut items: Vec<String> = images.iter().map(|(alt, path)| format!("![{alt}]({path})")).collect();
        items.extend(links.iter().map(|(name, path)| format!("[{}]({path})", escape_link_text(name))));
        if items.is_empty() {
            return;
        }
        let text = items.join("\n");
        let selection = if items.len() == 1 && !images.is_empty() {
            Some(Range::new(range.location + 2, u16len(&images[0].0)))
        } else {
            None
        };
        self.replace_characters(range, &text, selection);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamps() {
        assert_eq!(timestamp(UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000)), "20231114-221320");
    }

    #[test]
    fn encodes_paths() {
        assert_eq!(markdown_path("a b(1).png"), "a%20b%281%29.png");
    }
}
