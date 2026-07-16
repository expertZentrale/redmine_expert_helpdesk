/*
 * SLA-Statistik: rendert die Diagramme mit Chart.js (lokal gebundelt).
 * Daten kommen aus einem JSON-Insel-Element (#hd-sla-stats-data), es wird kein
 * inline ausfuehrbares Script benoetigt (CSP-freundlich).
 *
 * Beschriftungen: mengenbasierte Diagramme (Volumen/Stoßzeiten) zeigen absolute
 * Anzahlen auf den Balken (Prozente im Tooltip); die SLA-Erfüllung zeigt die
 * Erfüllungsquote (met%) als 0–100%-Balken. So entstehen keine irrefuehrenden
 * "100%" wenn alle Daten in einem Bucket/Segment liegen.
 */
(function () {
  'use strict';

  var COLORS = {
    created:  '#6ba36b', closed: '#9aa7b5',
    reaction: '#4a90c7', solution: '#7d5ba6',
    met:      '#5aa35a', breached: '#c0504d',
    bar:      '#4a90c7', grid: 'rgba(0,0,0,0.06)'
  };

  var HAS_DL = typeof ChartDataLabels !== 'undefined';

  function readData() {
    var el = document.getElementById('hd-sla-stats-data');
    if (!el) { return null; }
    try { return JSON.parse(el.textContent); } catch (e) { return null; }
  }

  function ctx(id) {
    var c = document.getElementById(id);
    return c ? c.getContext('2d') : null;
  }

  function plugins() { return HAS_DL ? [ChartDataLabels] : []; }

  // Tooltip: "Label: Wert (P%)" relativ zur Datensatz-Summe.
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

  // Datalabels: absolute Anzahl ueber dem Balken (nur wenn > 0).
  function countLabels() {
    return { anchor: 'end', align: 'end', offset: 0, clamp: true, display: 'auto',
             color: '#555', font: { size: 10, weight: 'bold' },
             formatter: function (v) { return v > 0 ? v : ''; } };
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
    o.plugins.datalabels = { display: false }; // Dauer, kein Prozent
    o.plugins.tooltip = { callbacks: { label: function (i) { return i.dataset.label + ': ' + fmtMinutes(i.parsed.y); } } };
    o.scales.y.ticks = { callback: function (v) { return fmtMinutes(v); } };
    new Chart(c, {
      type: 'line',
      plugins: plugins(),
      data: {
        labels: d.avgTrend.labels,
        datasets: [
          { label: d.labels.reaction, data: d.avgTrend.reaction, borderColor: COLORS.reaction,
            backgroundColor: COLORS.reaction, tension: 0.3, spanGaps: true, pointRadius: 3 },
          { label: d.labels.solution, data: d.avgTrend.solution, borderColor: COLORS.solution,
            backgroundColor: COLORS.solution, tension: 0.3, spanGaps: true, pointRadius: 3 }
        ]
      },
      options: o
    });
  }

  // SLA-Erfuellung als Erfuellungsquote je Uhr (met% ueber abgeschlossene Uhren,
  // 0–100%). Kein "100% wenn nur ein Segment" mehr; Tooltip zeigt die Anzahlen.
  function renderCompliance(d) {
    var c = ctx('hd-chart-compliance');
    if (!c || !d.compliance) { return; }
    var keys   = ['reaction', 'solution'];
    var labels = [d.labels.reaction, d.labels.solution];
    var ratio  = keys.map(function (k) {
      var x = d.compliance[k], done = (x.met || 0) + (x.breached || 0);
      return done ? Math.round(x.met / done * 1000) / 10 : null;
    });
    var o = baseOptions();
    o.indexAxis = 'y';
    o.plugins.legend = { display: false };
    o.plugins.datalabels = {
      anchor: 'end', align: 'end', offset: 4, clamp: true, color: '#333', font: { weight: 'bold' },
      formatter: function (v, c2) { var p = ratio[c2.dataIndex]; return p == null ? '–' : p + '%'; }
    };
    o.plugins.tooltip = { callbacks: { label: function (i) {
      var x = d.compliance[keys[i.dataIndex]];
      return d.labels.met + ': ' + (x.met || 0) + ' · ' + d.labels.breached + ': ' + (x.breached || 0);
    } } };
    o.scales.x = { beginAtZero: true, max: 100, grid: { color: COLORS.grid }, ticks: { callback: function (v) { return v + '%'; } } };
    o.scales.y = { grid: { display: false } };
    new Chart(c, {
      type: 'bar',
      plugins: plugins(),
      data: {
        labels: labels,
        datasets: [{ label: d.labels.met, data: ratio.map(function (p) { return p == null ? 0 : p; }),
                     backgroundColor: COLORS.met, borderRadius: 3 }]
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

  function fmtMinutes(m) {
    if (m == null) { return '–'; }
    m = Math.round(m);
    var h = Math.floor(m / 60), r = m % 60;
    return h > 0 ? (h + 'h ' + r + 'm') : (r + 'm');
  }

  function init() {
    if (typeof Chart === 'undefined') { return; }
    var d = readData();
    if (!d) { return; }
    renderVolume(d);
    renderAvg(d);
    renderCompliance(d);
    if (d.busiestHours) {
      renderBars('hd-chart-hours', d.busiestHours.labels, d.busiestHours.data, d.labels.hours);
    }
    if (d.busiestWeekdays) {
      renderBars('hd-chart-weekdays', d.busiestWeekdays.labels, d.busiestWeekdays.data, d.labels.weekdays);
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
