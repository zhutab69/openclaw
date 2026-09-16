// cron-uptime.js — 打印 OpenClaw Gateway 已运行分钟数
// 用途：cron 补跑守卫判别「补跑」vs「手动执行/正常触发」
// 补跑只在 Gateway 重启后约 2 分钟内发生；手动执行时 uptime 必然较大。
// 输出：一行 "UPTIME_MIN=<数字>"（失败时输出 UPTIME_MIN=999，即按"非补跑"处理，安全偏向执行）
const { execSync } = require('child_process');
try {
  // 找到 gateway 的 node 进程（CommandLine 含 gateway 且含 index.js）
  const ps =
    'Get-CimInstance Win32_Process -Filter "Name=\'node.exe\'" | ' +
    "Where-Object { $_.CommandLine -like '*gateway*' -and $_.CommandLine -like '*index.js*' } | " +
    'Sort-Object CreationDate | Select-Object -First 1 -ExpandProperty CreationDate';
  const out = execSync(`powershell -NoProfile -Command "${ps}"`, { encoding: 'utf8', timeout: 12000 }).trim();
  if (!out) {
    console.log('UPTIME_MIN=999');
    process.exit(0);
  }
  const start = new Date(out).getTime();
  if (isNaN(start)) {
    console.log('UPTIME_MIN=999');
    process.exit(0);
  }
  const min = Math.round((Date.now() - start) / 60000);
  console.log('UPTIME_MIN=' + min);
} catch (e) {
  // 探测失败时安全偏向执行（不误杀手动/正常运行）
  console.log('UPTIME_MIN=999');
}
