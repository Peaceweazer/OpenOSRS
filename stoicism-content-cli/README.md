# Stoicism Content CLI

A terminal-driven, multi-stage automation pipeline for a faceless Stoicism YouTube
channel. It reads competitor performance data from Google Drive, uses Claude to turn
that data into concrete video concepts and full production packages, generates
voiceover audio with ElevenLabs, and emits an FFmpeg Ken Burns assembly pipeline for
the final video — pausing for your approval at each major decision point.

## Architecture

```
stoicism-content-cli/
├── src/
│   ├── index.js               # Entry point / stage router
│   ├── config.js              # Env-based configuration
│   ├── logger.js               # chalk-based terminal logging
│   ├── state.js                # workflow_state.json persistence (resume support)
│   ├── utils.js                 # slugify, word/duration estimation, TTS chunking
│   ├── formats.js               # The 4 required content formats + word targets
│   ├── prompts.js               # All Claude prompt templates (brand voice + stages)
│   ├── services/
│   │   ├── googleDrive.js       # Drive search + Sheets/xlsx row extraction
│   │   ├── claude.js            # @anthropic-ai/sdk wrapper (text + strict-JSON)
│   │   ├── elevenlabs.js         # Chunked TTS synthesis
│   │   └── ffmpeg.js             # Ken Burns zoompan filter + assembly pipeline
│   ├── analysis/
│   │   └── breakoutAnalysis.js  # Z-score breakout detection + topic clustering
│   └── stages/
│       ├── stage1.js            # Data analysis -> 4 concepts -> approval
│       ├── stage2.js            # Outline -> script -> metadata/thumbnail/Leonardo prompts -> approval
│       └── stage3.js            # Voiceover, project folder, FFmpeg scripts, assembly
├── .env.example
└── package.json
```

Each stage is a pure function of `workflow_state.json` — every side effect (spreadsheet
read, generated concepts, chosen format, full script, generated assets) is written to
that file as soon as it's produced. If the CLI is killed at any point, re-running it
picks up exactly where it left off instead of re-calling any API.

## Setup

```bash
cd stoicism-content-cli
npm install
cp .env.example .env
```

Fill in `.env`:

| Variable | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | Claude API key used for concept/script/metadata generation |
| `ANTHROPIC_MODEL` | Defaults to `claude-sonnet-5` |
| `GOOGLE_APPLICATION_CREDENTIALS` | Path to a Google Cloud **service-account** JSON key |
| `SPREADSHEET_NAME` | Defaults to `MMS Competitor Intelligence` |
| `ELEVENLABS_API_KEY` | ElevenLabs API key |
| `ELEVENLABS_VOICE_ID` | Defaults to `ksXT3kwwp9WX9Ff2hdMa` |

**Google Drive access**: create a service account in Google Cloud Console, download its
JSON key, then share the "MMS Competitor Intelligence" file with the service account's
email address (Viewer is enough). The spreadsheet needs (flexibly-named) columns for
video title, channel, views, subscribers, and upload date.

**FFmpeg**: install the `ffmpeg` binary and make sure it's on `PATH`
(`ffmpeg -version` should work). The CLI still generates the assembly scripts without
it — it just can't run them for you.

## Running

```bash
npm start
```

### Stage 1 — Data Analysis & Content Proposal
Fetches the spreadsheet, scores every row with `0.6·z(view velocity) + 0.4·z(views:subscribers ratio)`
to flag statistical breakouts, clusters recurring topic keywords from breakout titles, then asks
Claude for exactly 4 concepts (short / listicle / deep-dive / reflection), each with a data
justification, 3 titles, and 3 hooks. You then pick a format, a title, and a hook (or type your own),
tweak individual variations, or regenerate all 4.

### Stage 2 — Complete Asset Production
For the chosen concept: Claude first drafts a scene-by-scene **outline** (targeting the format's
word count), then each scene's narration is generated as a separate call so continuity holds across
very long scripts (the 60+ minute reflection format runs ~12 sequential section calls). Scene word
counts become a **visual asset ledger** (`Image_01.png` → `0:00-0:14`, etc.) via a 150 wpm estimate.
A final Claude call — given the full script and the ledger — produces YouTube metadata, IG/FB/TikTok
captions & hashtags, a thumbnail concept (text overlay, composition, hex palette), and one Leonardo AI
prompt per image (flagged `new` vs `reuse` against recurring visual motifs). You approve, edit
metadata inline, or regenerate the whole package.

### Stage 3 — Automated Execution & Video Assembly
1. Writes `output/<slugified-title>/{script.txt, metadata.json, thumbnail.json, leonardo_prompts.json, asset_ledger.json, project.json}`.
2. Sends the full script to ElevenLabs (voice `ksXT3kwwp9WX9Ff2hdMa`), chunking on sentence
   boundaries to stay under the API's per-request character cap, then concatenates the chunks into
   `voiceover.mp3` with ffmpeg's concat demuxer.
3. **This tool does not call a Leonardo AI API** (none was specified in scope) — it generates
   `leonardo_prompts.json` for you to run through Leonardo AI yourself, and expects the resulting
   PNGs to be dropped into `output/<slug>/images/` named exactly as the asset ledger specifies
   (`Image_01.png`, `Image_02.png`, ...).
4. Generates `assemble.sh`, `assemble.bat`, and `assemble.js` inside the project folder — all three
   implement the same two-pass pipeline: render each image into its own Ken Burns clip via
   `zoompan` (scene duration rescaled to match the actual voiceover length), concat the clips, then
   mux the result against `voiceover.mp3`. If `ffmpeg` and all images are already present, the CLI
   offers to run this immediately and produce `final_video.mp4`.

If images aren't ready yet, the workflow pauses at `awaiting_images` — re-running the CLI after you
drop images in re-checks and resumes automatically.

## Ken Burns filter notes

Each clip uses:

```
scale=<2x target>:force_original_aspect_ratio=increase,crop=<2x target>,
zoompan=z='if(eq(on,0),1,min(zoom+0.0012,1.4))':x='<pan expr>':y='<pan expr>':d=1:s=<target>:fps=<fps>
```

`d=1` (rather than `d=<frames>`) with an `on`-indexed zoom expression avoids the classic zoompan
"jump/reset" artifact seen when animating a single looped still image. Four pan variants
(zoom-center, pan-right, pan-left, pan-down) rotate across consecutive images for visual variety.

## Resuming / starting over

Delete `workflow_state.json` to start an entirely new concept from Stage 1. Deleting only
`state.production` fields isn't supported via CLI flag today — regenerate via the in-app menu
option instead, or hand-edit the JSON file (it's just data).
