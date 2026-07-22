import { log } from '../logger.js';

const COLUMN_ALIASES = {
  title: ['video title', 'title', 'topic', 'video'],
  channel: ['channel', 'channel name'],
  views: ['views', 'view count'],
  subscribers: ['subscribers', 'subscriber count', 'subs'],
  uploadDate: ['upload date', 'published', 'publish date', 'date'],
};

const STOPWORDS = new Set([
  'the', 'a', 'an', 'of', 'to', 'and', 'in', 'on', 'for', 'with', 'is', 'are',
  'how', 'why', 'your', 'you', 'this', 'that', 'it', 'as', 'at', 'from', 'be', 'my',
]);

function findKey(row, aliases) {
  const keys = Object.keys(row);
  const exact = keys.find((k) => aliases.includes(k.toLowerCase().trim()));
  if (exact) return exact;
  return keys.find((k) => aliases.some((a) => k.toLowerCase().includes(a)));
}

function toNumber(value) {
  if (value === undefined || value === null || value === '') return NaN;
  const cleaned = String(value).replace(/[,%\s]/g, '');
  const num = Number(cleaned);
  return Number.isFinite(num) ? num : NaN;
}

function toDate(value) {
  if (!value) return null;
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? null : d;
}

function mean(nums) {
  return nums.length ? nums.reduce((a, b) => a + b, 0) / nums.length : 0;
}

function stdDev(nums, avg) {
  if (!nums.length) return 1;
  const variance = nums.reduce((a, b) => a + (b - avg) ** 2, 0) / nums.length;
  return Math.sqrt(variance) || 1;
}

// Detects "breakout" videos — those with disproportionate view velocity or
// views-to-subscriber ratio relative to the dataset — and surfaces recurring
// high-performing topic keywords to seed Stage 1 content concepts.
export function analyzeCompetitorData(rawRows) {
  if (!rawRows.length) throw new Error('Spreadsheet contained no data rows.');

  const sample = rawRows[0];
  const cols = {
    title: findKey(sample, COLUMN_ALIASES.title),
    channel: findKey(sample, COLUMN_ALIASES.channel),
    views: findKey(sample, COLUMN_ALIASES.views),
    subscribers: findKey(sample, COLUMN_ALIASES.subscribers),
    uploadDate: findKey(sample, COLUMN_ALIASES.uploadDate),
  };

  const missing = Object.entries(cols).filter(([, v]) => !v).map(([k]) => k);
  if (missing.length) {
    log.warn(`Could not confidently map columns: ${missing.join(', ')}. Detected headers: ${Object.keys(sample).join(', ')}`);
  }

  const now = Date.now();
  const metrics = rawRows.map((row) => {
    const views = toNumber(row[cols.views]);
    const subscribers = toNumber(row[cols.subscribers]);
    const uploadDate = toDate(row[cols.uploadDate]);
    const daysLive = uploadDate ? Math.max((now - uploadDate.getTime()) / 86_400_000, 1) : null;
    const safeViews = Number.isFinite(views) ? views : 0;
    const safeSubs = Number.isFinite(subscribers) ? subscribers : 0;
    return {
      title: cols.title && row[cols.title] ? String(row[cols.title]) : 'Untitled',
      channel: cols.channel ? row[cols.channel] : undefined,
      views: safeViews,
      subscribers: safeSubs,
      uploadDate,
      daysLive,
      viewVelocity: daysLive ? safeViews / daysLive : null,
      subscriberRatio: safeSubs > 0 ? safeViews / safeSubs : null,
    };
  });

  const velocities = metrics.map((m) => m.viewVelocity).filter((v) => v !== null);
  const ratios = metrics.map((m) => m.subscriberRatio).filter((v) => v !== null);
  const velocityMean = mean(velocities);
  const velocityStd = stdDev(velocities, velocityMean);
  const ratioMean = mean(ratios);
  const ratioStd = stdDev(ratios, ratioMean);

  const scored = metrics.map((m) => {
    const zVelocity = m.viewVelocity !== null ? (m.viewVelocity - velocityMean) / velocityStd : 0;
    const zRatio = m.subscriberRatio !== null ? (m.subscriberRatio - ratioMean) / ratioStd : 0;
    const breakoutScore = 0.6 * zVelocity + 0.4 * zRatio;
    return {
      ...m,
      zVelocity,
      zRatio,
      breakoutScore,
      isBreakout: breakoutScore > 1.25 || (m.subscriberRatio ?? 0) > 5,
    };
  });

  const breakouts = scored.filter((m) => m.isBreakout).sort((a, b) => b.breakoutScore - a.breakoutScore);
  const topicClusters = clusterTopics(scored);

  return {
    totalRows: scored.length,
    columns: cols,
    breakouts: breakouts.slice(0, 15),
    topicClusters: topicClusters.slice(0, 10),
  };
}

function clusterTopics(scored) {
  const freq = new Map();
  for (const row of scored) {
    const words = row.title
      .toLowerCase()
      .replace(/[^a-z0-9\s]/g, '')
      .split(/\s+/)
      .filter((w) => w.length > 3 && !STOPWORDS.has(w));
    const weight = Math.max(row.breakoutScore, 0.1);
    for (const w of new Set(words)) {
      freq.set(w, (freq.get(w) || 0) + weight);
    }
  }
  return [...freq.entries()]
    .sort((a, b) => b[1] - a[1])
    .map(([keyword, score]) => ({ keyword, score: Number(score.toFixed(2)) }));
}
