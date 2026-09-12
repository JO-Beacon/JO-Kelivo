// 图标 SVG 光栅化助手（供 scripts/icons/build_icons.py 调用）
//
// 用法：node render_svg.js <任务清单.json>
// 任务清单为数组，每项：
//   { "svg": "输入 SVG 路径", "out": "输出 PNG 路径", "width": 渲染宽度像素,
//     "background": "可选，CSS 颜色；缺省为透明" }
//
// 为什么用 resvg：图标母版带高斯模糊与发光滤镜，多数光栅化器做不出来。
// resvg 基于 Rust，预编译分发，Windows 上无需额外原生库。
const fs = require('fs');
const path = require('path');
const { Resvg } = require('@resvg/resvg-js');

const jobFile = process.argv[2];
if (!jobFile) {
  console.error('用法：node render_svg.js <任务清单.json>');
  process.exit(2);
}

let jobs;
try {
  jobs = JSON.parse(fs.readFileSync(jobFile, 'utf8'));
} catch (e) {
  console.error(`任务清单读取失败：${e.message}`);
  process.exit(2);
}

let done = 0;
const failures = [];
for (const job of jobs) {
  try {
    const svg = fs.readFileSync(job.svg, 'utf8');
    const resvg = new Resvg(svg, {
      fitTo: { mode: 'width', value: job.width },
      background: job.background || 'rgba(0,0,0,0)',
      font: { loadSystemFonts: false },
    });
    const png = resvg.render().asPng();
    fs.mkdirSync(path.dirname(job.out), { recursive: true });
    fs.writeFileSync(job.out, png);
    done += 1;
  } catch (e) {
    failures.push(`${job.svg} -> ${job.out}：${e.message}`);
  }
}

for (const message of failures) {
  console.error(`渲染失败 ${message}`);
}
console.log(`渲染完成：成功 ${done}，失败 ${failures.length}`);
process.exit(failures.length === 0 ? 0 : 1);
