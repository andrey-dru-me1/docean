use std::fs;
use std::io;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::library_sync::{DirFile, LibraryDir};

#[derive(Debug, Clone)]
pub struct LibraryFile {
    pub name: String,
    pub size: u64,
    pub modified_ms: i64,
}

#[derive(Debug, Clone)]
pub struct TreeFile {
    pub rel_dir: String,
    pub name: String,
    pub size: u64,
    pub modified_ms: i64,
}

#[derive(Debug, Clone)]
pub struct LibraryFs {
    dir: PathBuf,
}

impl LibraryFs {
    pub fn open(dir: &Path) -> io::Result<Self> {
        fs::create_dir_all(dir)?;
        Ok(Self {
            dir: dir.to_path_buf(),
        })
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    pub fn file_name_for(original_name: Option<&str>, mime_type: &str, hash: &str) -> String {
        let hash8 = &hash[..hash.len().min(8)];
        let stem = match original_name {
            Some(n) => {
                let raw_stem = Path::new(n)
                    .file_stem()
                    .map(|s| s.to_string_lossy().into_owned())
                    .unwrap_or_default();
                let sanitized = sanitize_stem(&raw_stem);
                if sanitized.is_empty() {
                    format!("document-{hash8}")
                } else {
                    sanitized
                }
            }
            None => format!("document-{hash8}"),
        };

        match resolve_ext(original_name, mime_type) {
            Some(e) => format!("{stem}.{e}"),
            None => stem,
        }
    }

    /// File name for a document mirror derived from the app's document title.
    ///
    /// The stem is the sanitized title (Unicode letters survive — Cyrillic,
    /// CJK, ...); the extension comes from the original file name when it has
    /// one, else from the mime type. A title that already ends with the
    /// resolved extension is not doubled. An empty sanitized title falls back
    /// to `document-<hash8>`.
    pub fn title_file_name(
        title: Option<&str>,
        original_name: Option<&str>,
        mime_type: &str,
        hash: &str,
    ) -> String {
        let hash8 = &hash[..hash.len().min(8)];
        let ext = resolve_ext(original_name, mime_type);
        let mut stem = match title {
            Some(t) => {
                let sanitized = sanitize_fs_stem(t);
                if sanitized.is_empty() {
                    format!("document-{hash8}")
                } else {
                    sanitized
                }
            }
            None => format!("document-{hash8}"),
        };
        if let Some(e) = &ext {
            let suffix = format!(".{e}");
            if stem
                .to_ascii_lowercase()
                .ends_with(&suffix.to_ascii_lowercase())
            {
                stem.truncate(stem.len() - suffix.len());
            }
        }
        match ext {
            Some(e) => format!("{stem}.{e}"),
            None => stem,
        }
    }

    /// First available name in the directory for [base]: [base] itself, then
    /// `base (2)`, `base (3)`, ... — extension preserved, human-readable
    /// collision suffixes.
    pub fn unique_name(&self, base: &str) -> String {
        if !self.contains(base) {
            return base.to_owned();
        }

        let (stem, ext) = match base.rfind('.') {
            Some(i) => (&base[..i], Some(&base[i + 1..])),
            None => (base, None),
        };

        let make = |n: u64| match ext {
            Some(e) => format!("{stem} ({n}).{e}"),
            None => format!("{stem} ({n})"),
        };

        let mut n: u64 = 2;
        loop {
            let candidate = make(n);
            if !self.contains(&candidate) {
                return candidate;
            }
            n += 1;
        }
    }

    pub fn write_file(&self, name: &str, bytes: &[u8]) -> io::Result<PathBuf> {
        let tmp = self.dir.join(format!(".{name}.tmp"));
        {
            let mut f = fs::File::create(&tmp)?;
            f.write_all(bytes)?;
            f.sync_all()?;
        }
        let dest = self.dir.join(name);
        fs::rename(&tmp, &dest)?;
        Ok(dest)
    }

    pub fn read_file(&self, name: &str) -> io::Result<Vec<u8>> {
        fs::read(self.dir.join(name))
    }

    pub fn contains(&self, name: &str) -> bool {
        self.dir.join(name).exists()
    }

    pub fn list_files(&self) -> io::Result<Vec<LibraryFile>> {
        let mut out = Vec::new();
        for entry in fs::read_dir(&self.dir)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || name.ends_with(".tmp") {
                continue;
            }
            let md = entry.metadata()?;
            if !md.is_file() {
                continue;
            }
            out.push(LibraryFile {
                name,
                size: md.len(),
                modified_ms: system_time_to_ms(md.modified()),
            });
        }
        out.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(out)
    }

