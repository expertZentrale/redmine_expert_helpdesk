/*
 * Toolbar additions for the note field: quoting and answer templates.
 *
 * The configuration comes from a JSON island (#hd-note-toolbar-data), so no
 * inline executable script is needed (CSP-friendly) - the same pattern as
 * helpdesk_sla_stats.js.
 *
 * Why the buttons are attached to the DOM instead of being registered through
 * jsToolBar.prototype.elements: wikitoolbar_for emits an inline script that
 * draws the toolbar while the page is still being parsed. The hook
 * view_issues_edit_notes_bottom renders only afterwards, so registering on the
 * prototype would come too late, would affect every toolbar on the page, and
 * would have to fight the insertion order of draw().
 */
(function () {
  'use strict';

  var CONF = null;
  var open = null; // { btn: HTMLElement, menu: HTMLElement }
  var busy = false;

  // --- Helpers -------------------------------------------------------------

  function readConfig() {
    var el = document.getElementById('hd-note-toolbar-data');
    if (!el) { return null; }
    try { return JSON.parse(el.textContent); } catch (e) { return null; }
  }

  function t(key) {
    return (CONF && CONF.labels && CONF.labels[key]) || key;
  }

  // --- Appending text ------------------------------------------------------

  // Appends the text at the end of the note field - like Redmine's own quote
  // button (journals/new.js.erb), separated by a blank line.
  function appendToNotes(textarea, text) {
    if (!text) { return; }

    // With the preview tab active the textarea is hidden; switch back to
    // "Edit" first, otherwise the agent never sees what was inserted.
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
    try { textarea.setSelectionRange(end, end); } catch (e) { /* hidden */ }
    textarea.scrollTop = textarea.scrollHeight;

    // input: the plugin's own convention (_macro_chips) and the trigger for
    // Redmine's unsaved-changes warning. change: the same for Redmine 5.
    textarea.dispatchEvent(new Event('input',  { bubbles: true }));
    textarea.dispatchEvent(new Event('change', { bubbles: true }));
  }

  // --- Status line ---------------------------------------------------------

  function flash(message, isError) {
    var box = document.getElementById('hd-tb-flash');
    if (!box) { return; }
    box.textContent = message || '';
    box.className   = 'hd-tb-flash' + (isError ? ' hd-tb-flash-error' : '');
    box.style.display = message ? 'block' : 'none';
  }

  // --- Fetching content from the server ------------------------------------

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

  // --- Menu ----------------------------------------------------------------

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

  // Scrolling and resizing do NOT close the menu, they move it along: a real
  // mouse click focuses the button, and a button below the fold is scrolled
  // into view by the browser as a result — the menu would vanish immediately in
  // exactly the case where it is needed most.
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

    // Stop the keys handled here: otherwise ArrowDown, for instance, would
    // still reach the button's own keydown handler, which would close the menu
    // that was just opened.
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
    // On <body> rather than inside the toolbar: there no overflow can clip the
    // menu, and it sits outside #issue-form, so it cannot submit the form by
    // accident.
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

    // mousedown in the capture phase: closes before the element underneath
    // reacts, otherwise the menu flickers when clicking the button.
    document.addEventListener('mousedown', onOutside, true);
    document.addEventListener('keydown', onKeydown, true);
    window.addEventListener('resize', reposition);
    window.addEventListener('scroll', reposition, true);

    if (focusFirst) { focusItem(0); }
  }

  // --- Buttons -------------------------------------------------------------

  // The icon comes from the CSS class jstb_hd_<key> as a background-image, so no
  // sprite path is needed - that path differs between Redmine 5 and 7.
  function makeButton(key, title, entriesFn) {
    var btn = document.createElement('button');
    // type=button is mandatory: a bare <button> inside #issue-form submits it.
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
      // Only open, never toggle: while the menu is open ArrowDown belongs to
      // navigating between the entries (see onKeydown).
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

  // --- Mounting ------------------------------------------------------------

  function findToolbar(textarea) {
    // jsToolBar wraps the textarea in div.jstBlock, which contains
    // div.jstElements - directly in Redmine 5, under li.tab-elements from 6 on.
    var block = textarea.closest ? textarea.closest('.jstBlock') : null;
    return block ? block.querySelector('.jstElements') : null;
  }

  // Without text formatting wikitoolbar_for draws nothing at all; build our own
  // small bar above the textarea instead of bailing out silently.
  function makeStandaloneToolbar(textarea) {
    var bar = document.createElement('div');
    bar.className = 'jstElements hd-tb-standalone';
    textarea.parentNode.insertBefore(bar, textarea);
    return bar;
  }

  function mount(toolbar, buttons) {
    // jstoolbar.css pushes the help button to the end of the bar; insert before
    // it so the new buttons sit with the formatting icons.
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
