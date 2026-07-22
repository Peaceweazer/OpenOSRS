export const BRAND_VOICE =
  'You are a master content strategist and philosophical writer for a faceless YouTube channel about Stoicism. ' +
  'Your tone is deep, contemplative, cinematic, and grounded in the actual texts of Marcus Aurelius, Seneca, and ' +
  'Epictetus — never cheesy, never generic self-help fluff. You write for viewers seeking calm, resilience, and ' +
  'hard-won wisdom.';

export function conceptGenerationPrompt(analysis) {
  const breakoutSummary = analysis.breakouts
    .slice(0, 8)
    .map(
      (b, i) =>
        `${i + 1}. "${b.title}" — ${b.views.toLocaleString()} views, ${b.subscribers.toLocaleString()} subs, ` +
        `breakout score ${b.breakoutScore.toFixed(2)} (velocity ${b.viewVelocity ? Math.round(b.viewVelocity) : 'n/a'}/day, ` +
        `views:subs ratio ${b.subscriberRatio ? b.subscriberRatio.toFixed(1) : 'n/a'}x)`
    )
    .join('\n');
  const topicSummary = analysis.topicClusters.slice(0, 10).map((t) => `${t.keyword} (${t.score})`).join(', ');

  const user = `Here is the breakout-video analysis from our competitor intelligence spreadsheet (${analysis.totalRows} videos analyzed):

TOP BREAKOUT VIDEOS (disproportionate views relative to channel size / upload age):
${breakoutSummary || 'No statistically significant breakouts detected — lean on the topic clusters below instead.'}

RECURRING HIGH-PERFORMING TOPIC KEYWORDS:
${topicSummary || 'none detected'}

Propose exactly 4 content concepts for our channel, one per format:
1. "short" — 60-120 second Short
2. "listicle" — 5-15 minute listicle long-form video
3. "deep_dive" — 15-30 minute deep-dive long-form video
4. "reflection" — 60+ minute night-time reflection / sleep video

For each concept return:
- format (one of: short, listicle, deep_dive, reflection)
- topic (a specific, non-generic Stoic theme, not just "stoicism")
- dataJustification (2-3 sentences citing the specific breakout numbers or keyword frequencies above that justify this bet)
- titles: array of exactly 3 high-CTR, SEO-optimized YouTube title variations
- hooks: array of exactly 3 opening-line hook variations (first 5-10 spoken seconds) optimized for retention

Return JSON: { "concepts": [ {format, topic, dataJustification, titles, hooks}, ... 4 items, one per format above ... ] }`;

  return { system: BRAND_VOICE, user };
}

export function outlinePrompt(selection, formatMeta) {
  const user = `We are producing a ${formatMeta.label} (${formatMeta.durationLabel}) titled "${selection.title}" on the topic "${selection.topic}".
Chosen hook: "${selection.hook}"
Data justification for this bet: ${selection.dataJustification}

Break the full narration into ${formatMeta.sectionCount} sequential scenes/sections that together read as one continuous cinematic Stoic script (section boundaries are structural only — nothing is spoken aloud as a heading). Total target length: ~${formatMeta.wordTarget} words.

For each section return:
- title (short internal label only, never spoken)
- targetWords (roughly proportional, summing close to ${formatMeta.wordTarget})
- sceneDescription (what the visual should show during this section, for the image artist)
- leonardoPromptSeed (a short seed idea for the image: subject, setting, mood)

Return JSON: { "sections": [ {title, targetWords, sceneDescription, leonardoPromptSeed}, ... ] }`;
  return { system: BRAND_VOICE, user };
}

export function sectionPrompt({ selection, section, previousExcerpt, sectionIndex, totalSections }) {
  const continuation = previousExcerpt
    ? `The script so far ends with:\n"...${previousExcerpt}"\n\nContinue directly from there, in the same voice, with no repeated recap and no section heading.`
    : `This is the opening section. Begin with this hook, verbatim or near-verbatim: "${selection.hook}"`;

  const user = `Continue writing the cinematic Stoic script for "${selection.title}" (topic: ${selection.topic}).
This is section ${sectionIndex + 1} of ${totalSections}: "${section.title}".
Scene focus: ${section.sceneDescription}
Target length: approximately ${section.targetWords} words.
${continuation}

Write ONLY the spoken narration text for this section — no headers, no stage directions, no bracketed notes. Deep, literary, second-person-or-universal Stoic voice.`;
  return { system: BRAND_VOICE, user };
}

export function finalPackagePrompt({ selection, formatMeta, fullScript, assetLedger }) {
  const ledgerSummary = assetLedger
    .map((a) => `${a.image} [${a.startLabel}-${a.endLabel}]: ${a.sceneDescription} (seed: ${a.leonardoPromptSeed})`)
    .join('\n');

  const truncated = fullScript.length > 6000;
  const scriptExcerpt = truncated
    ? `${fullScript.slice(0, 3000)}\n...[middle omitted for prompt length]...\n${fullScript.slice(-3000)}`
    : fullScript;

  const user = `Here is the finished script for our ${formatMeta.label} "${selection.title}" (topic: ${selection.topic}, full length ${fullScript.length} characters):

"""
${scriptExcerpt}
"""

Visual asset ledger (scene -> image slot, already fixed and must be honored in order):
${ledgerSummary}

Produce the full production package:
1. metadata: { youtubeTitle, description (SEO-optimized, 150-300 words), tags (array of 15-20), instagramCaption, facebookCaption, tiktokCaption, hashtags (array of 15) }
2. thumbnail: { textOverlay (short punchy phrase), composition (1-2 sentence visual layout description), colors (array of 4-6 objects {hex, label}) }
3. leonardoPrompts: exactly one entry per line in the asset ledger above, in the same order: { image (matching filename exactly), prompt (detailed cinematic/photorealistic Leonardo AI prompt including lighting, lens, mood and style keywords), assetType ("new" or "reuse"), reuseNote (if "reuse", name the recurring visual theme/motif from prior Stoicism videos this should match; empty string if "new") }

Return JSON: { "metadata": {...}, "thumbnail": {...}, "leonardoPrompts": [...] }`;

  return { system: BRAND_VOICE, user };
}
