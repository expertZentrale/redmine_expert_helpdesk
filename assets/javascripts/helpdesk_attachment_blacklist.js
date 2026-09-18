/*
 * Adds a "blacklist this file" button to every attachment row of a ticket.
 *
 * Redmine renders attachment rows from app/views/attachments/_links.html.erb, which
 * carries no view hook - and the markup moved between Redmine 5, 6 and 7 (paragraphs
 * became a table). So rather than matching a fixed structure, every row is found
 * through the one thing that has not changed: a link to /attachments/<id>. The button
 * is appended to the last cell of the row, next to Redmine's own delete link.
 *
 * Clicking asks the server how many copies the purge would take before it asks the
 * agent: deleting files off other people's tickets should be confirmed against a real
 * number, not a warning in the abstract.
 */
(function () {
  'use strict';

  var CONFIG_ID = 'helpdesk-attachment-blacklist-config';
  var MARKER = 'hd-blacklist-done';

  function config() {
    var node = document.getElementById(CONFIG_ID);
    if (!node) { return null; }
    try {
      return JSON.parse(node.textContent);
    } catch (e) {
      return null;
    }
  }

  // The attachment id out of any of the shapes Redmine links it by:
  // /attachments/12, /attachments/download/12/name.png, /attachments/thumbnail/12.
  function attachmentId(row) {
    var links = row.querySelectorAll('a[href*="/attachments/"]');
    for (var i = 0; i < links.length; i++) {
      var match = links[i].getAttribute('href').match(/\/attachments\/(?:download\/|thumbnail\/)?(\d+)\b/);
      if (match) { return match[1]; }
    }
    return null;
  }

  function template(text, values) {
    return String(text).replace(/%\{(\w+)\}/g, function (whole, key) {
      return Object.prototype.hasOwnProperty.call(values, key) ? values[key] : whole;
    });
  }

  function csrfToken() {
    var meta = document.querySelector('meta[name="csrf-token"]');
    return meta ? meta.getAttribute('content') : '';
  }

  // A real form post, so the server can answer with its usual redirect and flash.
  function submit(url) {
    var form = document.createElement('form');
    form.method = 'post';
    form.action = url;
    form.style.display = 'none';

    var token = document.createElement('input');
    token.type = 'hidden';
    token.name = 'authenticity_token';
    token.value = csrfToken();
    form.appendChild(token);

    document.body.appendChild(form);
    form.submit();
  }

  function onClick(cfg, id, event) {
    event.preventDefault();
    var button = event.currentTarget;
    if (button.dataset.hdBusy) { return; }
    button.dataset.hdBusy = '1';

    var previewUrl = cfg.previewUrl.replace('__ID__', id);
    var postUrl = cfg.postUrl.replace('__ID__', id);

    fetch(previewUrl, { credentials: 'same-origin', headers: { 'Accept': 'application/json' } })
      .then(function (response) {
        if (!response.ok) { throw new Error('preview failed'); }
        return response.json();
      })
      .then(function (data) {
        var message = template(data.copies > 1 ? cfg.confirmMany : cfg.confirmOne,
                               { file: data.filename, count: data.copies });
        if (window.confirm(message)) {
          submit(postUrl);
        } else {
          delete button.dataset.hdBusy;
        }
      })
      .catch(function () {
        delete button.dataset.hdBusy;
        window.alert(cfg.error);
      });
  }

  function decorate(cfg, row) {
    if (row.classList.contains(MARKER)) { return; }
    var id = attachmentId(row);
    if (!id) { return; }
    row.classList.add(MARKER);

    // The server decides which files may be blocked at all (type and size guards
    // from the settings), so an .eml, a PDF or a screenshot never gets the button.
    if (cfg.eligible.indexOf(Number(id)) === -1) { return; }

    var button = document.createElement('a');
    button.href = '#';
    button.className = 'hd-blacklist-attachment';
    button.textContent = cfg.label;
    button.title = cfg.title;
    button.addEventListener('click', onClick.bind(null, cfg, id));

    // Redmine's delete link sits in the row's last cell; join it there so the
    // destructive actions stay together. Without cells, append to the row itself.
    var cells = row.querySelectorAll('td');
    var target = cells.length ? cells[cells.length - 1] : row;
    target.appendChild(document.createTextNode(' '));
    target.appendChild(button);
  }

  function decorateAll() {
    var cfg = config();
    if (!cfg) { return; }

    var containers = document.querySelectorAll('.attachments');
    for (var i = 0; i < containers.length; i++) {
      var rows = containers[i].querySelectorAll('tr, p');
      if (rows.length) {
        for (var j = 0; j < rows.length; j++) { decorate(cfg, rows[j]); }
      } else {
        decorate(cfg, containers[i]);
      }
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', decorateAll);
  } else {
    decorateAll();
  }
})();
