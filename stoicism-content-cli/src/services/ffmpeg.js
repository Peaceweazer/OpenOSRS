import fs from 'node:fs';
import path from 'node:path';
import { execFile } from 'node:child_process';
import ffmpeg from 'fluent-ffmpeg';
import { log } from '../logger.js';

export function ffmpegAvailable() {
  return new Promise((resolve) => {
    execFile('ffmpeg', ['-version'], (err) => resolve(!err));
  });
}

export function probeDuration(filePath) {
  return new Promise((resolve, reject) => {
    ffmpeg.ffprobe(filePath, (err, data) => {
      if (err) return reject(new Error(`ffprobe failed on ${filePath}: ${err.message}`));
      resolve(data.format.duration);
    });
  });
}

export function concatAudioChunks(chunkFiles, outputPath) {
  return new Promise((resolve, reject) => {
    if (chunkFiles.length === 1) {
      fs.copyFileSync(chunkFiles[0], outputPath);
      return resolve(outputPath);
    }
    const listPath = `${outputPath}.concat.txt`;
    fs.writeFileSync(listPath, chunkFiles.map((f) => `file '${escapeForConcat(f)}'`).join('\n'));
    ffmpeg()
      .input(listPath)
      .inputOptions(['-f concat', '-safe 0'])
      .outputOptions(['-c copy'])
      .save(outputPath)
      .on('end', () => {
        fs.unlinkSync(listPath);
        resolve(outputPath);
      })
      .on('error', (err) => reject(new Error(`Failed to concatenate audio chunks: ${err.message}`)));
  });
}

