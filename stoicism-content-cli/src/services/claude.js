import Anthropic from '@anthropic-ai/sdk';
import { config, assertConfigured } from '../config.js';

let client;
function getClient() {
  assertConfigured(['anthropicApiKey']);
  if (!client) client = new Anthropic({ apiKey: config.anthropicApiKey });
  return client;
}

function extractJson(text) {
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  const candidate = fenced ? fenced[1] : text;
  const objStart = candidate.indexOf('{');
  const arrStart = candidate.indexOf('[');
  const starts = [objStart, arrStart].filter((i) => i >= 0);
  const from = starts.length ? Math.min(...starts) : -1;
  return JSON.parse(from >= 0 ? candidate.slice(from) : candidate);
}

export async function askText(system, user, { maxTokens = 2000 } = {}) {
  const anthropic = getClient();
  let response;
  try {
    response = await anthropic.messages.create({
      model: config.anthropicModel,
      max_tokens: maxTokens,
      system,
      messages: [{ role: 'user', content: user }],
    });
  } catch (err) {
    throw new Error(`Claude API request failed: ${err.message}`);
  }
  return response.content.map((block) => (block.type === 'text' ? block.text : '')).join('');
}

export async function askJson(system, user, opts = {}) {
  const text = await askText(system, `${user}\n\nRespond with ONLY valid JSON — no prose, no markdown code fences.`, opts);
  try {
    return extractJson(text);
  } catch (err) {
    throw new Error(`Claude returned unparseable JSON (${err.message}). Raw response (truncated):\n${text.slice(0, 500)}`);
  }
}
