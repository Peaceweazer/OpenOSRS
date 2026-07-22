import inquirer from 'inquirer';
import chalk from 'chalk';
import { log } from '../logger.js';
import { askJson, askText } from '../services/claude.js';
import { outlinePrompt, sectionPrompt, finalPackagePrompt } from '../prompts.js';
import { FORMATS } from '../formats.js';
import { estimateSeconds, formatTimestamp, wordCount } from '../utils.js';
import { config } from '../config.js';
import { saveState } from '../state.js';

export async function runStage2(state) {
  log.stage(2, 'Complete Asset Production');
  const formatMeta = FORMATS[state.selection.format];

  if (!state.production) {
    state.production = await buildProductionPackage(state.selection, formatMeta);
    saveState(state);
  } else {
    log.info('Reusing previously generated production package.');
  }

  return runApprovalLoop(state, formatMeta);
}

async function buildProductionPackage(selection, formatMeta) {
  const outline = await generateOutline(selection, formatMeta);
  const sections = await generateSections(selection, outline);
  const fullScript = sections.map((s) => s.text).join('\n\n');
  const assetLedger = buildAssetLedger(sections);
  const finalPackage = await generateFinalPackage(selection, formatMeta, fullScript, assetLedger);

  return {
    outline,
    fullScript,
    wordCount: wordCount(fullScript),
    assetLedger: mergeLeonardoIntoLedger(assetLedger, finalPackage.leonardoPrompts),
    metadata: finalPackage.metadata,
    thumbnail: finalPackage.thumbnail,
    leonardoPrompts: finalPackage.leonardoPrompts,
  };
}

async function generateOutline(selection, formatMeta) {
  log.info('Generating script outline...');
  const { system, user } = outlinePrompt(selection, formatMeta);
  const result = await askJson(system, user, { maxTokens: 2000 });
  if (!Array.isArray(result.sections) || !result.sections.length) {
    throw new Error('Claude did not return a usable section outline.');
  }
  return result.sections;
}

async function generateSections(selection, outline) {
  const sections = [];
  let runningScript = '';
  for (let i = 0; i < outline.length; i++) {
    const section = outline[i];
    log.info(`Writing section ${i + 1}/${outline.length}: "${section.title}" (~${section.targetWords} words)...`);
    const previousExcerpt = runningScript ? runningScript.slice(-500) : null;
    const { system, user } = sectionPrompt({ selection, section, previousExcerpt, sectionIndex: i, totalSections: outline.length });
    const maxTokens = Math.min(8000, Math.ceil((section.targetWords || 200) * 2.2) + 200);
    const text = (await askText(system, user, { maxTokens })).trim();
    runningScript += (runningScript ? '\n\n' : '') + text;
    sections.push({ ...section, text });
    log.dim(`  -> ${wordCount(text)} words generated.`);
  }
  return sections;
}

function buildAssetLedger(sections) {
  let cursor = 0;
  return sections.map((section, i) => {
    const duration = Math.max(estimateSeconds(section.text, config.wordsPerMinute), 3);
    const startSeconds = cursor;
    const endSeconds = cursor + duration;
    cursor = endSeconds;
    return {
      image: `Image_${String(i + 1).padStart(2, '0')}.png`,
      startSeconds,
      endSeconds,
      startLabel: formatTimestamp(startSeconds),
      endLabel: formatTimestamp(endSeconds),
      sceneDescription: section.sceneDescription,
      leonardoPromptSeed: section.leonardoPromptSeed,
    };
  });
}

async function generateFinalPackage(selection, formatMeta, fullScript, assetLedger) {
  log.info('Generating metadata, thumbnail concept, and Leonardo AI prompts...');
  const { system, user } = finalPackagePrompt({ selection, formatMeta, fullScript, assetLedger });
  const result = await askJson(system, user, { maxTokens: 4000 });
  if (!result.metadata || !result.thumbnail || !Array.isArray(result.leonardoPrompts)) {
    throw new Error('Claude did not return a complete production package (metadata/thumbnail/leonardoPrompts).');
  }
  return result;
}

