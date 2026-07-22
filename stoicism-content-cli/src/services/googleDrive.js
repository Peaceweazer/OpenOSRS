import { google } from 'googleapis';
import xlsx from 'xlsx';
import { config } from '../config.js';
import { log } from '../logger.js';

const SCOPES = [
  'https://www.googleapis.com/auth/drive.readonly',
  'https://www.googleapis.com/auth/spreadsheets.readonly',
];

async function getAuthClient() {
  if (!config.googleCredentialsPath) {
    throw new Error(
      'GOOGLE_APPLICATION_CREDENTIALS is not set. Point it at a Google Cloud service-account JSON key that has been shared (Viewer) on the target spreadsheet.'
    );
  }
  const auth = new google.auth.GoogleAuth({ keyFile: config.googleCredentialsPath, scopes: SCOPES });
  try {
    return await auth.getClient();
  } catch (err) {
    throw new Error(`Failed to authenticate with Google (${err.message}). Verify GOOGLE_APPLICATION_CREDENTIALS points at a valid service-account key.`);
  }
}

// Locates the "MMS Competitor Intelligence" spreadsheet on Drive and returns
// its rows as plain objects keyed by header. Handles both native Google
// Sheets and uploaded .xlsx files transparently.
export async function fetchCompetitorSpreadsheet() {
  const authClient = await getAuthClient();
  const drive = google.drive({ version: 'v3', auth: authClient });
  const sheets = google.sheets({ version: 'v4', auth: authClient });

  let searchResult;
  try {
    searchResult = await drive.files.list({
      q: `name = '${config.spreadsheetName.replace(/'/g, "\\'")}' and trashed = false`,
      fields: 'files(id, name, mimeType, modifiedTime)',
      spaces: 'drive',
      pageSize: 5,
    });
  } catch (err) {
    throw new Error(`Google Drive search failed: ${err.message}`);
  }

  const file = searchResult.data.files?.[0];
  if (!file) {
    throw new Error(
      `Could not find a Drive file named "${config.spreadsheetName}". Verify the name and that the service account has been shared access to it.`
    );
  }
  log.success(`Located spreadsheet "${file.name}" (modified ${file.modifiedTime}).`);

  let rows;
  try {
    rows =
      file.mimeType === 'application/vnd.google-apps.spreadsheet'
        ? await readGoogleNativeSheet(sheets, file.id)
        : await readUploadedWorkbook(drive, file.id);
  } catch (err) {
    throw new Error(`Failed to read spreadsheet contents: ${err.message}`);
  }

  return { fileId: file.id, fileName: file.name, modifiedTime: file.modifiedTime, rows };
}

async function readGoogleNativeSheet(sheets, fileId) {
  const meta = await sheets.spreadsheets.get({ spreadsheetId: fileId });
  const firstTab = meta.data.sheets?.[0]?.properties?.title || 'Sheet1';
  const values = await sheets.spreadsheets.values.get({
    spreadsheetId: fileId,
    range: `${firstTab}!A1:Z5000`,
  });
  return rowsFromGrid(values.data.values || []);
}

async function readUploadedWorkbook(drive, fileId) {
  const res = await drive.files.get({ fileId, alt: 'media' }, { responseType: 'arraybuffer' });
  const workbook = xlsx.read(Buffer.from(res.data), { type: 'buffer' });
  const firstSheetName = workbook.SheetNames[0];
  const grid = xlsx.utils.sheet_to_json(workbook.Sheets[firstSheetName], { header: 1, raw: false });
  return rowsFromGrid(grid);
}

function rowsFromGrid(grid) {
  if (!grid.length) return [];
  const headers = grid[0].map((h) => String(h ?? '').trim());
  return grid
    .slice(1)
    .filter((row) => row.some((cell) => cell !== undefined && cell !== ''))
    .map((row) => {
      const obj = {};
      headers.forEach((header, i) => {
        obj[header] = row[i];
      });
      return obj;
    });
}
