// Central definition of the 4 required content formats. wordTarget is based
// on a ~150 wpm Stoic narration pace; sectionCount drives how many
// scenes/images the script is broken into for Ken Burns assembly.
export const FORMATS = {
  short: {
    key: 'short',
    label: 'Short Video',
    durationLabel: '60-120 seconds',
    wordTarget: 280,
    sectionCount: 2,
  },
  listicle: {
    key: 'listicle',
    label: 'Listicle Long-form Video',
    durationLabel: '5-15 minutes',
    wordTarget: 1500,
    sectionCount: 5,
  },
  deep_dive: {
    key: 'deep_dive',
    label: 'Deep Dive Long-form Video',
    durationLabel: '15-30 minutes',
    wordTarget: 3300,
    sectionCount: 7,
  },
  reflection: {
    key: 'reflection',
    label: 'Night-time Reflection Video',
    durationLabel: '60+ minutes',
    wordTarget: 9000,
    sectionCount: 12,
  },
};

export const FORMAT_ORDER = ['short', 'listicle', 'deep_dive', 'reflection'];
