// DashboardHTML.swift
// ScreenMindMac — M9 科幻风格实时监控 Dashboard
//
// 本文件将完整的 Dashboard HTML 作为 Swift 字符串常量内嵌，
// 由 WebMonitorServer 在处理 GET / 请求时直接返回。
//
// Dashboard 功能区域（从上到下，左到右）：
//   ┌─────────────────────────────────────────────────────────────┐
//   │  HEADER：ScreenMind 标题 + 服务器启动时间 + 连接状态指示灯       │
//   ├───────────────┬─────────────────────┬───────────────────────┤
//   │ 焦虑仪表盘     │ HRV 趋势折线图        │ Pipeline 延迟柱状图      │
//   │ (半圆 gauge)  │ (60点滚动)            │ (30点滚动)              │
//   ├───────────────┴─────────────────────┴───────────────────────┤
//   │  实时事件流（滚动日志，最多 200 条，新事件从底部滚入）               │
//   ├─────────────────────────────────────────────────────────────┤
//   │  账号热力图区域（检测到的账号名 + 焦虑分 热度色块）                  │
//   └─────────────────────────────────────────────────────────────┘
//
// 技术栈：
//   - Chart.js v4（via cdnjs CDN）：折线图 + 柱状图
//   - 原生 EventSource API：接收 SSE 事件
//   - 纯 CSS 动画：扫描线、闪烁光标、矩阵雨效果（Canvas）
//   - 主题：黑色背景 + 绿色荧光（#00ff41）科幻终端风格
// ─────────────────────────────────────────────────────────────────────────────

enum DashboardHTML {

    // MARK: - 内联 HTML