    pub fn remove_file(&self, name: &str) -> io::Result<bool> {
        match fs::remove_file(self.dir.join(name)) {
            Ok(()) => Ok(true),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(e),
        }
    }

    fn validate_rel_dir(rel_dir: &str) -> io::Result<()> {
        if rel_dir == ".."
            || rel_dir.contains("/../")
            || rel_dir.ends_with("/..")
            || rel_dir.starts_with("../")
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "relative path may not contain '..' segments",
            ));
        }
        Ok(())
    }

    pub fn ensure_dir(&self, rel_dir: &str) -> io::Result<()> {
        if rel_dir.is_empty() {
            return Ok(());
        }
        Self::validate_rel_dir(rel_dir)?;
        fs::create_dir_all(self.dir.join(rel_dir))
    }

    pub fn rel_path(&self, rel_dir: &str, name: &str) -> PathBuf {
        if rel_dir.is_empty() {
            self.dir.join(name)
        } else {
            self.dir.join(rel_dir).join(name)
        }
    }

    pub fn contains_tree(&self, rel_dir: &str, name: &str) -> bool {
        self.rel_path(rel_dir, name).exists()
    }

    pub fn read_tree_file(&self, rel_dir: &str, name: &str) -> io::Result<Vec<u8>> {
        fs::read(self.rel_path(rel_dir, name))
    }

    pub fn write_tree_file(&self, rel_dir: &str, name: &str, bytes: &[u8]) -> io::Result<PathBuf> {
        self.ensure_dir(rel_dir)?;
        let dest = self.rel_path(rel_dir, name);
        let parent = dest.parent().unwrap_or(&self.dir);
        let tmp = parent.join(format!(".{name}.tmp"));
        {
            let mut f = fs::File::create(&tmp)?;
            f.write_all(bytes)?;
            f.sync_all()?;
        }
        fs::rename(&tmp, &dest)?;
        Ok(dest)
    }

    pub fn remove_tree_file(&self, rel_dir: &str, name: &str) -> io::Result<bool> {
        let path = self.rel_path(rel_dir, name);
        match fs::remove_file(&path) {
            Ok(()) => {
                if !rel_dir.is_empty() {
                    self.prune_empty_dirs(rel_dir);
                }
                Ok(true)
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(e),
        }
    }

    fn prune_empty_dirs(&self, rel_dir: &str) {
        let mut current = self.dir.join(rel_dir);
        let root = &self.dir;
        while current != *root {
            match fs::read_dir(&current) {
                Ok(mut entries) => {
                    if entries.next().is_some() {
                        break;
                    }
                    drop(entries);
                    let _ = fs::remove_dir(&current);
                }
                Err(_) => break,
            }
            current = match current.parent() {
                Some(p) if p != root => p.to_path_buf(),
                _ => break,
            };
        }
    }

    pub fn walk_tree(&self) -> io::Result<Vec<TreeFile>> {
        let mut result = Vec::new();
        self.walk_tree_recursive(&self.dir, "", &mut result)?;
        result.sort_by(|a, b| a.rel_dir.cmp(&b.rel_dir).then_with(|| a.name.cmp(&b.name)));
        Ok(result)
    }

    fn walk_tree_recursive(
        &self,
        dir: &Path,
        rel_dir: &str,
        out: &mut Vec<TreeFile>,
    ) -> io::Result<()> {
        let mut entries: Vec<_> = fs::read_dir(dir)?.filter_map(|e| e.ok()).collect();
        entries.sort_by_key(|e| e.file_name());

        let mut has_children = false;
        for entry in &entries {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || name.ends_with(".tmp") {
                continue;
            }
            let md = match entry.metadata() {
                Ok(m) => m,
                Err(_) => continue,
            };
            if md.is_file() {
                has_children = true;
                out.push(TreeFile {
                    rel_dir: rel_dir.to_owned(),
                    name,
                    size: md.len(),
                    modified_ms: system_time_to_ms(md.modified()),
                });
            } else if md.is_dir() {
                let child_rel = if rel_dir.is_empty() {
                    name.clone()
                } else {
                    format!("{}/{}", rel_dir, name)
                };
                let before = out.len();
                self.walk_tree_recursive(&entry.path(), &child_rel, out)?;
                if out.len() > before {
                    has_children = true;
                }
            }
        }
        let _ = has_children;
        Ok(())
    }
}

