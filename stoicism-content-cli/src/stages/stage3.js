import fs from 'node:fs';
import path from 'node:path';
import inquirer from 'inquirer';
import { log } from '../logger.js';
import { config } from '../config.js';
import { slugify } from '../utils.js';
import { synthesizeVoiceover } from '../services/elevenlabs.js';
import { concatAudioChunks, assembleVideo, ffmpegAvailable, generateStandaloneScripts } from '../services/ffmpeg.js';
import { saveState } from '../state.js';

export async function runStage3(state) {
  log.stage(3, 'Automated Execution & Video Assembly');

  const projectSlug = slugify(state.selection.title);
  const projectDir = path.resolve(config.outputRoot, projectSlug);
  fs.mkdirSync(path.join(projectDir, 'images'), { recursive: true });

  writeProjectFiles(projectDir, state);

  let voiceoverPath = state.execution?.voiceoverPath;
  if (!voiceoverPath || !fs.existsSync(voiceoverPath)) {
    const chunkFiles = await synthesizeVoiceover(state.production.fullScript, projectDir);
    voiceoverPath = path.join(projectDir, 'voiceover.mp3');
    await concatAudioChunks(chunkFiles, voiceoverPath);
    log.success(`Voiceover saved: ${voiceoverPath}`);
  } else {
    log.info('Voiceover already generated, skipping ElevenLabs call.');
  }

  const scriptPaths = generateStandaloneScripts(projectDir, state.production.assetLedger, {
    resolution: config.videoResolution,
    fps: config.videoFps,
  });
  log.success(`FFmpeg assembly scripts written: ${path.basename(scriptPaths.sh)}, ${path.basename(scriptPaths.bat)}, ${path.basename(scriptPaths.js)}`);

  state.execution = {
    projectDir,
    voiceoverPath,
    assemblyScripts: scriptPaths,
    videoOutputPath: state.execution?.videoOutputPath || null,
    completedAt: state.execution?.completedAt || null,
  };
  saveState(state);

  const imageCheck = checkImagesPresent(projectDir, state.production.assetLedger);
  if (!imageCheck.allPresent) {
    log.warn(`Missing ${imageCheck.missing.length} image asset(s) in ${path.join(projectDir, 'images')}:`);
    imageCheck.missing.forEach((m) => log.dim(`  - ${m}`));
    log.info('Generate these with Leonardo AI using leonardo_prompts.json, drop them in the images/ folder, then re-run this CLI to finish assembly.');
    state.stage = 'awaiting_images';
    saveState(state);
    return state;
  }

  const hasFfmpeg = await ffmpegAvailable();
  if (!hasFfmpeg) {
    log.warn('ffmpeg binary not found on PATH — skipping automatic assembly. Install ffmpeg, then run assemble.sh/assemble.bat manually inside the project folder.');
    state.stage = 'done';
    saveState(state);
    return state;
  }

  const { runNow } = await inquirer.prompt([
    { type: 'confirm', name: 'runNow', message: 'Images and ffmpeg detected. Assemble final_video.mp4 now?', default: true },
  ]);

  if (runNow) {
    const finalVideo = await assembleVideo({
      projectDir,
      assetLedger: state.production.assetLedger,
      audioPath: voiceoverPath,
      resolution: config.videoResolution,
      fps: config.videoFps,
    });
    state.execution.videoOutputPath = finalVideo;
    state.execution.completedAt = new Date().toISOString();
    log.success(`Final video assembled: ${finalVideo}`);
  } else {
    log.info(`Run ${path.join(projectDir, 'assemble.sh')} (or assemble.bat) whenever you're ready.`);
  }

  state.stage = 'done';
  saveState(state);
  return state;
}

function writeProjectFiles(projectDir, state) {
  fs.writeFileSync(path.join(projectDir, 'script.txt'), state.production.fullScript, 'utf-8');
  fs.writeFileSync(path.join(projectDir, 'metadata.json'), JSON.stringify(state.production.metadata, null, 2));
  fs.writeFileSync(path.join(projectDir, 'thumbnail.json'), JSON.stringify(state.production.thumbnail, null, 2));
  fs.writeFileSync(path.join(projectDir, 'leonardo_prompts.json'), JSON.stringify(state.production.leonardoPrompts, null, 2));
  fs.writeFileSync(path.join(projectDir, 'asset_ledger.json'), JSON.stringify(state.production.assetLedger, null, 2));
  fs.writeFileSync(
    path.join(projectDir, 'project.json'),
    JSON.stringify({ selection: state.selection, production: state.production }, null, 2)
  );
  log.success(`Project files written to ${projectDir}`);
}

function checkImagesPresent(projectDir, assetLedger) {
  const imagesDir = path.join(projectDir, 'images');
  const missing = assetLedger.filter((a) => !fs.existsSync(path.join(imagesDir, a.image))).map((a) => a.image);
  return { allPresent: missing.length === 0, missing };
}
