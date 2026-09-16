#!/usr/bin/env node
/**
 * delivery 死信队列清理（独立运行，须在 Gateway 停止时执行）。
 *
 * 用法（停掉启动器后、重启前，在此目录运行）：
 *   node cleanup-delivery-queue.cjs
 *
 * 安全护栏（任何一步不符即中止，不删）：
 *   1) 重新导出全部条目到带时间戳的备份 JSON
 *   2) 校验：必须全部 status='failed'，若有非 failed 条目 → 中止
 *   3) DELETE 全部 → 确认表空 → 打印结果
 */
const fs = require('fs');
const path = require('path');
const { DatabaseSync } = require('node:sqlite');

const DB = 'C:\\Users\\zhuyulin\\.openclaw\\state\\openclaw.sqlite';
const BK_DIR = 'C:\\Users\\zhuyulin\\.openclaw\\backups';

function ts() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

// 若 Gateway 还开着，WAL 可能有锁；检测并提示
function main() {
  if (!fs.existsSync(DB)) { console.error('DB_MISSING: ' + DB); process.exit(1); }

  // 只读先校验
  const ro = new DatabaseSync(DB, { readOnly: true });
  const total = ro.prepare('SELECT COUNT(*) c FROM delivery_queue_entries').get().c;
  const byStatus = ro.prepare('SELECT status, COUNT(*) c FROM delivery_queue_entries GROUP BY status').all();
  const rows = ro.prepare('SELECT * FROM delivery_queue_entries').all();
  ro.close();

  console.log('[1/4] 当前队列 total=' + total);
  console.log('      by_status=' + JSON.stringify(byStatus));

  if (total === 0) { console.log('队列已空，无需清理。'); return; }

  const nonFailed = byStatus.filter((s) => s.status !== 'failed');
  if (nonFailed.length > 0) {
    console.error('❌ 中止：存在非 failed 条目 ' + JSON.stringify(nonFailed) + '，不删。请人工检查。');
    process.exit(2);
  }

  // 备份
  const bkPath = path.join(BK_DIR, `delivery-queue-cleanup-${ts()}.json`);
  fs.mkdirSync(BK_DIR, { recursive: true });
  fs.writeFileSync(bkPath, JSON.stringify(rows, null, 2), 'utf8');
  console.log('[2/4] 已备份 ' + rows.length + ' 条 -> ' + bkPath + ` (${(fs.statSync(bkPath).size / 1024).toFixed(0)}KB)`);

  // 读写打开执行 DELETE
  let db;
  try {
    db = new DatabaseSync(DB); // 读写
  } catch (e) {
    console.error('❌ 打开 DB(读写)失败，可能 Gateway 仍在运行占用锁：' + e.message);
    console.error('   请先完全停止启动器/Gateway 再重试。备份已生成，未做任何删除。');
    process.exit(3);
  }

  try {
    const before = db.prepare('SELECT COUNT(*) c FROM delivery_queue_entries').get().c;
    db.exec('DELETE FROM delivery_queue_entries');
    const after = db.prepare('SELECT COUNT(*) c FROM delivery_queue_entries').get().c;
    console.log('[3/4] DELETE 完成：before=' + before + ' after=' + after);
    if (after !== 0) {
      console.error('⚠️ 删除后仍有 ' + after + ' 条，异常。备份在 ' + bkPath);
      process.exit(4);
    }
    // 回收空间
    try { db.exec('VACUUM'); console.log('      VACUUM 完成'); } catch (e) { console.log('      VACUUM 跳过: ' + e.message); }
    console.log('[4/4] ✅ 清理成功，表已空。备份：' + bkPath);
    console.log('      重启启动器后，启动日志应不再有 delivery-recovery 刷屏。');
  } finally {
    db.close();
  }
}

main();
