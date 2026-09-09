/*
 * Ticket statistics: renders the charts with Chart.js (bundled locally).
 * Data comes from a JSON island (#hd-ticket-stats-data), no inline executable
 * script is needed (CSP friendly). Structure mirrors helpdesk_sla_stats.js.
 *
 * Count based charts (volume, conversation length, busiest times) show absolute
 * numbers on the bars and percentages in the tooltip; duration charts (trend,
 * time in status) format minutes as "Xh Ym".
 */
(function () {
  'use strict';

  var COLORS = {
    created: '#6ba36b', closed: '#9aa7b5',
    first:   '#4a90c7', resolution: '#7d5ba6',
    bar:     '#4a90c7', dwell: '#e0a458', grid: 'rgba(0,0,0,0.06)'
  };

  var HAS_DL = typeof ChartDataLabels !== 'undefined';

  function readData() {
    var el = document.getElementById('hd-ticket-stats-data');
    if (!el) { return null; }
    try { return JSON.parse(el.textContent); } catch (e) { return null; }
  }

  function ctx(id) {
    var c = document.getElementById(id);
    return c ? c.getContext('2d') : null;
  }

  function plugins() { return HAS_DL ? [ChartDataLabels] : []; }

  // Tooltip: "Label: value (P%)" relative to the dataset sum.
  function tipDatasetPct(item) {
    var sum = item.chart.data.datasets[item.datasetIndex].data.reduce(function (a, b) { return a + (b || 0); }, 0);
    var p = sum ? Math.round(item.raw / sum * 100) : 0;
    return item.dataset.label + ': ' + item.raw + ' (' + p + '%)';
  }

  function baseOptions() {
    return {
      responsive: true,
      maintainAspectRatio: false,
      interaction: { mode: 'index', intersect: false },
      plugins: {
        legend: { display: true, position: 'bottom', labels: { boxWidth: 12, usePointStyle: true } }
      },
      scales: {
        x: { grid: { display: false } },
        y: { beginAtZero: true, grid: { color: COLORS.grid }, ticks: { precision: 0 } }
      }
    };
  }

  // Datalabels: absolute count above the bar (only when > 0).
  function countLabels() {
    return { anchor: 'end', align: 'end', offset: 0, clamp: true, display: 'auto',
             color: '#555', font: { size: 10, weight: 'bold' },
             formatter: function (v) { return v > 0 ? v : ''; } };
  }

  function fmtMinutes(m) {
    if (m == null) { return '–'; }
    m = Math.round(m);
    var h = Math.floor(m / 60), r = m % 60;
    return h > 0 ? (h + 'h ' + r + 'm') : (r + 'm');
  }

  function renderVolume(d) {
    var c = ctx('hd-chart-volume');
    if (!c || !d.volume) { return; }
    var o = baseOptions();
    o.plugins.tooltip = { callbacks: { label: tipDatasetPct } };
    o.plugins.datalabels = countLabels();
    new Chart(c, {
      type: 'bar',
      plugins: plugins(),
      data: {
        labels: d.volume.labels,
        datasets: [
          { label: d.labels.created, data: d.volume.created, backgroundColor: COLORS.created, borderRadius: 3 },
          { label: d.labels.closed,  data: d.volume.closed,  backgroundColor: COLORS.closed,  borderRadius: 3 }
        ]
      },
      options: o
    });
  }

  function renderAvg(d) {
    var c = ctx('hd-chart-avg');
    if (!c || !d.avgTrend) { return; }
    var o = baseOptions();
    o.plugins.datalabels = { display: false };
    o.plugins.tooltip = { callbacks: { label: function (i) { return i.dataset.label + ': ' + fmtMinutes(i.parsed.y); } } };
    o.scales.y.ticks = { precision: 0, callback: function (v) { return fmtMinutes(v); } };
    new Chart(c, {
      type: 'line',
      plugins: plugins(),
      data: {
        labels: d.avgTrend.labels,
        datasets: [
          { label: d.labels.firstResponse, data: d.avgTrend.firstResponse, borderColor: COLORS.first,
            backgroundColor: COLORS.first, tension: 0.3, spanGaps: true, pointRadius: 3 },
          { label: d.labels.resolution, data: d.avgTrend.resolution, borderColor: COLORS.resolution,
            backgroundColor: COLORS.resolution, tension: 0.3, spanGaps: true, pointRadius: 3 }
        ]
      },
      options: o
    });
  }

  // Median time in status as horizontal bars; tooltip adds mean and the number
  // of completed stays.
  function renderStatusDwell(d) {
    var c = ctx('hd-chart-status');
    if (!c || !d.statusDwell || !d.statusDwell.labels.length) { return; }
    var s = d.statusDwell;
    var o = baseOptions();
    o.indexAxis = 'y';
    o.plugins.legend = { display: false };
    o.plugins.datalabels = {
      anchor: 'end', align: 'end', offset: 4, clamp: true, color: '#333', font: { size: 10, weight: 'bold' },
      formatter: function (v) { return fmtMinutes(v); }
    };
    o.plugins.tooltip = { callbacks: { label: function (i) {
      var k = i.dataIndex;
      return d.labels.median + ': ' + fmtMinutes(s.median[k]) + ' · Ø ' + fmtMinutes(s.mean[k]) + ' · n=' + s.count[k];
    } } };
    o.scales.x = { beginAtZero: true, grid: { color: COLORS.grid }, ticks: { precision: 0, callback: function (v) { return fmtMinutes(v); } } };
    o.scales.y = { grid: { display: false } };
    new Chart(c, {
      type: 'bar',
      plugins: plugins(),
      data: {
        labels: s.labels,
        datasets: [{ label: d.labels.median, data: s.median, backgroundColor: COLORS.dwell, borderRadius: 3 }]
      },
      options: o
    });
  }

  function renderBars(id, labels, data, label) {
    var c = ctx(id);
    if (!c) { return; }
    var o = baseOptions();
    o.plugins.legend = { display: false };
    o.plugins.tooltip = { callbacks: { label: tipDatasetPct } };
    o.plugins.datalabels = countLabels();
    new Chart(c, {
      type: 'bar',
      plugins: plugins(),
      data: { labels: labels, datasets: [{ label: label, data: data, backgroundColor: COLORS.bar, borderRadius: 3 }] },
      options: o
    });
  }

  function init() {
    if (typeof Chart === 'undefined') { return; }
    var d = readData();
    if (!d) { return; }
    renderVolume(d);
    renderAvg(d);
    renderStatusDwell(d);
    if (d.conversation) {
      renderBars('hd-chart-conversation', d.conversation.labels, d.conversation.data, d.labels.tickets);
    }
    if (d.busiestHours) {
      renderBars('hd-chart-hours', d.busiestHours.labels, d.busiestHours.data, d.labels.hours);
    }
    if (d.busiestWeekdays) {
      renderBars('hd-chart-weekdays', d.busiestWeekdays.labels, d.busiestWeekdays.data, d.labels.weekdays);
    }
  }

  // Range presets by approximate span (days) and a sensible default per
  // grouping, so "day" does not show a whole year of daily bars.
  var RANGE_SPAN = {
    last_7_days: 7, last_30_days: 30, last_90_days: 90,
    last_6_months: 182, last_12_months: 365, last_5_years: 1825
  };
  var GROUP_DEFAULT_RANGE = {
    day: 'last_30_days', week: 'last_90_days', month: 'last_12_months', year: 'last_5_years'
  };

  function wireFilter() {
    var form = document.querySelector('.hd-stats-filter');
    if (!form) { return; }
    var period = form.querySelector('#hd-stats-period');
    var range  = form.querySelector('#hd-stats-range');
    var custom = document.getElementById('hd-stats-custom-dates');

    // Date fields only in "custom" mode; disabled otherwise so no stale dates
    // are submitted.
    function toggleCustom() {
      var isCustom = !!(range && range.value === 'custom');
      if (!custom) { return; }
      custom.style.display = isCustom ? '' : 'none';
      Array.prototype.forEach.call(custom.querySelectorAll('input'), function (i) {
        i.disabled = !isCustom;
      });
    }
    if (range) { range.addEventListener('change', toggleCustom); }
    toggleCustom();

    if (period && range) {
      period.addEventListener('change', function () {
        if (range.value === 'custom') { return; }
        var def = GROUP_DEFAULT_RANGE[period.value] || 'last_12_months';
        if ((RANGE_SPAN[range.value] || 0) > (RANGE_SPAN[def] || 0)) {
          range.value = def;
          toggleCustom();
        }
      });
    }
  }

  // --- Sortable tables --------------------------------------------------------
  // Click a header to sort the table by that column; numeric-looking cells
  // ("22h 28m", "46m (n=1)", "100.0 %", "12") sort as numbers, "–" sorts last.
  function cellValue(td) {
    var t = (td.textContent || '').trim();
    if (t === '' || t === '–') { return { n: null, s: '' }; }
    var m = t.match(/^(?:(\d+)h\s*)?(\d+)m\b/);
    if (m) { return { n: (parseInt(m[1] || '0', 10) * 60) + parseInt(m[2], 10), s: t }; }
    m = t.match(/^-?\d+(?:[.,]\d+)?/);
    if (m && /^-?\d+(?:[.,]\d+)?\s*(%|$)/.test(t)) { return { n: parseFloat(m[0].replace(',', '.')), s: t }; }
    return { n: null, s: t.toLowerCase(), text: true };
  }

  function sortTable(table, col, dir) {
    var tbody = table.tBodies[0];
    if (!tbody) { return; }
    var rows = Array.prototype.slice.call(tbody.rows);
    rows.sort(function (a, b) {
      var va = cellValue(a.cells[col]), vb = cellValue(b.cells[col]);
      if (va.n == null && vb.n == null) { return va.s.localeCompare(vb.s) * dir; }
      if (va.n == null) { return 1; }
      if (vb.n == null) { return -1; }
      return (va.n - vb.n) * dir;
    });
    rows.forEach(function (r, i) {
      r.className = r.className.replace(/\b(odd|even)\b/g, '').trim() + (i % 2 ? ' even' : ' odd');
      tbody.appendChild(r);
    });
  }

  function wireSortableTables() {
    Array.prototype.forEach.call(document.querySelectorAll('table.hd-stats-table'), function (table) {
      var ths = table.tHead ? table.tHead.rows[0].cells : [];
      Array.prototype.forEach.call(ths, function (th, col) {
        th.classList.add('hd-sortable');
        th.addEventListener('click', function () {
          var numeric = th.classList.contains('num');
          var wasAsc = th.classList.contains('hd-sort-asc');
          var wasDesc = th.classList.contains('hd-sort-desc');
          // numeric columns start descending, text columns ascending
          var dir = wasAsc ? -1 : wasDesc ? 1 : (numeric ? -1 : 1);
          Array.prototype.forEach.call(ths, function (h) { h.classList.remove('hd-sort-asc', 'hd-sort-desc'); });
          th.classList.add(dir > 0 ? 'hd-sort-asc' : 'hd-sort-desc');
          sortTable(table, col, dir);
        });
      });
    });
  }

  function boot() {
    wireFilter();
    wireSortableTables();
    init();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