impl LibraryDir for LibraryFs {
    fn contains(&self, name: &str) -> bool {
        LibraryFs::contains(self, name)
    }

    fn list_files(&self) -> io::Result<Vec<DirFile>> {
        Ok(LibraryFs::list_files(self)?
            .into_iter()
            .map(|f| DirFile {
                name: f.name,
                size: f.size,
                modified_ms: f.modified_ms,
            })
            .collect())
    }

    fn read_file(&self, name: &str) -> io::Result<Vec<u8>> {
        LibraryFs::read_file(self, name)
    }

    fn write_file(&self, name: &str, bytes: &[u8]) -> io::Result<()> {
        LibraryFs::write_file(self, name, bytes).map(|_| ())
    }

    fn path_for(&self, name: &str) -> Option<PathBuf> {
        Some(self.dir.join(name))
    }

    fn walk_tree(&self) -> io::Result<Vec<TreeFile>> {
        LibraryFs::walk_tree(self)
    }

    fn ensure_dir(&self, rel_dir: &str) -> io::Result<()> {
        LibraryFs::ensure_dir(self, rel_dir)
    }

    fn read_tree_file(&self, rel_dir: &str, name: &str) -> io::Result<Vec<u8>> {
        LibraryFs::read_tree_file(self, rel_dir, name)
    }

    fn write_tree_file(&self, rel_dir: &str, name: &str, bytes: &[u8]) -> io::Result<()> {
        LibraryFs::write_tree_file(self, rel_dir, name, bytes).map(|_| ())
    }

    fn remove_tree_file(&self, rel_dir: &str, name: &str) -> io::Result<bool> {
        LibraryFs::remove_tree_file(self, rel_dir, name)
    }

    fn contains_tree(&self, rel_dir: &str, name: &str) -> bool {
        LibraryFs::contains_tree(self, rel_dir, name)
    }
}

fn resolve_ext(original_name: Option<&str>, mime_type: &str) -> Option<String> {
    original_ext(original_name).or_else(|| mime_to_ext(mime_type).map(str::to_owned))
}

/// Sanitize a document title into a filesystem-safe stem, preserving Unicode
/// letters and digits (Cyrillic, CJK, ...). Allowed: alphanumeric, space,
/// `.`, `_`, `-`, `(`, `)`; everything else collapses to `_` (runs dedup'd),
/// edges are trimmed, length capped at 80 chars, and Windows-reserved device
/// names get a `_` prefix.
pub(crate) fn sanitize_fs_stem(raw: &str) -> String {
    let mapped: String = raw
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || matches!(c, ' ' | '.' | '_' | '-' | '(' | ')') {
                c
            } else {
                '_'
            }
        })
        .collect();

    let mut collapsed = String::with_capacity(mapped.len());
    let mut prev_underscore = false;
    for c in mapped.chars() {
        if c == '_' {
            if prev_underscore {
                continue;
            }
            prev_underscore = true;
        } else {
            prev_underscore = false;
        }
        collapsed.push(c);
    }

    let trimmed = collapsed.trim_matches(|c| matches!(c, '_' | '.' | '-' | ' '));
    let mut stem: String = trimmed.chars().take(80).collect();
    if is_windows_reserved(&stem) {
        stem.insert(0, '_');
    }
    stem
}

/// Whether [stem]'s name head (before the first dot) is a Windows-reserved
/// device name (`CON`, `PRN`, `AUX`, `NUL`, `COM1-9`, `LPT1-9`), which is
/// illegal as a file or directory name on Windows even with an extension.
fn is_windows_reserved(stem: &str) -> bool {
    let head = stem.split('.').next().unwrap_or("").to_ascii_uppercase();
    match head.as_str() {
        "CON" | "PRN" | "AUX" | "NUL" => true,
        _ if head.is_empty() => false,
        _ => {
            // Reserved suffixes are ASCII digits only; a multi-byte last
            // char can never qualify.
            let last = head.chars().last().unwrap_or('\0');
            let prefix_len = head.len() - last.len_utf8();
            let prefix = &head[..prefix_len];
            (prefix == "COM" || prefix == "LPT") && matches!(last, '1'..='9')
        }
    }
}

