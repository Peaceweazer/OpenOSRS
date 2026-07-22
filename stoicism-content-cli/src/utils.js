export function slugify(text) {
  return String(text)
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/(^-|-$)+/g, '')
    .slice(0, 80) || 'untitled';
}

export function wordCount(text) {
  return text.trim().split(/\s+/).filter(Boolean).length;
}

export function estimateSeconds(text, wpm) {
  return Math.round((wordCount(text) / wpm) * 60);
}

export function formatTimestamp(totalSeconds) {
  const s = Math.max(0, Math.round(totalSeconds));
  const m = Math.floor(s / 60);
  const sec = s % 60;
  return `${m}:${String(sec).padStart(2, '0')}`;
}

// Splits narration text into TTS-safe chunks on sentence boundaries, never
// exceeding maxChars — ElevenLabs enforces a per-request character cap.
export function chunkTextForTts(text, maxChars = 4500) {
  const sentences = text.split(/(?<=[.!?])\s+/);
  const chunks = [];
  let current = '';
  for (const sentence of sentences) {
    const candidate = current ? `${current} ${sentence}` : sentence;
    if (candidate.length > maxChars && current) {
      chunks.push(current.trim());
      current = sentence;
    } else {
      current = candidate;
    }
  }
  if (current.trim()) chunks.push(current.trim());
  return chunks;
}
