/*
 * KI-Statistik: rendert die Diagramme mit Chart.js (lokal gebundelt).
 * Daten kommen aus einem JSON-Insel-Element (#hd-ai-stats-data), kein inline
 * ausfuehrbares Script noetig (CSP-freundlich). Struktur analog zu
 * helpdesk_sla_stats.js (readData/baseOptions/wireFilter).
 */
(function () {
  'use strict';

  var COLORS = {
    requests: '#4a90c7', input: '#6ba36b', output: '#7d5ba6',
    success:  '#5aa35a', failed: '#c0504d', bar: '#4a90c7',
    grid: 'rgba(0,0,0,0.06)',
    pie: ['#4a90c7', '#6ba36b', '#7d5ba6', '#e0a458', '#c0504d', '#9aa7b5']
  };

  var HAS_DL = typeof ChartDataLabels !== 'undefined';

  function readData() {
    var el = document.getElementById('hd-ai-stats-data');
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

  // Einreihiges Balkendiagramm (Anzahl je Kategorie).
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

  // Gruppiertes Balkendiagramm (zwei Reihen).
  function renderGrouped(id, labels, series) {
    var c = ctx(id);
    if (!c) { return; }
    var o = baseOptions();
    o.plugins.tooltip = { callbacks: { label: tipDatasetPct } };
    o.plugins.datalabels = countLabels();
    new Chart(c, {
      type: 'bar',
      plugins: plugins(),
      data: {
        labels: labels,
        datasets: series.map(function (s) {
          return { label: s.label, data: s.data, backgroundColor: s.color, borderRadius: 3 };
        })
      },
      options: o
    });
  }

  // Ring-Diagramm (Anteile), Datalabels als Prozent.
  function renderDoughnut(id, labels, data) {
    var c = ctx(id);
    if (!c || !labels.length) { return; }
    var o = baseOptions();
    delete o.scales;
    o.plugins.tooltip = { callbacks: { label: tipDatasetPct } };
    o.plugins.datalabels = {
      color: '#fff', font: { weight: 'bold', size: 11 },
      formatter: function (v, c2) {
        var arr = c2.chart.data.datasets[0].data;
        var sum = arr.reduce(function (a, b) { return a + (b || 0); }, 0);
        return v > 0 && sum ? Math.round(v / sum * 100) + '%' : '';
      }
    };
    new Chart(c, {
      type: 'doughnut',
      plugins: plugins(),
      data: { labels: labels, datasets: [{ data: data, backgroundColor: COLORS.pie, borderWidth: 1 }] },
      options: o
    });
  }

  function init() {
    if (typeof Chart === 'undefined') { return; }
    var d = readData();
    if (!d) { return; }

    if (d.volume) { renderBars('hd-chart-ai-volume', d.volume.labels, d.volume.requests, d.labels.requests); }
    if (d.tokens) {
      renderGrouped('hd-chart-ai-tokens', d.tokens.labels, [
        { label: d.labels.input,  data: d.tokens.input,  color: COLORS.input },
        { label: d.labels.output, data: d.tokens.output, color: COLORS.output }
      ]);
    }
    if (d.success) {
      renderGrouped('hd-chart-ai-success', d.success.labels, [
        { label: d.labels.success, data: d.success.success, color: COLORS.success },
        { label: d.labels.failed,  data: d.success.failed,  color: COLORS.failed }
      ]);
    }
    if (d.byType)  { renderDoughnut('hd-chart-ai-types', d.byType.labels, d.byType.data); }
    if (d.byModel) { renderBars('hd-chart-ai-models', d.byModel.labels, d.byModel.data, d.labels.requests); }
    if (d.busiestHours) {
      renderBars('hd-chart-ai-hours', d.busiestHours.labels, d.busiestHours.data, d.labels.hours);
    }
    if (d.busiestWeekdays) {
      renderBars('hd-chart-ai-weekdays', d.busiestWeekdays.labels, d.busiestWeekdays.data, d.labels.weekdays);
    }
  }

  // Zeitraum-Presets nach ungefaehrer Spanne (Tage) und sinnvoller Default je
  // Gruppierung, damit z. B. "Tag" nicht ein ganzes Jahr an Tagesbalken zeigt.
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

  function boot() {
    wireFilter();
    init();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