fn sanitize_stem(stem: &str) -> String {
    let mut mapped = String::with_capacity(stem.len());
    for c in stem.chars() {
        if c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == ' ' || c == '-' {
            mapped.push(c);
        } else {
            mapped.push('_');
        }
    }

    let mut collapsed = String::with_capacity(mapped.len());
    let mut prev_underscore = false;
    for c in mapped.chars() {
        if c == '_' {
            if prev_underscore {
                continue;
            }
            prev_underscore = true;
        } else {
            prev_underscore = false;
        }
        collapsed.push(c);
    }

    let trimmed = collapsed.trim_matches(|c| c == '.' || c == '_' || c == '-');
    trimmed.chars().take(80).collect()
}

fn original_ext(original_name: Option<&str>) -> Option<String> {
    let name = original_name?;
    let ext = Path::new(name).extension()?.to_str()?;
    let ext = ext.to_ascii_lowercase();
    if !ext.is_empty() && ext.len() <= 8 && ext.chars().all(|c| c.is_ascii_alphanumeric()) {
        Some(ext)
    } else {
        None
    }
}

fn mime_to_ext(mime_type: &str) -> Option<&'static str> {
    match mime_type {
        "application/pdf" => Some("pdf"),
        "text/plain" => Some("txt"),
        "text/markdown" => Some("md"),
        "text/html" => Some("html"),
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => Some("docx"),
        "application/msword" => Some("doc"),
        "application/vnd.oasis.opendocument.text" => Some("odt"),
        "application/rtf" => Some("rtf"),
        "application/epub+zip" => Some("epub"),
        "message/rfc822" => Some("eml"),
        "image/png" => Some("png"),
        "image/jpeg" => Some("jpg"),
        "image/gif" => Some("gif"),
        "image/bmp" => Some("bmp"),
        "image/webp" => Some("webp"),
        "image/tiff" => Some("tiff"),
        "image/heic" => Some("heic"),
        "application/zip" => Some("zip"),
        _ => None,
    }
}

