import fs from 'node:fs';
import path from 'node:path';
import { config, assertConfigured } from '../config.js';
import { log } from '../logger.js';
import { chunkTextForTts } from '../utils.js';

const BASE_URL = 'https://api.elevenlabs.io/v1';

// ElevenLabs caps request text length, so long-form scripts (deep-dive,
// 60+ minute reflections) are split on sentence boundaries and synthesized
// as sequential chunks, later concatenated by the ffmpeg service.
export async function synthesizeVoiceover(script, outputDir) {
  assertConfigured(['elevenLabsApiKey']);
  const chunks = chunkTextForTts(script, 4500);
  log.info(`Synthesizing voiceover in ${chunks.length} chunk(s) via ElevenLabs voice ${config.elevenLabsVoiceId}...`);

  const chunkDir = path.join(outputDir, 'audio_chunks');
  fs.mkdirSync(chunkDir, { recursive: true });

  const chunkFiles = [];
  for (let i = 0; i < chunks.length; i++) {
    const filePath = path.join(chunkDir, `chunk_${String(i + 1).padStart(3, '0')}.mp3`);
    await synthesizeChunk(chunks[i], filePath, i + 1, chunks.length);
    chunkFiles.push(filePath);
  }

  log.success(`Voiceover audio generated: ${chunkFiles.length} chunk(s).`);
  return chunkFiles;
}

async function synthesizeChunk(text, filePath, index, total) {
  const url = `${BASE_URL}/text-to-speech/${config.elevenLabsVoiceId}`;
  let response;
  try {
    response = await fetch(url, {
      method: 'POST',
      headers: {
        'xi-api-key': config.elevenLabsApiKey,
        'Content-Type': 'application/json',
        Accept: 'audio/mpeg',
      },
      body: JSON.stringify({
        text,
        model_id: 'eleven_multilingual_v2',
        voice_settings: { stability: 0.45, similarity_boost: 0.75, style: 0.35, use_speaker_boost: true },
      }),
    });
  } catch (err) {
    throw new Error(`Network error calling ElevenLabs (chunk ${index}/${total}): ${err.message}`);
  }

  if (!response.ok) {
    const body = await response.text().catch(() => '');
    throw new Error(`ElevenLabs API error ${response.status} on chunk ${index}/${total}: ${body.slice(0, 300)}`);
  }

  const buffer = Buffer.from(await response.arrayBuffer());
  fs.writeFileSync(filePath, buffer);
  log.dim(`  chunk ${index}/${total} -> ${path.basename(filePath)} (${(buffer.length / 1024).toFixed(0)} KB)`);
}
