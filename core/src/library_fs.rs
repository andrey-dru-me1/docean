use std::fs;
use std::io;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone)]
pub struct LibraryFile {
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

        let ext = original_ext(original_name).or_else(|| mime_to_ext(mime_type).map(str::to_owned));

        match ext {
            Some(e) => format!("{stem}.{e}"),
            None => stem,
        }
    }

    pub fn unique_name(&self, base: &str, hash: &str) -> String {
        let hash8 = &hash[..hash.len().min(8)];

        let (stem, ext) = match base.rfind('.') {
            Some(i) => (&base[..i], Some(&base[i + 1..])),
            None => (base, None),
        };

        let make = |suffix: Option<&str>| match (ext, suffix) {
            (Some(e), Some(s)) => format!("{stem}{s}.{e}"),
            (Some(e), None) => format!("{stem}.{e}"),
            (None, Some(s)) => format!("{stem}{s}"),
            (None, None) => stem.to_string(),
        };

        let first = make(None);
        if !self.contains(&first) {
            return first;
        }

        let second = make(Some(&format!("-{hash8}")));
        if !self.contains(&second) {
            return second;
        }

        let mut n: u64 = 2;
        loop {
            let candidate = make(Some(&format!("-{hash8}-{n}")));
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
            "docer-library-fs-{tag}-{}-{}",
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
        let hash = "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890";

        // Pre-seed "Report.pdf"
        fs::write(root.join("Report.pdf"), b"").unwrap();
        let name1 = lib.unique_name("Report.pdf", hash);
        assert_eq!(name1, "Report-abcdef12.pdf");

        // Pre-seed that too
        fs::write(root.join("Report-abcdef12.pdf"), b"").unwrap();
        let name2 = lib.unique_name("Report.pdf", hash);
        assert_eq!(name2, "Report-abcdef12-2.pdf");

        // Pre-seed that
        fs::write(root.join("Report-abcdef12-2.pdf"), b"").unwrap();
        let name3 = lib.unique_name("Report.pdf", hash);
        assert_eq!(name3, "Report-abcdef12-3.pdf");
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
}