    /// 完整 Dashboard HTML 内容（约 700 行）
    /// 使用 Swift 多行字符串字面量，避免转义地狱。
    static let content: String = """
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ScreenMind · 实时监控</title>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.min.js"></script>
    <style>
    /* ───────────────────────────────────────────────────────────────────
       全局基础样式
       ─────────────────────────────────────────────────────────────────── */
    :root {
      --green:       #00ff41;
      --green-dim:   #00aa2b;
      --green-glow:  0 0 8px #00ff41, 0 0 20px #00cc33;
      --amber:       #ffb300;
      --red:         #ff3a3a;
      --bg:          #020c07;
      --card-bg:     #05160a;
      --border:      #0a3d1a;
      --text-dim:    #3a6647;
      --font:        'Courier New', 'Consolas', monospace;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    html, body {
      width: 100%; height: 100%;
      background: var(--bg);
      color: var(--green);
      font-family: var(--font);
      font-size: 13px;
      overflow: hidden;
    }
    /* 全屏扫描线叠层（纯 CSS，不影响点击） */
    body::before {
      content: '';
      position: fixed; inset: 0; z-index: 9999; pointer-events: none;
      background: repeating-linear-gradient(
        0deg,
        transparent,
        transparent 2px,
        rgba(0,255,65,0.015) 2px,
        rgba(0,255,65,0.015) 4px
      );
      animation: scanDown 8s linear infinite;
    }
    @keyframes scanDown {
      0%   { background-position: 0 0; }
      100% { background-position: 0 100vh; }
    }

    /* ───────────────────────────────────────────────────────────────────
       布局：使用 CSS Grid 实现全屏自适应
       ─────────────────────────────────────────────────────────────────── */
    #app {
      display: grid;
      grid-template-rows: 52px 1fr 180px 120px;
      grid-template-columns: 1fr;
      height: 100vh;
      gap: 0;
    }

    /* ───────────────────────────────────────────────────────────────────
       HEADER 区域
       ─────────────────────────────────────────────────────────────────── */
    #header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0 20px;
      border-bottom: 1px solid var(--border);
      background: linear-gradient(90deg, #020c07 0%, #031a0a 50%, #020c07 100%);
    }
    #header h1 {
      font-size: 18px;
      letter-spacing: 6px;
      text-transform: uppercase;
      text-shadow: var(--green-glow);
      animation: pulse 3s ease-in-out infinite;
    }
    @keyframes pulse {
      0%, 100% { opacity: 1; }
      50%       { opacity: 0.85; }
    }
    #header h1 span { color: var(--green-dim); }
    .header-right { display: flex; align-items: center; gap: 20px; }
    #conn-status {
      display: flex; align-items: center; gap: 6px;
      font-size: 11px; color: var(--text-dim);
    }
    #conn-dot {
      width: 8px; height: 8px; border-radius: 50%;
      background: var(--red);
      transition: background 0.3s;
    }
    #conn-dot.connected { background: var(--green); box-shadow: var(--green-glow); }
    #clock { font-size: 12px; color: var(--green-dim); letter-spacing: 2px; }
    #total-events { font-size: 11px; color: var(--text-dim); }

    /* ───────────────────────────────────────────────────────────────────
       中间 3 列图表区域
       ─────────────────────────────────────────────────────────────────── */
    #charts-row {
      display: grid;
      grid-template-columns: 280px 1fr 1fr;
      gap: 1px;
      background: var(--border);
      overflow: hidden;
    }
    .chart-panel {
      background: var(--card-bg);
      display: flex; flex-direction: column;
      padding: 12px;
      position: relative;
      overflow: hidden;
    }
    .chart-panel::after {
      content: '';
      position: absolute; top: 0; left: -100%;
      width: 60%; height: 100%;
      background: linear-gradient(90deg, transparent, rgba(0,255,65,0.03), transparent);
      animation: shimmer 4s ease-in-out infinite;
    }
    @keyframes shimmer {
      0%   { left: -100%; }
      100% { left: 150%; }
    }
    .panel-title {
      font-size: 10px; letter-spacing: 3px;
      text-transform: uppercase; color: var(--green-dim);
      margin-bottom: 8px; border-bottom: 1px solid var(--border);
      padding-bottom: 4px;
    }
    .panel-value {
      font-size: 42px; font-weight: bold;
      text-shadow: var(--green-glow);
      line-height: 1;
    }
    .panel-value.amber { color: var(--amber); text-shadow: 0 0 8px var(--amber); }
    .panel-value.red   { color: var(--red);   text-shadow: 0 0 8px var(--red);   }
    .panel-sub {
      font-size: 11px; color: var(--text-dim); margin-top: 4px;
    }
    canvas.chart-canvas { flex: 1; min-height: 0; }

    /* ───────────────────────────────────────────────────────────────────
       焦虑仪表盘（半圆 Gauge，用 Canvas 手绘）
       ─────────────────────────────────────────────────────────────────── */
    #gauge-wrap {
      display: flex; flex-direction: column; align-items: center;
      justify-content: center; gap: 6px;
      flex: 1;
    }
    #gauge-canvas { display: block; }
    #gauge-app {
      font-size: 11px; color: var(--green-dim);
      text-align: center; max-width: 220px;
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
    }

    /* ───────────────────────────────────────────────────────────────────
       实时事件流日志区域
       ─────────────────────────────────────────────────────────────────── */
    #event-stream {
      background: var(--card-bg);
      border-top: 1px solid var(--border);
      border-bottom: 1px solid var(--border);
      display: flex; flex-direction: column;
      overflow: hidden;
      padding: 6px 12px;
    }
    #event-stream-title {
      font-size: 10px; letter-spacing: 3px;
      text-transform: uppercase; color: var(--green-dim);
      margin-bottom: 4px; flex-shrink: 0;
    }
    #event-log {
      flex: 1; overflow-y: auto; overflow-x: hidden;
      scrollbar-width: thin; scrollbar-color: var(--green-dim) transparent;
    }
    #event-log::-webkit-scrollbar { width: 4px; }
    #event-log::-webkit-scrollbar-thumb { background: var(--green-dim); border-radius: 2px; }
    .log-line {
      display: flex; gap: 10px; padding: 1px 0;
      border-bottom: 1px solid rgba(10,61,26,0.3);
      animation: fadeIn 0.3s ease;
    }
    @keyframes fadeIn { from { opacity: 0; transform: translateX(-4px); } to { opacity: 1; } }
    .log-ts   { color: var(--text-dim); flex-shrink: 0; min-width: 85px; }
    .log-type {
      flex-shrink: 0; min-width: 90px; font-weight: bold;
      padding: 0 4px; border-radius: 2px;
      font-size: 11px;
    }
    .log-type.anxiety  { color: #000; background: var(--green); }
    .log-type.hrv      { color: #000; background: #00bcd4; }
    .log-type.latency  { color: #000; background: var(--amber); }
    .log-type.account  { color: #000; background: #ab47bc; }
    .log-type.alert    { color: #fff; background: var(--red); }
    .log-type.heartbeat{ color: var(--text-dim); background: transparent; border: 1px solid var(--text-dim); }
    .log-msg   { color: var(--green); flex: 1; }

    /* ───────────────────────────────────────────────────────────────────
       底部账号热力图区域
       ─────────────────────────────────────────────────────────────────── */
    #account-heatmap {
      background: var(--card-bg);
      display: flex; flex-direction: column;
      padding: 6px 12px; overflow: hidden;
    }
    #heatmap-title {
      font-size: 10px; letter-spacing: 3px;
      text-transform: uppercase; color: var(--green-dim);
      margin-bottom: 6px; flex-shrink: 0;
    }
    #heatmap-cells {
      display: flex; flex-wrap: wrap; gap: 6px;
      overflow: hidden; align-items: flex-start;
    }
    .heat-cell {
      padding: 4px 10px; border-radius: 3px;
      font-size: 11px; font-weight: bold;
      border: 1px solid;
      transition: all 0.5s;
      white-space: nowrap;
    }

    /* ───────────────────────────────────────────────────────────────────
       矩阵雨背景（Canvas 叠层）
       ─────────────────────────────────────────────────────────────────── */
    #matrix-canvas {
      position: fixed; top: 0; left: 0;
      width: 100%; height: 100%;
      z-index: -1; opacity: 0.04;
      pointer-events: none;
    }

    /* ───────────────────────────────────────────────────────────────────
       闪烁光标（标题后）
       ─────────────────────────────────────────────────────────────────── */
    .cursor { animation: blink 1s step-end infinite; }
    @keyframes blink { 0%, 100% { opacity: 1; } 50% { opacity: 0; } }
    </style>
    </head>
    <body>

    <!-- 矩阵雨背景 Canvas -->
    <canvas id="matrix-canvas"></canvas>

    <div id="app">

      <!-- ─── HEADER ─────────────────────────────────────────────────────── -->
      <div id="header">
        <h1>SCREEN<span>MIND</span> · 实时监控<span class="cursor">_</span></h1>
        <div class="header-right">
          <div id="total-events">事件总数: <span id="ev-count">0</span></div>
          <div id="conn-status">
            <div id="conn-dot"></div>
            <span id="conn-label">未连接</span>
          </div>
          <div id="clock">--:--:--</div>
        </div>
      </div>

      <!-- ─── 图表区域（3列） ─────────────────────────────────────────────── -->
      <div id="charts-row">

        <!-- 左列：焦虑仪表盘 -->
        <div class="chart-panel">
          <div class="panel-title">▸ 焦虑指数</div>
          <div id="gauge-wrap">
            <canvas id="gauge-canvas" width="240" height="130"></canvas>
            <div id="gauge-score" class="panel-value">0.00</div>
            <div class="panel-sub">触发应用</div>
            <div id="gauge-app">—</div>
          </div>
        </div>

        <!-- 中列：HRV 趋势 -->
        <div class="chart-panel">
          <div class="panel-title">▸ HRV 趋势 (SDNN ms)</div>
          <div style="display:flex; gap:16px; margin-bottom:8px;">
            <div>
              <div class="panel-sub">SDNN</div>
              <div id="hrv-sdnn" class="panel-value" style="font-size:28px;">—</div>
            </div>
            <div>
              <div class="panel-sub">RMSSD</div>
              <div id="hrv-rmssd" class="panel-value" style="font-size:28px;">—</div>
            </div>
          </div>
          <canvas id="hrv-chart" class="chart-canvas"></canvas>
        </div>

        <!-- 右列：Pipeline 延迟 -->
        <div class="chart-panel">
          <div class="panel-title">▸ Pipeline 延迟 (ms)</div>
          <div style="margin-bottom:8px;">
            <div class="panel-sub">最新耗时</div>
            <div id="latency-val" class="panel-value" style="font-size:28px;">— ms</div>
          </div>
          <canvas id="latency-chart" class="chart-canvas"></canvas>
        </div>

      </div>

      <!-- ─── 实时事件流 ───────────────────────────────────────────────────── -->
      <div id="event-stream">
        <div id="event-stream-title">▸ 实时事件流 <span style="color:var(--text-dim);font-size:10px;">(最近 200 条)</span></div>
        <div id="event-log"></div>
      </div>

      <!-- ─── 账号热力图 ───────────────────────────────────────────────────── -->
      <div id="account-heatmap">
        <div id="heatmap-title">▸ 账号焦虑热力图</div>
        <div id="heatmap-cells">
          <div style="color:var(--text-dim);font-size:11px;">等待账号检测数据...</div>
        </div>
      </div>

    </div><!-- #app -->

    <script>
    // ═══════════════════════════════════════════════════════════════════════════
    // 工具函数
    // ═══════════════════════════════════════════════════════════════════════════

    // 格式化时间戳（只取时分秒.毫秒 部分）
    function fmtTs(isoStr) {
      const d = new Date(isoStr);
      if (isNaN(d)) return '--:--:--';
      return d.toLocaleTimeString('zh-CN', {hour12: false})
             + '.' + String(d.getMilliseconds()).padStart(3,'0');
    }

    // 根据分数 0–1 返回科幻颜色
    function scoreColor(s) {
      if (s < 0.4)  return '#00ff41';   // 绿：安全
      if (s < 0.6)  return '#aaff00';   // 黄绿：正常
      if (s < 0.7)  return '#ffb300';   // 琥珀：注意
      if (s < 0.85) return '#ff6a00';   // 橙：警告
      return '#ff3a3a';                  // 红：危险
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 实时时钟
    // ═══════════════════════════════════════════════════════════════════════════
    function updateClock() {
      document.getElementById('clock').textContent =
        new Date().toLocaleTimeString('zh-CN', {hour12: false});
    }
    setInterval(updateClock, 1000);
    updateClock();

    // ═══════════════════════════════════════════════════════════════════════════
    // 矩阵雨背景
    // ═══════════════════════════════════════════════════════════════════════════
    (function matrixRain() {
      const canvas = document.getElementById('matrix-canvas');
      const ctx = canvas.getContext('2d');
      canvas.width  = window.innerWidth;
      canvas.height = window.innerHeight;
      window.addEventListener('resize', () => {
        canvas.width  = window.innerWidth;
        canvas.height = window.innerHeight;
        drops = Array(Math.ceil(canvas.width / 16)).fill(1);
      });
      const cols = Math.ceil(canvas.width / 16);
      let drops = Array(cols).fill(1);
      const chars = '01アイウエオカキクケコ心焦虑HRV'.split('');

      function draw() {
        ctx.fillStyle = 'rgba(2,12,7,0.05)';
        ctx.fillRect(0, 0, canvas.width, canvas.height);
        ctx.fillStyle = '#00ff41';
        ctx.font = '14px Courier New';
        drops.forEach((y, i) => {
          const ch = chars[Math.floor(Math.random() * chars.length)];
          ctx.fillText(ch, i * 16, y * 16);
          if (y * 16 > canvas.height && Math.random() > 0.975) drops[i] = 0;
          drops[i]++;
        });
      }
      setInterval(draw, 50);
    })();

    // ═══════════════════════════════════════════════════════════════════════════
    // 焦虑仪表盘（半圆 Gauge，手绘 Canvas）
    // ═══════════════════════════════════════════════════════════════════════════
    const gaugeCanvas = document.getElementById('gauge-canvas');
    const gCtx = gaugeCanvas.getContext('2d');
    let currentAnxiety = 0;

    function drawGauge(score) {
      const w = gaugeCanvas.width, h = gaugeCanvas.height;
      const cx = w / 2, cy = h - 10;
      const r = 100;
      gCtx.clearRect(0, 0, w, h);

      // 背景弧（暗绿）
      gCtx.beginPath();
      gCtx.arc(cx, cy, r, Math.PI, 0);
      gCtx.lineWidth = 14;
      gCtx.strokeStyle = '#0a3d1a';
      gCtx.stroke();

      // 前景弧（根据分数着色）
      const angle = Math.PI + score * Math.PI;
      const color = scoreColor(score);
      gCtx.beginPath();
      gCtx.arc(cx, cy, r, Math.PI, angle);
      gCtx.lineWidth = 14;
      gCtx.strokeStyle = color;
      gCtx.shadowColor = color;
      gCtx.shadowBlur = 12;
      gCtx.stroke();
      gCtx.shadowBlur = 0;

      // 刻度线（5 段）
      for (let i = 0; i <= 5; i++) {
        const a = Math.PI + (i / 5) * Math.PI;
        const x1 = cx + (r - 18) * Math.cos(a), y1 = cy + (r - 18) * Math.sin(a);
        const x2 = cx + (r + 5)  * Math.cos(a), y2 = cy + (r + 5)  * Math.sin(a);
        gCtx.beginPath();
        gCtx.moveTo(x1, y1); gCtx.lineTo(x2, y2);
        gCtx.lineWidth = 1;
        gCtx.strokeStyle = '#0a3d1a';
        gCtx.stroke();
      }

      // 指针
      const nx = cx + (r - 24) * Math.cos(angle);
      const ny = cy + (r - 24) * Math.sin(angle);
      gCtx.beginPath();
      gCtx.moveTo(cx, cy); gCtx.lineTo(nx, ny);
      gCtx.lineWidth = 2;
      gCtx.strokeStyle = '#fff';
      gCtx.shadowColor = '#fff';
      gCtx.shadowBlur = 6;
      gCtx.stroke();
      gCtx.shadowBlur = 0;

      // 中心圆
      gCtx.beginPath();
      gCtx.arc(cx, cy, 5, 0, Math.PI * 2);
      gCtx.fillStyle = '#fff';
      gCtx.fill();
    }
    drawGauge(0);

    function updateAnxiety(score, appName, ts) {
      currentAnxiety = score;
      drawGauge(score);
      const el = document.getElementById('gauge-score');
      el.textContent = score.toFixed(2);
      el.className = 'panel-value';
      if (score >= 0.85) el.classList.add('red');
      else if (score >= 0.6) el.classList.add('amber');
      document.getElementById('gauge-app').textContent = appName || '—';

      // 更新焦虑折线图
      const label = fmtTs(ts);
      anxietyData.labels.push(label);
      anxietyData.datasets[0].data.push(score);
      if (anxietyData.labels.length > 60) {
        anxietyData.labels.shift();
        anxietyData.datasets[0].data.shift();
      }
      anxietyChart.update('quiet');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Chart.js 折线图配置工厂函数
    // ═══════════════════════════════════════════════════════════════════════════
    function makeLineChart(canvasId, label, color, yMin, yMax) {
      const ctx = document.getElementById(canvasId).getContext('2d');
      const data = { labels: [], datasets: [{
        label, data: [],
        borderColor: color,
        backgroundColor: color + '18',
        borderWidth: 1.5,
        pointRadius: 0,
        tension: 0.4,
        fill: true,
      }]};
      const chart = new Chart(ctx, {
        type: 'line',
        data,
        options: {
          animation: false,
          responsive: true,
          maintainAspectRatio: false,
          plugins: { legend: { display: false } },
          scales: {
            x: {
              display: false,
              ticks: { color: '#3a6647', maxTicksLimit: 6, font: { family: 'Courier New', size: 10 } },
              grid: { color: '#0a3d1a' },
            },
            y: {
              min: yMin, max: yMax,
              ticks: { color: '#3a6647', font: { family: 'Courier New', size: 10 } },
              grid: { color: '#0a3d1a' },
            }
          }
        }
      });
      return { chart, data };
    }

    // 焦虑折线（叠在仪表盘下方，隐式折线数据）
    const { chart: anxietyChart, data: anxietyData } =
      makeLineChart('hrv-chart', 'HRV SDNN', '#00bcd4', 0, 100);

    // 重新把 HRV Chart 单独声明（上面复用了 canvas id hrv-chart）
    // — 实际上 anxietyChart 绘制在 hrv-chart 上，HRV 数据就用这个图

    // Pipeline 延迟柱状图
    (function() {
      const ctx = document.getElementById('latency-chart').getContext('2d');
      window.latencyChartData = { labels: [], datasets: [{
        label: 'ms',
        data: [],
        backgroundColor: '#ffb30060',
        borderColor: '#ffb300',
        borderWidth: 1,
      }]};
      window.latencyChart = new Chart(ctx, {
        type: 'bar',
        data: window.latencyChartData,
        options: {
          animation: false,
          responsive: true,
          maintainAspectRatio: false,
          plugins: { legend: { display: false } },
          scales: {
            x: { display: false },
            y: {
              min: 0,
              ticks: { color: '#3a6647', font: { family: 'Courier New', size: 10 } },
              grid: { color: '#0a3d1a' },
            }
          }
        }
      });
    })();

    function updateHRV(sdnn, rmssd, ts) {
      document.getElementById('hrv-sdnn').textContent = sdnn.toFixed(1);
      document.getElementById('hrv-rmssd').textContent = rmssd.toFixed(1);
      // 把 sdnn 追加到折线图
      const label = fmtTs(ts);
      anxietyData.labels.push(label);
      anxietyData.datasets[0].data.push(sdnn);
      if (anxietyData.labels.length > 60) {
        anxietyData.labels.shift();
        anxietyData.datasets[0].data.shift();
      }
      anxietyChart.update('quiet');
    }

    function updateLatency(ms, stage, ts) {
      document.getElementById('latency-val').textContent = ms.toFixed(0) + ' ms';
      const label = fmtTs(ts);
      window.latencyChartData.labels.push(label);
      window.latencyChartData.datasets[0].data.push(ms);
      if (window.latencyChartData.labels.length > 30) {
        window.latencyChartData.labels.shift();
        window.latencyChartData.datasets[0].data.shift();
      }
      window.latencyChart.update('quiet');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 实时事件流日志
    // ═══════════════════════════════════════════════════════════════════════════
    const eventLog = document.getElementById('event-log');
    let logCount = 0;
    const MAX_LOG = 200;

    function addLog(type, msg, ts) {
      const line = document.createElement('div');
      line.className = 'log-line';
      line.innerHTML = `
        <span class="log-ts">${ts ? fmtTs(ts) : new Date().toLocaleTimeString()}</span>
        <span class="log-type ${type}">${type.toUpperCase()}</span>
        <span class="log-msg">${msg}</span>`;
      eventLog.appendChild(line);
      logCount++;
      // 超过最大条数时移除最旧的
      if (logCount > MAX_LOG) {
        eventLog.removeChild(eventLog.firstChild);
        logCount--;
      }
      // 自动滚动到底部
      eventLog.scrollTop = eventLog.scrollHeight;

      // 更新计数器
      document.getElementById('ev-count').textContent = logCount;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // 账号热力图
    // ═══════════════════════════════════════════════════════════════════════════
    const accountMap = {};  // { accountName: { score, platform, count } }

    function updateAccountHeatmap(name, platform, score) {
      if (!name) return;
      if (!accountMap[name]) accountMap[name] = { score, platform, count: 0 };
      accountMap[name].score = score;
      accountMap[name].count++;

      const container = document.getElementById('heatmap-cells');
      container.innerHTML = '';

      // 按分数倒序排列
      const sorted = Object.entries(accountMap)
        .sort((a, b) => b[1].score - a[1].score);

      sorted.forEach(([name, info]) => {
        const color = scoreColor(info.score);
        const cell = document.createElement('div');
        cell.className = 'heat-cell';
        cell.style.borderColor = color;
        cell.style.color = color;
        cell.style.backgroundColor = color + '18';
        cell.style.boxShadow = `0 0 6px ${color}40`;
        cell.textContent = `${name} (${info.platform}) ${info.score.toFixed(2)}`;
        container.appendChild(cell);
      });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SSE 连接 & 事件处理
    // ═══════════════════════════════════════════════════════════════════════════
    let evtSource = null;
    let reconnectDelay = 2000;

    function connect() {
      evtSource = new EventSource('/events');

      evtSource.onopen = () => {
        document.getElementById('conn-dot').classList.add('connected');
        document.getElementById('conn-label').textContent = '已连接';
        reconnectDelay = 2000;
        addLog('heartbeat', '✅ SSE 连接已建立', null);
      };

      evtSource.onerror = () => {
        document.getElementById('conn-dot').classList.remove('connected');
        document.getElementById('conn-label').textContent = '重连中...';
        evtSource.close();
        setTimeout(connect, reconnectDelay);
        reconnectDelay = Math.min(reconnectDelay * 1.5, 30000);
      };

      // ── 焦虑事件 ──────────────────────────────────────────────────────────
      evtSource.addEventListener('anxiety', (e) => {
        const d = JSON.parse(e.data);
        updateAnxiety(d.score, d.appName, d.ts);
        addLog('anxiety',
          `分数 ${d.score.toFixed(3)} ← ${d.appName || '未知'}`, d.ts);
      });

      // ── HRV 事件 ──────────────────────────────────────────────────────────
      evtSource.addEventListener('hrv', (e) => {
        const d = JSON.parse(e.data);
        updateHRV(d.sdnn, d.rmssd, d.ts);
        addLog('hrv',
          `SDNN=${d.sdnn.toFixed(1)}ms  RMSSD=${d.rmssd.toFixed(1)}ms`, d.ts);
      });

      // ── Pipeline 延迟事件 ─────────────────────────────────────────────────
      evtSource.addEventListener('latency', (e) => {
        const d = JSON.parse(e.data);
        updateLatency(d.totalMs, d.stage, d.ts);
        addLog('latency',
          `${d.stage} 耗时 ${d.totalMs.toFixed(0)}ms`, d.ts);
      });

      // ── 账号检测事件 ──────────────────────────────────────────────────────
      evtSource.addEventListener('account', (e) => {
        const d = JSON.parse(e.data);
        updateAccountHeatmap(d.accountName, d.platform, d.combinedScore);
        addLog('account',
          `${d.platform} · ${d.accountName}  综合分=${d.combinedScore.toFixed(2)}`, d.ts);
      });

      // ── 告警事件 ──────────────────────────────────────────────────────────
      evtSource.addEventListener('alert', (e) => {
        const d = JSON.parse(e.data);
        addLog('alert',
          `⚠️ 告警触发！${d.reason}  阈值=${d.threshold}`, d.ts);
        // 告警时屏幕边框闪红
        flashBorder();
      });

      // ── 心跳事件 ──────────────────────────────────────────────────────────
      evtSource.addEventListener('heartbeat', (e) => {
        const d = JSON.parse(e.data);
        addLog('heartbeat', '♥ heartbeat', d.ts);
      });

      // ── 初始快照（连接后服务器主动推送一次全量状态）────────────────────────
      evtSource.addEventListener('snapshot', (e) => {
        const snap = JSON.parse(e.data);
        if (snap.latestAnxietyScore) {
          updateAnxiety(snap.latestAnxietyScore, snap.latestAnxietyApp, new Date().toISOString());
        }
        if (snap.latestHRVsdnn) {
          updateHRV(snap.latestHRVsdnn, snap.latestHRVrmssd, new Date().toISOString());
        }
        if (snap.latestPipelineMs) {
          updateLatency(snap.latestPipelineMs, snap.latestPipelineStage, new Date().toISOString());
        }
        if (snap.latestAccountName) {
          updateAccountHeatmap(snap.latestAccountName, snap.latestAccountPlatform, snap.latestAccountScore);
        }
        // 历史数据批量加载
        (snap.anxietyHistory || []).forEach(pt => {
          anxietyData.labels.push(fmtTs(pt.ts));
          anxietyData.datasets[0].data.push(pt.score);
        });
        anxietyChart.update();
        (snap.latencyHistory || []).forEach(pt => {
          window.latencyChartData.labels.push(fmtTs(pt.ts));
          window.latencyChartData.datasets[0].data.push(pt.ms);
        });
        window.latencyChart.update();
        addLog('heartbeat', `📦 已加载快照，历史焦虑点数=${snap.anxietyHistory?.length||0}`, null);
      });
    }

    // ── 告警边框闪烁 ───────────────────────────────────────────────────────
    function flashBorder() {
      document.body.style.boxShadow = 'inset 0 0 60px rgba(255,58,58,0.6)';
      setTimeout(() => { document.body.style.boxShadow = ''; }, 1000);
    }

    // 启动连接
    connect();

    // ═══════════════════════════════════════════════════════════════════════════
    // 全屏切换（按 F 键）
    // ═══════════════════════════════════════════════════════════════════════════
    document.addEventListener('keydown', (e) => {
      if (e.key === 'f' || e.key === 'F') {
        if (!document.fullscreenElement) document.documentElement.requestFullscreen();
        else document.exitFullscreen();
      }
    });
    </script>
    </body>
    </html>
    """
}