function escapeForConcat(filePath) {
  return path.resolve(filePath).replace(/'/g, "'\\''");
}

// Four alternating pan/zoom variants keep a long sequence of static images
// visually varied instead of every clip zooming toward dead-center.
const PAN_VARIANTS = [
  { name: 'zoom-in-center', x: 'iw/2-(iw/zoom/2)', y: 'ih/2-(ih/zoom/2)' },
  { name: 'pan-right', x: '(iw-iw/zoom)*(on/{FRAMES})', y: 'ih/2-(ih/zoom/2)' },
  { name: 'pan-left', x: '(iw-iw/zoom)*(1-on/{FRAMES})', y: 'ih/2-(ih/zoom/2)' },
  { name: 'pan-down', x: 'iw/2-(iw/zoom/2)', y: '(ih-ih/zoom)*(on/{FRAMES})' },
];

// Builds a single zoompan filter string implementing a slow Ken Burns
// zoom/pan over `durationSeconds`. Using d=1 with an `on`-indexed zoom
// expression (rather than d=<frames>) avoids the well-known zoompan
// "reset/jump" artifact that occurs when animating a single looped image.
export function buildKenBurnsFilter(index, durationSeconds, fps, resolution) {
  const [w, h] = resolution.split('x').map(Number);
  const frames = Math.max(Math.round(durationSeconds * fps), 1);
  const variant = PAN_VARIANTS[index % PAN_VARIANTS.length];
  const zoomExpr = `if(eq(on,0),1,min(zoom+0.0012,1.4))`;
  const xExpr = variant.x.replace('{FRAMES}', frames);
  const yExpr = variant.y.replace('{FRAMES}', frames);
  const filter =
    `scale=${w * 2}:${h * 2}:force_original_aspect_ratio=increase,` +
    `crop=${w * 2}:${h * 2},` +
    `zoompan=z='${zoomExpr}':x='${xExpr}':y='${yExpr}':d=1:s=${w}x${h}:fps=${fps},` +
    `format=yuv420p`;
  return { frames, variant: variant.name, filter };
}

export function renderKenBurnsClip(imagePath, durationSeconds, outputPath, opts = {}) {
  const fps = opts.fps || 25;
  const resolution = opts.resolution || '1920x1080';
  const index = opts.index || 0;
  const { filter } = buildKenBurnsFilter(index, durationSeconds, fps, resolution);

  return new Promise((resolve, reject) => {
    ffmpeg(imagePath)
      .inputOptions([`-loop 1`, `-framerate ${fps}`])
      .videoFilters(filter)
      .outputOptions([`-t ${durationSeconds.toFixed(2)}`, '-c:v libx264', '-pix_fmt yuv420p'])
      .save(outputPath)
      .on('end', () => resolve(outputPath))
      .on('error', (err) => reject(new Error(`Ken Burns render failed for ${path.basename(imagePath)}: ${err.message}`)));
  });
}

export function concatClips(clipFiles, outputPath) {
  return new Promise((resolve, reject) => {
    const listPath = `${outputPath}.concat.txt`;
    fs.writeFileSync(listPath, clipFiles.map((f) => `file '${escapeForConcat(f)}'`).join('\n'));
    ffmpeg()
      .input(listPath)
      .inputOptions(['-f concat', '-safe 0'])
      .outputOptions(['-c copy'])
      .save(outputPath)
      .on('end', () => {
        fs.unlinkSync(listPath);
        resolve(outputPath);
      })
      .on('error', (err) => reject(new Error(`Failed to concatenate video clips: ${err.message}`)));
  });
}

export function muxAudioVideo(videoPath, audioPath, outputPath) {
  return new Promise((resolve, reject) => {
    ffmpeg()
      .input(videoPath)
      .input(audioPath)
      .outputOptions(['-map 0:v:0', '-map 1:a:0', '-c:v copy', '-c:a aac', '-shortest'])
      .save(outputPath)
      .on('end', () => resolve(outputPath))
      .on('error', (err) => reject(new Error(`Final mux failed: ${err.message}`)));
  });
}

// Full pipeline: rescale the script-estimated scene durations to match the
// actual ElevenLabs audio length, render each image as a Ken Burns clip,
// concat, then mux against the voiceover.
export async function assembleVideo({ projectDir, assetLedger, audioPath, resolution = '1920x1080', fps = 25 }) {
  const imagesDir = path.join(projectDir, 'images');
  const clipsDir = path.join(projectDir, 'clips');
  fs.mkdirSync(clipsDir, { recursive: true });

  const audioDuration = await probeDuration(audioPath);
  const scriptDuration = assetLedger.reduce((sum, a) => sum + (a.endSeconds - a.startSeconds), 0);
  const scale = scriptDuration > 0 ? audioDuration / scriptDuration : 1;

  const clipFiles = [];
  for (let i = 0; i < assetLedger.length; i++) {
    const asset = assetLedger[i];
    const imagePath = path.join(imagesDir, asset.image);
    if (!fs.existsSync(imagePath)) {
      throw new Error(`Missing image asset: ${imagePath}. Place all Leonardo AI renders in ${imagesDir} before assembly.`);
    }
    const duration = Math.max((asset.endSeconds - asset.startSeconds) * scale, 0.5);
    const clipPath = path.join(clipsDir, `clip_${String(i + 1).padStart(3, '0')}.mp4`);
    log.dim(`  rendering ${asset.image} (${duration.toFixed(1)}s, ${PAN_VARIANTS[i % PAN_VARIANTS.length].name})...`);
    await renderKenBurnsClip(imagePath, duration, clipPath, { index: i, fps, resolution });
    clipFiles.push(clipPath);
  }

  const silentVideo = path.join(projectDir, 'silent_video.mp4');
  await concatClips(clipFiles, silentVideo);

  const finalVideo = path.join(projectDir, 'final_video.mp4');
  await muxAudioVideo(silentVideo, audioPath, finalVideo);

  return finalVideo;
}

// Emits portable assemble.sh / assemble.bat (raw ffmpeg CLI, no Node
// required) and assemble.js (fluent-ffmpeg, re-invokes assembleVideo above)
// so the two-pass render/concat/mux pipeline can be re-run standalone once
// Leonardo AI images have been dropped into the project's images/ folder.
export function generateStandaloneScripts(projectDir, assetLedger, { resolution = '1920x1080', fps = 25 } = {}) {
  const shPath = path.join(projectDir, 'assemble.sh');
  const batPath = path.join(projectDir, 'assemble.bat');
  const jsPath = path.join(projectDir, 'assemble.js');

  fs.writeFileSync(shPath, buildShScript(assetLedger, resolution, fps), { mode: 0o755 });
  fs.writeFileSync(batPath, buildBatScript(assetLedger, resolution, fps));
  fs.writeFileSync(jsPath, buildNodeScript(assetLedger, resolution, fps));

  return { sh: shPath, bat: batPath, js: jsPath };
}

function clipFilterString(index, durationSeconds, resolution, fps) {
  return buildKenBurnsFilter(index, durationSeconds, fps, resolution).filter;
}

function buildShScript(assetLedger, resolution, fps) {
  const lines = ['#!/usr/bin/env bash', 'set -euo pipefail', '', 'mkdir -p clips', ''];
  assetLedger.forEach((asset, i) => {
    const duration = Math.max(asset.endSeconds - asset.startSeconds, 0.5);
    const filter = clipFilterString(i, duration, resolution, fps);
    const clip = `clips/clip_${String(i + 1).padStart(3, '0')}.mp4`;
    lines.push(`echo "Rendering ${asset.image} (${duration.toFixed(1)}s)..."`);
    lines.push(
      `ffmpeg -y -loop 1 -framerate ${fps} -i "images/${asset.image}" -vf "${filter}" -t ${duration.toFixed(2)} -c:v libx264 -pix_fmt yuv420p "${clip}"`
    );
    lines.push('');
  });
  lines.push('echo "Concatenating clips..."');
  lines.push('{');
  assetLedger.forEach((_, i) => lines.push(`  echo "file 'clips/clip_${String(i + 1).padStart(3, '0')}.mp4'"`));
  lines.push('} > clips.txt');
  lines.push('ffmpeg -y -f concat -safe 0 -i clips.txt -c copy silent_video.mp4');
  lines.push('');
  lines.push('echo "Muxing with voiceover.mp3..."');
  lines.push('ffmpeg -y -i silent_video.mp4 -i voiceover.mp3 -map 0:v:0 -map 1:a:0 -c:v copy -c:a aac -shortest final_video.mp4');
  lines.push('echo "Done: final_video.mp4"');
  return `${lines.join('\n')}\n`;
}

function buildBatScript(assetLedger, resolution, fps) {
  const lines = ['@echo off', 'setlocal enabledelayedexpansion', 'mkdir clips 2>nul', ''];
  assetLedger.forEach((asset, i) => {
    const duration = Math.max(asset.endSeconds - asset.startSeconds, 0.5);
    const filter = clipFilterString(i, duration, resolution, fps);
    const clip = `clips\\clip_${String(i + 1).padStart(3, '0')}.mp4`;
    lines.push(`echo Rendering ${asset.image}...`);
    lines.push(
      `ffmpeg -y -loop 1 -framerate ${fps} -i "images\\${asset.image}" -vf "${filter}" -t ${duration.toFixed(2)} -c:v libx264 -pix_fmt yuv420p "${clip}"`
    );
  });
  lines.push('');
  lines.push('(');
  assetLedger.forEach((_, i) => lines.push(`  echo file 'clips/clip_${String(i + 1).padStart(3, '0')}.mp4'`));
  lines.push(') > clips.txt');
  lines.push('ffmpeg -y -f concat -safe 0 -i clips.txt -c copy silent_video.mp4');
  lines.push('ffmpeg -y -i silent_video.mp4 -i voiceover.mp3 -map 0:v:0 -map 1:a:0 -c:v copy -c:a aac -shortest final_video.mp4');
  lines.push('echo Done: final_video.mp4');
  return `${lines.join('\r\n')}\r\n`;
}

function buildNodeScript(assetLedger, resolution, fps) {
  return `// Standalone runner: node assemble.js
// Re-renders the Ken Burns clips from images/ and muxes them with voiceover.mp3.
// Requires the CLI's node_modules (fluent-ffmpeg) to be reachable from here.
import path from 'node:path';
import { assembleVideo } from '../../src/services/ffmpeg.js';

const assetLedger = ${JSON.stringify(assetLedger, null, 2)};

assembleVideo({
  projectDir: path.resolve('.'),
  assetLedger,
  audioPath: path.resolve('./voiceover.mp3'),
  resolution: '${resolution}',
  fps: ${fps},
})
  .then((finalVideo) => console.log('Final video:', finalVideo))
  .catch((err) => {
    console.error('Assembly failed:', err.message);
    process.exit(1);
  });
`;
}
