#!/usr/bin/env node
import { log } from './logger.js';
import { loadState, saveState } from './state.js';
import { runStage1 } from './stages/stage1.js';
import { runStage2 } from './stages/stage2.js';
import { runStage3 } from './stages/stage3.js';

async function main() {
  log.banner('STOICISM CONTENT ENGINE');
  let state = loadState();
  saveState(state);

  try {
    if (state.stage === 1) state = await runStage1(state);
    if (state.stage === 2) state = await runStage2(state);
    if (state.stage === 3 || state.stage === 'awaiting_images') state = await runStage3(state);

    if (state.stage === 'done') {
      log.success('Workflow complete for this concept! Delete workflow_state.json to start a new one.');
    } else if (state.stage === 'awaiting_images') {
      log.warn('Paused — waiting on Leonardo AI image assets. Re-run once they are in place.');
    }
  } catch (err) {
    log.error(err.message);
    if (process.env.DEBUG) console.error(err);
    process.exitCode = 1;
  }
}

main();