function mergeLeonardoIntoLedger(assetLedger, leonardoPrompts) {
  const byImage = new Map(leonardoPrompts.map((p) => [p.image, p]));
  return assetLedger.map((asset) => ({ ...asset, leonardo: byImage.get(asset.image) || null }));
}

function presentProductionPackage(production, selection) {
  console.log();
  log.divider();
  log.heading(`Script — "${selection.title}"`);
  console.log(chalk.gray(`${production.wordCount} words · est. ${formatTimestamp(estimateSeconds(production.fullScript, config.wordsPerMinute))} narrated`));
  console.log(`${production.fullScript.slice(0, 400)}${production.fullScript.length > 400 ? '...' : ''}`);

  log.divider();
  log.heading('Metadata');
  console.log(chalk.bold('YouTube Title: ') + production.metadata.youtubeTitle);
  console.log(chalk.bold('Description: ') + production.metadata.description);
  console.log(chalk.bold('Tags: ') + production.metadata.tags.join(', '));
  console.log(chalk.bold('IG Caption: ') + production.metadata.instagramCaption);
  console.log(chalk.bold('FB Caption: ') + production.metadata.facebookCaption);
  console.log(chalk.bold('TikTok Caption: ') + production.metadata.tiktokCaption);
  console.log(chalk.bold('Hashtags: ') + production.metadata.hashtags.join(' '));

  log.divider();
  log.heading('Thumbnail Concept');
  console.log(chalk.bold('Text Overlay: ') + production.thumbnail.textOverlay);
  console.log(chalk.bold('Composition: ') + production.thumbnail.composition);
  console.log(chalk.bold('Colors: ') + production.thumbnail.colors.map((c) => `${c.hex} (${c.label})`).join(', '));

  log.divider();
  log.heading('Visual Asset Ledger + Leonardo AI Prompts');
  for (const asset of production.assetLedger) {
    console.log(chalk.bold(`${asset.image}  [${asset.startLabel}-${asset.endLabel}]`));
    console.log(`  scene: ${asset.sceneDescription}`);
    if (asset.leonardo) {
      console.log(`  ${asset.leonardo.assetType === 'reuse' ? chalk.yellow('REUSE') : chalk.green('NEW')}: ${asset.leonardo.prompt}`);
      if (asset.leonardo.reuseNote) console.log(chalk.gray(`  reuse note: ${asset.leonardo.reuseNote}`));
    }
  }
  log.divider();
  console.log();
}

async function runApprovalLoop(state, formatMeta) {
  for (;;) {
    presentProductionPackage(state.production, state.selection);

    const { action } = await inquirer.prompt([
      {
        type: 'list',
        name: 'action',
        message: 'Approve this production package?',
        choices: [
          { name: 'Approve and continue to Stage 3 (voiceover + video assembly)', value: 'approve' },
          { name: 'Edit metadata (title/description/tags)', value: 'edit' },
          { name: 'Regenerate the entire script + package', value: 'regenerate' },
          { name: 'Exit', value: 'exit' },
        ],
      },
    ]);

    if (action === 'exit') {
      log.info('Exiting. Re-run the CLI to resume at Stage 2.');
      process.exit(0);
    }

    if (action === 'regenerate') {
      state.production = await buildProductionPackage(state.selection, formatMeta);
      saveState(state);
      continue;
    }

    if (action === 'edit') {
      await editMetadata(state.production);
      saveState(state);
      continue;
    }

    state.stage = 3;
    saveState(state);
    log.success('Production package approved.');
    return state;
  }
}

async function editMetadata(production) {
  const answers = await inquirer.prompt([
    { type: 'input', name: 'youtubeTitle', message: 'YouTube title:', default: production.metadata.youtubeTitle },
    { type: 'input', name: 'description', message: 'Description:', default: production.metadata.description },
    { type: 'input', name: 'tags', message: 'Tags (comma-separated):', default: production.metadata.tags.join(', ') },
  ]);
  production.metadata.youtubeTitle = answers.youtubeTitle;
  production.metadata.description = answers.description;
  production.metadata.tags = answers.tags.split(',').map((t) => t.trim()).filter(Boolean);
  log.success('Metadata updated.');
}
