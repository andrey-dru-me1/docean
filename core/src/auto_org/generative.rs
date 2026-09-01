//! Optional generative LLM filename tier.
//!
//! **This is the only module in `auto_org` that depends on [`crate::ai`].** The
//! deterministic pipeline ([`super::organizer`]) never imports the LLM layer;
//! this upgrade is wired in by the caller only when a generative provider has
//! been enabled by the user.

use crate::ai::{BoxAiProvider, GenerateMode, GenerateRequest};
use crate::auto_org::config::OrgPlan;
use crate::auto_org::keywords::sanitize_filename;
use crate::auto_org::organizer::CorpusDoc;

/// Generate a human-friendly filename for `doc` using the active provider.
///
/// Returns `Err` if generation fails; the caller should fall back to the
/// deterministic template title already present in `plan`.
pub async fn generate_filename(
    provider: &BoxAiProvider,
    model: &str,
    doc: &CorpusDoc,
) -> anyhow::Result<String> {
    let prompt = format!(
        "Generate a short, descriptive filename (no extension, max 5 words) for \
         a document titled \"{}\" whose content starts with: \"{}\". \
         Return only the filename.",
        doc.title,
        excerpt(&doc.text, 400)
    );

    let request = GenerateRequest {
        model: model.to_owned(),
        prompt,
        system: Some(
            "You are a file-organizing assistant. Output only the filename, \
             no quotes, no explanation."
                .to_owned(),
        ),
        mode: GenerateMode::Summary,
        max_tokens: Some(16),
        temperature: Some(0.2),
    };

    let response = provider.generate(request).await?;
    let cleaned = sanitize_filename(response.content.trim());
    Ok(cleaned)
}

/// Apply a generated filename to `plan`, marking its source as generative.
pub fn apply_generated(plan: &mut OrgPlan, filename: String) {
    plan.suggested_title = Some(filename);
    plan.filename_source = crate::auto_org::config::FilenameSource::Generative;
}

fn excerpt(text: &str, max_chars: usize) -> String {
    let mut out: String = text.chars().take(max_chars).collect();
    if text.chars().count() > max_chars {
        out.push('…');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn excerpt_truncates_and_ellipsizes() {
        let long = "a".repeat(500);
        let ex = excerpt(&long, 400);
        assert_eq!(ex.chars().count(), 401);
        assert!(ex.ends_with('…'));
    }
}
