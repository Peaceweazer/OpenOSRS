import 'dotenv/config';

export const config = {
  anthropicApiKey: process.env.ANTHROPIC_API_KEY,
  anthropicModel: process.env.ANTHROPIC_MODEL || 'claude-sonnet-5',

  googleCredentialsPath: process.env.GOOGLE_APPLICATION_CREDENTIALS,
  spreadsheetName: process.env.SPREADSHEET_NAME || 'MMS Competitor Intelligence',

  elevenLabsApiKey: process.env.ELEVENLABS_API_KEY,
  elevenLabsVoiceId: process.env.ELEVENLABS_VOICE_ID || 'ksXT3kwwp9WX9Ff2hdMa',

  outputRoot: process.env.OUTPUT_ROOT || 'output',
  stateFile: process.env.STATE_FILE || 'workflow_state.json',

  wordsPerMinute: Number(process.env.NARRATION_WPM || 150),
  videoResolution: process.env.VIDEO_RESOLUTION || '1920x1080',
  videoFps: Number(process.env.VIDEO_FPS || 25),
};

const KEY_TO_ENV = {
  anthropicApiKey: 'ANTHROPIC_API_KEY',
  elevenLabsApiKey: 'ELEVENLABS_API_KEY',
  googleCredentialsPath: 'GOOGLE_APPLICATION_CREDENTIALS',
};

export function assertConfigured(keys) {
  const missing = keys.filter((k) => !config[k]);
  if (missing.length) {
    const envNames = missing.map((k) => KEY_TO_ENV[k] || k).join(', ');
    throw new Error(`Missing required configuration: ${envNames}. Set it in your .env file (see .env.example).`);
  }
}