fn system_time_to_ms(t: io::Result<SystemTime>) -> i64 {
    match t {
        Ok(t) => t
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0),
        Err(_) => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root(tag: &str) -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "docean-library-fs-{tag}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn file_name_for_sanitizes_stem() {
        assert_eq!(
            LibraryFs::file_name_for(Some("Hello World.pdf"), "application/pdf", "abcdef12345678"),
            "Hello World.pdf"
        );
        // Special chars replaced with _, collapsed, trimmed, truncated
        let long_name = format!("{}Report.pdf", "A".repeat(90));
        let result =
            LibraryFs::file_name_for(Some(&long_name), "application/pdf", "abcdef12345678");
        assert!(result.len() <= "A".repeat(80).len() + ".pdf".len() + 1);
        assert!(result.starts_with('A'));
        assert!(result.ends_with(".pdf"));
    }

    #[test]
    fn file_name_for_trims_leading_trailing_separator_chars() {
        assert_eq!(
            LibraryFs::file_name_for(Some("--Report--.pdf"), "application/pdf", "abcdef12345678"),
            "Report.pdf"
        );
        assert_eq!(
            LibraryFs::file_name_for(Some("..Report..pdf"), "application/pdf", "abcdef12345678"),
            "Report.pdf"
        );
        assert_eq!(
            LibraryFs::file_name_for(Some("_Report_.pdf"), "application/pdf", "abcdef12345678"),
            "Report.pdf"
        );
    }

    #[test]
    fn file_name_for_keeps_allowed_spaces() {
        // Spaces are in the keep set [A-Za-z0-9._ -]
        assert_eq!(
            LibraryFs::file_name_for(
                Some("Hello   World.pdf"),
                "application/pdf",
                "abcdef12345678"
            ),
            "Hello   World.pdf"
        );
    }

    #[test]
    fn file_name_for_collapses_consecutive_underscores() {
        // Non-allowed chars become _, then consecutive _ collapse to one
        assert_eq!(
            LibraryFs::file_name_for(
                Some("Hello @#$ World.pdf"),
                "application/pdf",
                "abcdef12345678"
            ),
            "Hello _ World.pdf"
        );
        // A run of garbage between words collapses to a single _
        assert_eq!(
            LibraryFs::file_name_for(Some("Q1@report#.pdf"), "application/pdf", "abcdef12345678"),
            "Q1_report.pdf"
        );
    }

    #[test]
    fn file_name_for_empty_stem_uses_hash() {
        // A name whose stem collapses to nothing falls back to the hash
        assert_eq!(
            LibraryFs::file_name_for(Some("---"), "application/pdf", "abcdef12345678"),
            "document-abcdef12.pdf"
        );
        assert_eq!(
            LibraryFs::file_name_for(Some("*_*"), "application/pdf", "abcdef12345678"),
            "document-abcdef12.pdf"
        );
    }

    #[test]
    fn file_name_for_dotfile_stem_trimmed() {
        // Leading dot is trimmed → "hidden" is the stem
        assert_eq!(
            LibraryFs::file_name_for(Some(".hidden"), "application/pdf", "abcdef12345678"),
            "hidden.pdf"
        );
    }

    #[test]
    fn file_name_for_no_original_name_uses_hash() {
        assert_eq!(
            LibraryFs::file_name_for(None, "application/pdf", "abcdef12345678"),
            "document-abcdef12.pdf"
        );
    }

    #[test]
    fn file_name_for_mime_mapping() {
        assert_eq!(
            LibraryFs::file_name_for(None, "text/plain", "abcdef12345678"),
            "document-abcdef12.txt"
        );
        assert_eq!(
            LibraryFs::file_name_for(None, "text/markdown", "abcdef12345678"),
            "document-abcdef12.md"
        );
        assert_eq!(
            LibraryFs::file_name_for(None, "text/html", "abcdef12345678"),
            "document-abcdef12.html"
        );
        assert_eq!(
            LibraryFs::file_name_for(
                None,
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                "abcdef12345678"
            ),
            "document-abcdef12.docx"
        );
        assert_eq!(
            LibraryFs::file_name_for(None, "message/rfc822", "abcdef12345678"),
            "document-abcdef12.eml"
        );
        assert_eq!(
            LibraryFs::file_name_for(None, "image/jpeg", "abcdef12345678"),
            "document-abcdef12.jpg"
        );
        assert_eq!(
            LibraryFs::file_name_for(None, "application/zip", "abcdef12345678"),
            "document-abcdef12.zip"
        );
        // Unmapped mime → no extension
        assert_eq!(
            LibraryFs::file_name_for(None, "application/octet-stream", "abcdef12345678"),
            "document-abcdef12"
        );
    }

    #[test]
    fn file_name_for_original_ext_preferred_over_mime() {
        assert_eq!(
            LibraryFs::file_name_for(Some("Report.pdf"), "text/plain", "abcdef12345678"),
            "Report.pdf"
        );
    }

    #[test]
    fn unique_name_collision_handling() {
        let root = temp_root("unique");
        let lib = LibraryFs::open(&root).unwrap();
        // Pre-seed "Report.pdf"
        fs::write(root.join("Report.pdf"), b"").unwrap();
        assert_eq!(lib.unique_name("Report.pdf"), "Report (2).pdf");

        // Pre-seed that too
        fs::write(root.join("Report (2).pdf"), b"").unwrap();
        assert_eq!(lib.unique_name("Report.pdf"), "Report (3).pdf");

        // Pre-seed that
        fs::write(root.join("Report (3).pdf"), b"").unwrap();
        assert_eq!(lib.unique_name("Report.pdf"), "Report (4).pdf");

        // Extensionless names collide the same way.
        fs::write(root.join("Notes"), b"").unwrap();
        assert_eq!(lib.unique_name("Notes"), "Notes (2)");

        // A free base is returned untouched.
        assert_eq!(lib.unique_name("Fresh.txt"), "Fresh.txt");
    }

    #[test]
    fn title_file_name_derives_from_title() {
        assert_eq!(
            LibraryFs::title_file_name(
                Some("Quarterly Report"),
                Some("scan_0042.pdf"),
                "application/pdf",
                "abcdef12345678"
            ),
            "Quarterly Report.pdf"
        );
        // Cyrillic (and any Unicode letters) must survive.
        assert_eq!(
            LibraryFs::title_file_name(
                Some("Конспект лекций"),
                None,
                "application/pdf",
                "abcdef12345678"
            ),
            "Конспект лекций.pdf"
        );
        // A title already carrying the extension is not doubled.
        assert_eq!(
            LibraryFs::title_file_name(
                Some("Report.pdf"),
                None,
                "application/pdf",
                "abcdef12345678"
            ),
            "Report.pdf"
        );
        // Forbidden filesystem characters fold into underscores; edge
        // underscores are trimmed.
        assert_eq!(
            LibraryFs::title_file_name(Some("a/b: c<d>?"), None, "text/plain", "abcdef12345678"),
            "a_b_ c_d.txt"
        );
        // Empty title falls back to the hash.
        assert_eq!(
            LibraryFs::title_file_name(
                Some("---"),
                Some("x.bin"),
                "application/octet-stream",
                "abcdef12345678"
            ),
            "document-abcdef12.bin"
        );
    }

    #[test]
    fn sanitize_fs_stem_windows_reserved_names() {
        assert_eq!(sanitize_fs_stem("CON"), "_CON");
        assert_eq!(sanitize_fs_stem("nul"), "_nul");
        assert_eq!(sanitize_fs_stem("Com1"), "_Com1");
        assert_eq!(sanitize_fs_stem("lpt4.txt"), "_lpt4.txt");
        assert_eq!(sanitize_fs_stem("CON.txt"), "_CON.txt");
        assert_eq!(sanitize_fs_stem("console"), "console");
        // Trailing dots and spaces are trimmed (Windows).
        assert_eq!(sanitize_fs_stem("Report. "), "Report");
    }

    #[test]
    fn write_read_round_trip() {
        let root = temp_root("rw");
        let lib = LibraryFs::open(&root).unwrap();
        let data = b"hello world content";
        lib.write_file("test.txt", data).unwrap();
        let read = lib.read_file("test.txt").unwrap();
        assert_eq!(read, data);
    }

    #[test]
    fn list_files_skips_dotfiles_and_tmp() {
        let root = temp_root("list");
        let lib = LibraryFs::open(&root).unwrap();
        fs::write(root.join("visible.txt"), b"v").unwrap();
        fs::write(root.join(".hidden"), b"h").unwrap();
        fs::write(root.join("temp.tmp"), b"t").unwrap();
        fs::create_dir(root.join("subdir")).unwrap(); // skipped (not a file)

        let files = lib.list_files().unwrap();
        let names: Vec<&str> = files.iter().map(|f| f.name.as_str()).collect();
        assert_eq!(names, vec!["visible.txt"]);
        assert_eq!(files[0].size, 1);
    }

    #[test]
    fn remove_file_idempotent() {
        let root = temp_root("rm");
        let lib = LibraryFs::open(&root).unwrap();
        fs::write(root.join("to_delete.txt"), b"d").unwrap();
        assert!(lib.remove_file("to_delete.txt").unwrap());
        assert!(!lib.contains("to_delete.txt"));
        assert!(!lib.remove_file("to_delete.txt").unwrap());
    }

    #[test]
    fn contains_reflects_written_file() {
        let root = temp_root("contains");
        let lib = LibraryFs::open(&root).unwrap();
        assert!(!lib.contains("nope.txt"));
        lib.write_file("nope.txt", b"x").unwrap();
        assert!(lib.contains("nope.txt"));
    }

    #[test]
    fn list_files_sorted_by_name() {
        let root = temp_root("sorted");
        let lib = LibraryFs::open(&root).unwrap();
        fs::write(root.join("z.txt"), b"1").unwrap();
        fs::write(root.join("a.txt"), b"2").unwrap();
        fs::write(root.join("m.txt"), b"3").unwrap();

        let files = lib.list_files().unwrap();
        let names: Vec<&str> = files.iter().map(|f| f.name.as_str()).collect();
        assert_eq!(names, vec!["a.txt", "m.txt", "z.txt"]);
    }

    #[test]
    fn file_name_for_unique_across_different_stems() {
        // Two different stems shouldn't collide
        let a = LibraryFs::file_name_for(Some("Alpha.pdf"), "application/pdf", "aaaa");
        let b = LibraryFs::file_name_for(Some("Beta.pdf"), "application/pdf", "bbbb");
        assert_ne!(a, b);
    }

    #[test]
    fn walk_tree_nested_dirs() {
        let root = temp_root("walk-nested");
        let lib = LibraryFs::open(&root).unwrap();
        fs::write(root.join("root.txt"), b"r").unwrap();
        fs::create_dir_all(root.join("a")).unwrap();
        fs::write(root.join("a/file1.txt"), b"1").unwrap();
        fs::create_dir_all(root.join("a/b")).unwrap();
        fs::write(root.join("a/b/file2.txt"), b"2").unwrap();
        // Dotfiles and tmp should be skipped
        fs::write(root.join(".dotfile"), b"d").unwrap();
        fs::write(root.join("a/.hidden"), b"h").unwrap();
        fs::write(root.join("a/temp.tmp"), b"t").unwrap();
        // Empty dir should be skipped
        fs::create_dir(root.join("a/b/empty")).unwrap();

        let tree = lib.walk_tree().unwrap();
        assert_eq!(tree.len(), 3);
        assert_eq!(tree[0].rel_dir, "");
        assert_eq!(tree[0].name, "root.txt");
        assert_eq!(tree[1].rel_dir, "a");
        assert_eq!(tree[1].name, "file1.txt");
        assert_eq!(tree[2].rel_dir, "a/b");
        assert_eq!(tree[2].name, "file2.txt");
    }

    #[test]
    fn walk_tree_deep_nesting() {
        let root = temp_root("walk-deep");
        let lib = LibraryFs::open(&root).unwrap();
        // 5-level deep path
        fs::create_dir_all(root.join("teaching/diploma/2025-2026/Andrey")).unwrap();
        fs::write(
            root.join("teaching/diploma/2025-2026/Andrey/article.pdf"),
            b"deep",
        )
        .unwrap();
        fs::create_dir_all(root.join("a/b/c/d")).unwrap();
        fs::write(root.join("a/b/c/d/deep.txt"), b"deepest").unwrap();

        let tree = lib.walk_tree().unwrap();
        assert_eq!(tree.len(), 2);
        assert_eq!(tree[0].rel_dir, "a/b/c/d");
        assert_eq!(tree[0].name, "deep.txt");
        assert_eq!(tree[1].rel_dir, "teaching/diploma/2025-2026/Andrey");
        assert_eq!(tree[1].name, "article.pdf");
    }

    #[test]
    fn ensure_dir_rejects_dotdot() {
        let root = temp_root("ensure-dotdot");
        let lib = LibraryFs::open(&root).unwrap();
        assert!(lib.ensure_dir("..").is_err());
        assert!(lib.ensure_dir("a/../b").is_err());
        assert!(lib.ensure_dir("a/..").is_err());
        assert!(lib.ensure_dir("../a").is_err());
        // Valid paths should work
        assert!(lib.ensure_dir("a/b/c").is_ok());
    }

    #[test]
    fn ensure_dir_creates_nested() {
        let root = temp_root("ensure-nested");
        let lib = LibraryFs::open(&root).unwrap();
        lib.ensure_dir("x/y/z").unwrap();
        assert!(root.join("x/y/z").is_dir());
        // Empty string is a no-op
        lib.ensure_dir("").unwrap();
    }

    #[test]
    fn write_read_tree_round_trip() {
        let root = temp_root("tree-rw");
        let lib = LibraryFs::open(&root).unwrap();
        let data = b"nested content";
        lib.write_tree_file("a/b", "file.txt", data).unwrap();
        let read = lib.read_tree_file("a/b", "file.txt").unwrap();
        assert_eq!(read, data);
        // Root file
        lib.write_tree_file("", "root.txt", b"root").unwrap();
        let read = lib.read_tree_file("", "root.txt").unwrap();
        assert_eq!(read, b"root");
    }

    #[test]
    fn remove_tree_file_prunes_empty_parents() {
        let root = temp_root("tree-prune");
        let lib = LibraryFs::open(&root).unwrap();
        lib.write_tree_file("a/b/c", "file.txt", b"data").unwrap();
        assert!(root.join("a/b/c/file.txt").exists());
        assert!(root.join("a/b/c").is_dir());
        assert!(root.join("a/b").is_dir());
        assert!(root.join("a").is_dir());

        lib.remove_tree_file("a/b/c", "file.txt").unwrap();
        assert!(!root.join("a/b/c/file.txt").exists());
        // Empty parent dirs should be pruned
        assert!(!root.join("a/b/c").exists());
        assert!(!root.join("a/b").exists());
        assert!(!root.join("a").exists());
    }

    #[test]
    fn contains_tree_checks_subdirectory() {
        let root = temp_root("tree-contains");
        let lib = LibraryFs::open(&root).unwrap();
        assert!(!lib.contains_tree("a/b", "file.txt"));
        lib.write_tree_file("a/b", "file.txt", b"x").unwrap();
        assert!(lib.contains_tree("a/b", "file.txt"));
        assert!(!lib.contains_tree("", "root.txt"));
        lib.write_tree_file("", "root.txt", b"r").unwrap();
        assert!(lib.contains_tree("", "root.txt"));
    }
}
