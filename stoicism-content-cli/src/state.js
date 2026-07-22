import fs from 'node:fs';
import path from 'node:path';
import { config } from './config.js';
import { log } from './logger.js';

const STATE_PATH = path.resolve(process.cwd(), config.stateFile);

export function defaultState() {
  const now = new Date().toISOString();
  return {
    version: 1,
    stage: 1,
    createdAt: now,
    updatedAt: now,
    analysis: null,
    concepts: null,
    selection: null,
    production: null,
    execution: null,
  };
}

export function loadState() {
  if (!fs.existsSync(STATE_PATH)) return defaultState();
  try {
    const raw = fs.readFileSync(STATE_PATH, 'utf-8');
    const state = JSON.parse(raw);
    log.info(`Resuming from ${config.stateFile} — currently at Stage ${state.stage}.`);
    return state;
  } catch (err) {
    log.warn(`Could not parse ${config.stateFile} (${err.message}). Starting fresh.`);
    return defaultState();
  }
}

export function saveState(state) {
  state.updatedAt = new Date().toISOString();
  fs.writeFileSync(STATE_PATH, JSON.stringify(state, null, 2), 'utf-8');
}
