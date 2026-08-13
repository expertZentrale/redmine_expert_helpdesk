/*
 * Werkzeugleisten-Erweiterungen des Notizfeldes: Zitieren und Antwortvorlagen.
 *
 * Konfiguration kommt aus einem JSON-Insel-Element (#hd-note-toolbar-data), es
 * wird kein inline ausfuehrbares Script benoetigt (CSP-freundlich) - dasselbe
 * Muster wie helpdesk_sla_stats.js.
 *
 * Warum die Buttons per DOM eingehaengt und nicht ueber
 * jsToolBar.prototype.elements registriert werden: wikitoolbar_for gibt ein
 * inline-Script aus, das die Leiste schon waehrend des Parsens zeichnet. Der
 * Hook view_issues_edit_notes_bottom wird erst danach gerendert - eine
 * Registrierung am Prototyp kaeme also zu spaet, wuerde global auf jede
 * Werkzeugleiste der Seite wirken und muesste sich mit der Einfuegereihenfolge
 * von draw() herumschlagen.
 */
(function () {
  'use strict';

  var CONF = null;
  var open = null; // { btn: HTMLElement, menu: HTMLElement }
  var busy = false;

  // --- Hilfsfunktionen -----------------------------------------------------

  function readConfig() {
    var el = document.getElementById('hd-note-toolbar-data');
    if (!el) { return null; }
    try { return JSON.parse(el.textContent); } catch (e) { return null; }
  }

  function t(key) {
    return (CONF && CONF.labels && CONF.labels[key]) || key;
  }

  // --- Text anfuegen -------------------------------------------------------

  // Haengt den Text unten an das Notizfeld an - wie Redmines eigener
  // Zitieren-Button (journals/new.js.erb), getrennt durch eine Leerzeile.
  function appendToNotes(textarea, text) {
    if (!text) { return; }

    // Bei aktiver Vorschau ist das Textfeld ausgeblendet; erst zurueck auf
    // "Bearbeiten" schalten, sonst sieht der Bearbeiter das Eingefuegte nicht.
    if (textarea.offsetParent === null) {
      var block   = textarea.closest ? textarea.closest('.jstBlock') : null;
      var editTab = block ? block.querySelector('.jstTabs a') : null;
      if (editTab) { editTab.click(); }
    }

    var current = textarea.value;
    var sep     = '\n\n';
    if (current.length === 0)            { sep = ''; }
    else if (/\n[ \t]*\n[ \t]*$/.test(current)) { sep = ''; }
    else if (/\n[ \t]*$/.test(current))  { sep = '\n'; }

    textarea.value = current + sep + String(text).replace(/\s+$/, '') + '\n';

    textarea.focus();
    var end = textarea.value.length;
    try { textarea.setSelectionRange(end, end); } catch (e) { /* verborgen */ }
    textarea.scrollTop = textarea.scrollHeight;

    // input: Konvention des Plugins (_macro_chips) und Ausloeser fuer Redmines
    // Warnung ueber ungespeicherte Aenderungen. change: dasselbe fuer Redmine 5.
    textarea.dispatchEvent(new Event('input',  { bubbles: true }));
    textarea.dispatchEvent(new Event('change', { bubbles: true }));
  }

  // --- Statuszeile ---------------------------------------------------------

  function flash(message, isError) {
    var box = document.getElementById('hd-tb-flash');
    if (!box) { return; }
    box.textContent = message || '';
    box.className   = 'hd-tb-flash' + (isError ? ' hd-tb-flash-error' : '');
    box.style.display = message ? 'block' : 'none';
  }

  // --- Inhalt vom Server holen --------------------------------------------

  function loadContent(textarea, params) {
    if (busy) { return; }
    busy = true;
    flash(t('loading'), false);

    var csrf = (document.querySelector('meta[name="csrf-token"]') || {}).content || '';
    var body = new FormData();
    Object.keys(params).forEach(function (key) { body.append(key, params[key]); });

    fetch(CONF.postUrl, {
      method:      'POST',
      credentials: 'same-origin',
      headers:     { 'X-CSRF-Token': csrf, 'Accept': 'application/json' },
      body:        body
    }).then(function (resp) {
      return resp.json().then(function (data) {
        if (!resp.ok) { throw new Error(data.error || resp.statusText); }
        return data;
      });
    }).then(function (data) {
      appendToNotes(textarea, data.content);
      flash('', false);
      if (data.truncated) { flash(t('truncated'), false); }
    }).catch(function (err) {
      flash(t('failed') + ' ' + err.message, true);
    }).then(function () {
      busy = false;
    });
  }

  // --- Menue ---------------------------------------------------------------

  function closeMenu() {
    if (!open) { return; }
    if (open.menu.parentNode) { open.menu.parentNode.removeChild(open.menu); }
    open.btn.setAttribute('aria-expanded', 'false');
    open = null;
    document.removeEventListener('mousedown', onOutside, true);
    document.removeEventListener('keydown', onKeydown, true);
    window.removeEventListener('resize', reposition);
    window.removeEventListener('scroll', reposition, true);
  }

  // Scrollen und Groessenaenderung schliessen das Menue NICHT, sie ruecken es
  // nach: ein echter Mausklick fokussiert den Button, und ein Button unterhalb
  // des sichtbaren Bereichs wird dabei vom Browser hereingescrollt — das Menue
  // waere also genau dann sofort wieder weg, wenn man es am noetigsten braucht.
  function reposition() {
    if (open) { placeMenu(open.menu, open.btn); }
  }

  function onOutside(ev) {
    if (!open) { return; }
    if (open.menu.contains(ev.target) || open.btn.contains(ev.target)) { return; }
    closeMenu();
  }

  function items() {
    return open ? Array.prototype.slice.call(open.menu.querySelectorAll('.hd-tb-item:not([disabled])')) : [];
  }

  function focusItem(index) {
    var list = items();
    if (!list.length) { return; }
    var i = (index + list.length) % list.length;
    list[i].focus();
  }

  function onKeydown(ev) {
    if (!open) { return; }
    var list = items();
    var at   = list.indexOf(document.activeElement);

    // Die behandelten Tasten hier stoppen: sonst erreicht z. B. ArrowDown noch
    // den Keydown-Handler des Buttons, der das gerade geoeffnete Menue wieder
    // zuklappen wuerde.
    if (['Escape', 'ArrowDown', 'ArrowUp', 'Home', 'End'].indexOf(ev.key) !== -1) {
      ev.stopPropagation();
    }

    if (ev.key === 'Escape') {
      ev.preventDefault();
      var btn = open.btn;
      closeMenu();
      btn.focus();
    } else if (ev.key === 'ArrowDown') {
      ev.preventDefault();
      focusItem(at + 1);
    } else if (ev.key === 'ArrowUp') {
      ev.preventDefault();
      focusItem(at <= 0 ? list.length - 1 : at - 1);
    } else if (ev.key === 'Home') {
      ev.preventDefault();
      focusItem(0);
    } else if (ev.key === 'End') {
      ev.preventDefault();
      focusItem(list.length - 1);
    } else if (ev.key === 'Tab') {
      closeMenu();
    }
  }

  function placeMenu(menu, btn) {
    menu.style.visibility = 'hidden';
    menu.style.display    = 'block';
    var rect = btn.getBoundingClientRect();
    var mw   = menu.offsetWidth;
    var mh   = menu.offsetHeight;
    var sx   = window.pageXOffset;
    var sy   = window.pageYOffset;
    var vw   = document.documentElement.clientWidth;

    var left = rect.left + sx;
    var top  = rect.bottom + sy + 2;
    if (rect.left + mw > vw - 8)                              { left = Math.max(sx + 8, rect.right + sx - mw); }
    if (rect.bottom + mh > window.innerHeight - 8 && rect.top > mh) { top = rect.top + sy - mh - 2; }

    menu.style.left       = left + 'px';
    menu.style.top        = top + 'px';
    menu.style.visibility = '';
  }

  // entries: [{ label, run } | { label, disabled } | { label, href } | { separator: true }]
  function buildMenu(entries) {
    // Am <body> statt in der Werkzeugleiste: dort kann kein overflow das Menue
    // abschneiden, und es liegt ausserhalb von #issue-form, kann das Formular
    // also nicht versehentlich absenden.
    var menu = document.createElement('div');
    menu.className = 'hd-tb-menu';
    menu.setAttribute('role', 'menu');

    entries.forEach(function (entry) {
      if (entry.separator) {
        var hr = document.createElement('div');
        hr.className = 'hd-tb-sep';
        menu.appendChild(hr);
        return;
      }
      if (entry.href) {
        var link = document.createElement('a');
        link.className = 'hd-tb-item';
        link.setAttribute('role', 'menuitem');
        link.href = entry.href;
        link.textContent = entry.label;
        menu.appendChild(link);
        return;
      }

      var item = document.createElement('button');
      item.type      = 'button';
      item.className = 'hd-tb-item';
      item.setAttribute('role', 'menuitem');
      item.tabIndex  = -1;
      item.textContent = entry.label;
      if (entry.suffix) {
        var suffix = document.createElement('span');
        suffix.className   = 'hd-tb-item-suffix';
        suffix.textContent = ' ' + entry.suffix;
        item.appendChild(suffix);
      }
      if (entry.disabled) {
        item.disabled = true;
      } else {
        item.addEventListener('click', function (ev) {
          ev.preventDefault();
          closeMenu();
          entry.run();
        });
      }
      menu.appendChild(item);
    });

    return menu;
  }

  function toggleMenu(btn, entriesFn, focusFirst) {
    var wasOpen = open && open.btn === btn;
    closeMenu();
    if (wasOpen) { return; }

    var menu = buildMenu(entriesFn());
    document.body.appendChild(menu);
    placeMenu(menu, btn);
    btn.setAttribute('aria-expanded', 'true');
    open = { btn: btn, menu: menu };

    // mousedown in der Capture-Phase: schliesst, bevor das darunterliegende
    // Element reagiert, sonst flackert das Menue beim Klick auf den Button.
    document.addEventListener('mousedown', onOutside, true);
    document.addEventListener('keydown', onKeydown, true);
    window.addEventListener('resize', reposition);
    window.addEventListener('scroll', reposition, true);

    if (focusFirst) { focusItem(0); }
  }

  // --- Buttons -------------------------------------------------------------

  // Das Icon liefert die CSS-Klasse jstb_hd_<key> als background-image;
  // so ist kein Sprite-Pfad noetig, der sich zwischen Redmine 5 und 7 unterscheidet.
  function makeButton(key, title, entriesFn) {
    var btn = document.createElement('button');
    // type=button ist Pflicht: ein nacktes <button> in #issue-form sendet ab.
    btn.type      = 'button';
    btn.className = 'jstb_hd_' + key + ' hd-tb-btn';
    btn.title     = title;
    btn.setAttribute('aria-label', title);
    btn.setAttribute('aria-haspopup', 'true');
    btn.setAttribute('aria-expanded', 'false');

    btn.addEventListener('click', function (ev) {
      ev.preventDefault();
      ev.stopPropagation();
      toggleMenu(btn, entriesFn, false);
    });
    btn.addEventListener('keydown', function (ev) {
      // Nur oeffnen, nie umschalten: bei offenem Menue gehoert ArrowDown der
      // Navigation zwischen den Eintraegen (siehe onKeydown).
      if (ev.key === 'ArrowDown' && !(open && open.btn === btn)) {
        ev.preventDefault();
        toggleMenu(btn, entriesFn, true);
      }
    });
    return btn;
  }

  function quoteEntries(textarea) {
    return function () {
      return [
        { label: t('quoteDescription'),      run: function () { loadContent(textarea, { source: 'description' }); } },
        { label: t('quoteConversation'),     run: function () { loadContent(textarea, { source: 'conversation' }); } },
        { label: t('quoteMailConversation'), run: function () { loadContent(textarea, { source: 'mail_conversation' }); } }
      ];
    };
  }

  function templateEntries(textarea) {
    return function () {
      var entries = (CONF.templates || []).map(function (tpl) {
        return {
          label:  tpl.name,
          suffix: tpl.global ? t('globalSuffix') : null,
          run:    function () { loadContent(textarea, { source: 'template', template_id: tpl.id }); }
        };
      });
      if (!entries.length) {
        entries.push({ label: t('templatesEmpty'), disabled: true });
      }
      if (CONF.manageUrl) {
        entries.push({ separator: true });
        entries.push({ label: t('templatesManage'), href: CONF.manageUrl });
      }
      return entries;
    };
  }

  // --- Einhaengen ----------------------------------------------------------

  function findToolbar(textarea) {
    // jsToolBar umschliesst das Textfeld mit div.jstBlock; darin liegt
    // div.jstElements - in Redmine 5 direkt, ab Redmine 6 unter li.tab-elements.
    var block = textarea.closest ? textarea.closest('.jstBlock') : null;
    return block ? block.querySelector('.jstElements') : null;
  }

  // Ohne Textformatierung zeichnet wikitoolbar_for gar nichts; dann bauen wir
  // eine eigene kleine Leiste ueber dem Textfeld, statt stumm auszusteigen.
  function makeStandaloneToolbar(textarea) {
    var bar = document.createElement('div');
    bar.className = 'jstElements hd-tb-standalone';
    textarea.parentNode.insertBefore(bar, textarea);
    return bar;
  }

  function mount(toolbar, buttons) {
    // jstoolbar.css schiebt den Hilfe-Button ans Ende der Leiste; davor
    // einhaengen, damit die neuen Buttons bei den Formatierungsicons stehen.
    var anchor = toolbar.querySelector('.jstb_help') || toolbar.querySelector('.help');
    var group  = document.createDocumentFragment();

    var spacer = document.createElement('span');
    spacer.className = 'jstSpacer';
    spacer.innerHTML = '&nbsp;';
    group.appendChild(spacer);
    buttons.forEach(function (b) { group.appendChild(b); });

    if (anchor) { toolbar.insertBefore(group, anchor); } else { toolbar.appendChild(group); }
  }

  function init() {
    if (window.hdNoteToolbarLoaded) { return; }
    window.hdNoteToolbarLoaded = true;

    CONF = readConfig();
    if (!CONF) { return; }

    var textarea = document.getElementById(CONF.textareaId);
    if (!textarea) { return; }

    var toolbar = findToolbar(textarea) || makeStandaloneToolbar(textarea);
    mount(toolbar, [
      makeButton('quote', t('quote'), quoteEntries(textarea)),
      makeButton('templates', t('templates'), templateEntries(textarea))
    ]);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
