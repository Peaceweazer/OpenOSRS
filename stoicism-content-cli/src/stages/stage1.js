import inquirer from 'inquirer';
import chalk from 'chalk';
import { log } from '../logger.js';
import { fetchCompetitorSpreadsheet } from '../services/googleDrive.js';
import { analyzeCompetitorData } from '../analysis/breakoutAnalysis.js';
import { askJson } from '../services/claude.js';
import { conceptGenerationPrompt } from '../prompts.js';
import { FORMATS, FORMAT_ORDER } from '../formats.js';
import { saveState } from '../state.js';

export async function runStage1(state) {
  log.stage(1, 'Data Analysis & Content Proposal');

  if (!state.analysis) {
    log.info('Reading "MMS Competitor Intelligence" from Google Drive...');
    const sheet = await fetchCompetitorSpreadsheet();
    log.info(`Analyzing ${sheet.rows.length} rows for breakout performance...`);
    const analysis = analyzeCompetitorData(sheet.rows);
    state.analysis = { fileId: sheet.fileId, fileName: sheet.fileName, ...analysis };
    saveState(state);
    log.success(`Found ${analysis.breakouts.length} breakout video(s) and ${analysis.topicClusters.length} recurring topic keyword(s).`);
  } else {
    log.info('Reusing previously fetched spreadsheet analysis (delete workflow_state.json to refetch).');
  }

  if (!state.concepts) {
    state.concepts = await generateConcepts(state.analysis);
    saveState(state);
  }

  return runSelectionLoop(state);
}

async function generateConcepts(analysis) {
  log.info('Asking Claude to propose 4 tailored content concepts...');
  const { system, user } = conceptGenerationPrompt(analysis);
  const result = await askJson(system, user, { maxTokens: 3000 });
  if (!Array.isArray(result.concepts) || result.concepts.length !== 4) {
    throw new Error('Claude did not return exactly 4 concepts as expected.');
  }
  return result.concepts;
}

function presentConcepts(concepts) {
  console.log();
  for (const concept of concepts) {
    const meta = FORMATS[concept.format] || { label: concept.format };
    log.divider();
    log.heading(`${meta.label}  [${concept.format}]`);
    console.log(chalk.bold('Topic: ') + concept.topic);
    console.log(chalk.bold('Data justification: ') + chalk.italic(concept.dataJustification));
    console.log(chalk.bold('Titles:'));
    concept.titles.forEach((t, i) => console.log(`  ${i + 1}. ${t}`));
    console.log(chalk.bold('Hooks:'));
    concept.hooks.forEach((h, i) => console.log(`  ${i + 1}. ${h}`));
  }
  log.divider();
  console.log();
}

async function runSelectionLoop(state) {
  for (;;) {
    presentConcepts(state.concepts);

    const { action } = await inquirer.prompt([
      {
        type: 'list',
        name: 'action',
        message: 'How would you like to proceed?',
        choices: [
          { name: 'Proceed with one of these concepts', value: 'proceed' },
          { name: 'Tweak a title or hook', value: 'tweak' },
          { name: 'Regenerate all 4 concepts', value: 'regenerate' },
          { name: 'Exit', value: 'exit' },
        ],
      },
    ]);

    if (action === 'exit') {
      log.info('Exiting. Re-run the CLI to resume at Stage 1.');
      process.exit(0);
    }

    if (action === 'regenerate') {
      state.concepts = await generateConcepts(state.analysis);
      saveState(state);
      continue;
    }

    if (action === 'tweak') {
      await tweakConcept(state.concepts);
      saveState(state);
      continue;
    }

    // action === 'proceed'
    const selection = await pickConcept(state.concepts);
    state.selection = selection;
    state.stage = 2;
    saveState(state);
    log.success(`Locked in: ${selection.title} (${FORMATS[selection.format].label})`);
    return state;
  }
}

async function tweakConcept(concepts) {
  const { formatKey } = await inquirer.prompt([
    {
      type: 'list',
      name: 'formatKey',
      message: 'Which concept do you want to tweak?',
      choices: FORMAT_ORDER.map((key) => ({ name: FORMATS[key].label, value: key })),
    },
  ]);
  const concept = concepts.find((c) => c.format === formatKey);

  const { field } = await inquirer.prompt([
    { type: 'list', name: 'field', message: 'Tweak which field?', choices: ['titles', 'hooks'] },
  ]);

  const { index } = await inquirer.prompt([
    {
      type: 'list',
      name: 'index',
      message: `Which ${field.slice(0, -1)} variation?`,
      choices: concept[field].map((v, i) => ({ name: v, value: i })),
    },
  ]);

  const { newValue } = await inquirer.prompt([
    { type: 'input', name: 'newValue', message: `New text for ${field} #${index + 1}:`, default: concept[field][index] },
  ]);
  concept[field][index] = newValue;
  log.success('Updated.');
}

async function pickConcept(concepts) {
  const { formatKey } = await inquirer.prompt([
    {
      type: 'list',
      name: 'formatKey',
      message: 'Which format do you want to produce?',
      choices: FORMAT_ORDER.map((key) => {
        const c = concepts.find((cc) => cc.format === key);
        return { name: `${FORMATS[key].label} — ${c?.titles?.[0] ?? '(no title)'}`, value: key };
      }),
    },
  ]);
  const concept = concepts.find((c) => c.format === formatKey);

  const { title } = await inquirer.prompt([
    {
      type: 'list',
      name: 'title',
      message: 'Choose a title:',
      choices: [...concept.titles.map((t) => ({ name: t, value: t })), { name: '(type a custom title)', value: '__custom__' }],
    },
  ]);
  const finalTitle =
    title === '__custom__'
      ? (await inquirer.prompt([{ type: 'input', name: 'v', message: 'Custom title:' }])).v
      : title;

  const { hook } = await inquirer.prompt([
    {
      type: 'list',
      name: 'hook',
      message: 'Choose a hook:',
      choices: [...concept.hooks.map((h) => ({ name: h, value: h })), { name: '(type a custom hook)', value: '__custom__' }],
    },
  ]);
  const finalHook =
    hook === '__custom__' ? (await inquirer.prompt([{ type: 'input', name: 'v', message: 'Custom hook:' }])).v : hook;

  return {
    format: formatKey,
    topic: concept.topic,
    dataJustification: concept.dataJustification,
    title: finalTitle,
    hook: finalHook,
  };
}
