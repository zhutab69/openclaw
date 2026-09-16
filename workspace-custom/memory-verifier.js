/*
 * 只读记忆健康检查。
 * 不写入 MEMORY、archive、daily logs 或状态文件；只输出 JSON 和退出码。
 */
const fs = require('fs');
const path = require('path');

const workspaceRoot = 'C:\\Users\\zhuyulin\\.openclaw\\workspace';
const memoryDir = path.join(workspaceRoot, 'memory');
const paths = {
  hot: path.join(workspaceRoot, 'MEMORY.md'),
  archive: path.join(workspaceRoot, 'MEMORY.archive.md'),
  blocks: path.join(workspaceRoot, 'MEMORY-blocks.md'),
  dreamLog: path.join(memoryDir, 'dream-log.md'),
  smartMemoryLog: 'C:\\Users\\zhuyulin\\.openclaw\\plugins\\smart-memory.log',
};
const HOT_WARN_CHARS = 14000;
const HOT_LIMIT_CHARS = 16000;

function readUtf8(file) {
  return fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '');
}

function fileInfo(file) {
  if (!fs.existsSync(file)) return { exists: false, characters: 0, bytes: 0, modifiedAt: null };
  const stat = fs.statSync(file);
  return { exists: true, characters: readUtf8(file).length, bytes: stat.size, modifiedAt: stat.mtime.toISOString() };
}

function diaryDate(name) {
  const match = name.match(/^(\d{4}-\d{2}-\d{2})/);
  return match ? match[1] : null;
}

function dateInTimeZone(date, timeZone = 'Asia/Shanghai') {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone, year: 'numeric', month: '2-digit', day: '2-digit'
  }).formatToParts(date);
  const values = Object.fromEntries(parts.filter(part => part.type !== 'literal').map(part => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}`;
}

function getDiaryStates(lastDream) {
  if (!fs.existsSync(memoryDir)) return { currentPending: [], pendingSinceDream: [], legacyUnverified: [] };
  const today = dateInTimeZone(new Date());
  const lastDreamDay = lastDream?.dateKey || null;
  const states = { currentPending: [], pendingSinceDream: [], legacyUnverified: [] };

  for (const name of fs.readdirSync(memoryDir).filter(file => /^\d{4}-\d{2}-\d{2}.*\.md$/.test(file))) {
    const file = path.join(memoryDir, name);
    const content = readUtf8(file);
    // 回执必须是文件末尾独占一行；正文引用该字符串不代表已经整合。
    if (/\r?\n<!-- consolidated -->\s*$/.test(content)) continue;
    const stat = fs.statSync(file);
    const entry = { name, date: diaryDate(name), path: file, size: stat.size, lastWrite: stat.mtime.toISOString() };

    // 当天日记在每日 Dream 运行前没有回执是正常状态。
    if (entry.date === today) states.currentPending.push(entry);
    // 最近一次 Dream 后出现的历史日记，需要在下一次 Dream 前关注。
    else if (!lastDreamDay || (entry.date && entry.date > lastDreamDay)) states.pendingSinceDream.push(entry);
    // 旧格式/旧流程文件可能已被人工或旧 Dream 整合但未回写标记；仅登记，不告警。
    else states.legacyUnverified.push(entry);
  }
  return states;
}

function getLastDreamRun() {
  if (!fs.existsSync(paths.dreamLog)) return null;
  const matches = [...readUtf8(paths.dreamLog).matchAll(/## 🌙 Dream #(\d+) — (\d{4}-\d{2}-\d{2})/g)];
  if (!matches.length) return null;
  const last = matches.at(-1);
  return { id: Number(last[1]), dateKey: last[2], date: new Date(`${last[2]}T00:00:00+08:00`) };
}

function smartMemoryHealth() {
  if (!fs.existsSync(paths.smartMemoryLog)) return { exists: false, recentEntry: null };
  const lines = readUtf8(paths.smartMemoryLog).trim().split(/\r?\n/).filter(Boolean);
  return { exists: true, recentEntry: lines.at(-1) || null };
}

const now = new Date();
const hot = fileInfo(paths.hot);
const archive = fileInfo(paths.archive);
const blocks = fileInfo(paths.blocks);
const lastDream = getLastDreamRun();
const diaryStates = getDiaryStates(lastDream);
const smartMemory = smartMemoryHealth();
const hotText = hot.exists ? readUtf8(paths.hot) : '';
const blocksText = blocks.exists ? readUtf8(paths.blocks) : '';
const errors = [];
const warnings = [];

if (!hot.exists) errors.push('MEMORY.md missing');
if (!archive.exists) errors.push('MEMORY.archive.md missing');
if (!blocks.exists) errors.push('MEMORY-blocks.md missing');
if (hot.characters > HOT_LIMIT_CHARS) errors.push(`MEMORY.md exceeds hard injection limit: ${hot.characters}/${HOT_LIMIT_CHARS}`);
else if (hot.characters > HOT_WARN_CHARS) warnings.push(`MEMORY.md is near the injection limit: ${hot.characters}/${HOT_LIMIT_CHARS}`);
if (!hotText.includes('## 冷归档索引')) errors.push('MEMORY.md missing cold archive index');
if (!blocksText.includes('本地 SQLite `222,867,681` 条')) errors.push('source-registry routed memory is not at the verified local baseline');
if (blocksText.includes('目标3 1亿🔄')) errors.push('source-registry routed memory still contains obsolete in-progress milestone');
if (!smartMemory.exists) warnings.push('smart-memory log not found');
if (diaryStates.pendingSinceDream.length) warnings.push(`daily memories pending since the last Dream: ${diaryStates.pendingSinceDream.length}`);
const twoDaysAgo = new Date(now.getTime() - 48 * 60 * 60 * 1000);
if (!lastDream || Number.isNaN(lastDream.date.getTime()) || lastDream.date < twoDaysAgo) warnings.push('no confirmed Dream run in the last 48 hours');

const result = {
  timestamp: now.toISOString(),
  mode: 'read-only',
  thresholds: { hotWarnChars: HOT_WARN_CHARS, hotHardLimitChars: HOT_LIMIT_CHARS },
  files: { hot, archive, routedBlocks: blocks },
  coldArchiveIndexPresent: hotText.includes('## 冷归档索引'),
  sourceRegistryBlockCurrent: blocksText.includes('本地 SQLite `222,867,681` 条') && !blocksText.includes('目标3 1亿🔄'),
  smartMemory,
  diaryStates: {
    currentPending: diaryStates.currentPending,
    pendingSinceDream: diaryStates.pendingSinceDream,
    legacyUnverified: diaryStates.legacyUnverified,
  },
  pendingAlertCount: diaryStates.pendingSinceDream.length,
  legacyUnverifiedCount: diaryStates.legacyUnverified.length,
  lastDreamRunId: lastDream?.id ?? null,
  lastDreamDate: lastDream?.date?.toISOString() ?? null,
  errors,
  warnings,
  healthy: errors.length === 0,
};

console.log(JSON.stringify(result, null, 2));
process.exit(errors.length ? 2 : warnings.length ? 1 : 0);