import Foundation

/// The dashboard page the Windows shell serves: the menu-bar popover and the settings window
/// of the macOS app, as one HTML page talking to `DashboardAPI`.
///
/// Kept as a string in the binary rather than a resource file so the executable is the whole
/// app — there is no bundle on Windows to keep a page in, and a page that can go missing
/// next to the `.exe` is a support ticket. No script or style is fetched from anywhere: the
/// page works offline and loads nothing a third party could change.
///
/// The page never restates the reviewer surface. Which reviewer has a CLI, takes a key, has
/// efforts, or needs prices comes from `ReviewerDescriptor` in the snapshot, so a reviewer
/// added to `ReviewerName` gets a card here without a change to this file.
enum DashboardPage {
    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Review Bot</title>
    <style>
    :root {
      color-scheme: light dark;
      --bg: #f4f4f6; --panel: #ffffff; --border: #dcdce2; --text: #1c1c1e; --muted: #6b6b73;
      --accent: #2f6fed; --accent-text: #ffffff; --green: #1f9d55; --orange: #d97706;
      --red: #d13438; --blue: #2f6fed; --purple: #7c3aed; --input: #ffffff; --hover: #eef0f5;
      --mono: ui-monospace, "Cascadia Mono", Consolas, Menlo, monospace;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #1b1b1f; --panel: #26262b; --border: #3a3a42; --text: #ececf1; --muted: #a0a0ab;
        --input: #1f1f24; --hover: #30303a;
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0; background: var(--bg); color: var(--text);
      font: 14px/1.45 -apple-system, "Segoe UI Variable", "Segoe UI", system-ui, sans-serif;
    }
    .app { max-width: 960px; margin: 0 auto; padding: 20px 20px 60px; }
    header.top {
      display: flex; align-items: center; gap: 14px; padding: 14px 16px; margin-bottom: 14px;
      background: var(--panel); border: 1px solid var(--border); border-radius: 12px;
    }
    .status-dot { width: 40px; height: 40px; border-radius: 10px; display: grid; place-items: center; font-size: 20px; }
    .status-dot.ok { background: color-mix(in srgb, var(--green) 15%, transparent); }
    .status-dot.paused { background: color-mix(in srgb, var(--orange) 15%, transparent); }
    .status-dot.failed { background: color-mix(in srgb, var(--red) 15%, transparent); }
    .status-dot.running { background: color-mix(in srgb, var(--blue) 15%, transparent); }
    header.top h1 { margin: 0; font-size: 17px; }
    header.top .status { color: var(--muted); font-size: 13px; }
    .badge {
      font-size: 11px; font-weight: 600; padding: 3px 9px; border-radius: 999px;
      background: color-mix(in srgb, currentColor 14%, transparent);
    }
    .badge.green { color: var(--green); } .badge.orange { color: var(--orange); }
    .badge.red { color: var(--red); } .badge.blue { color: var(--blue); }
    .grow { flex: 1; }
    button {
      font: inherit; color: var(--text); background: var(--panel); border: 1px solid var(--border);
      border-radius: 8px; padding: 6px 12px; cursor: pointer;
    }
    button:hover:not(:disabled) { background: var(--hover); }
    button:disabled { opacity: .5; cursor: default; }
    button.primary { background: var(--accent); color: var(--accent-text); border-color: transparent; }
    button.primary:hover:not(:disabled) { background: color-mix(in srgb, var(--accent) 85%, black); }
    button.danger { color: var(--red); }
    button.link { border: none; background: none; color: var(--accent); padding: 0; }
    input[type=text], input[type=password], input[type=number], select, textarea {
      font: inherit; color: var(--text); background: var(--input); border: 1px solid var(--border);
      border-radius: 8px; padding: 6px 9px;
    }
    input.mono, textarea.mono { font-family: var(--mono); font-size: 13px; }
    textarea { width: 100%; min-height: 320px; resize: vertical; }
    .tabs { display: flex; gap: 4px; border-bottom: 1px solid var(--border); margin-bottom: 16px; }
    .tabs button {
      border: none; background: none; border-radius: 8px 8px 0 0; padding: 9px 14px; color: var(--muted);
      border-bottom: 2px solid transparent; margin-bottom: -1px;
    }
    .tabs button.active { color: var(--text); border-bottom-color: var(--accent); }
    .panel { display: none; }
    .panel.active { display: block; }
    .box {
      background: var(--panel); border: 1px solid var(--border); border-radius: 12px;
      padding: 14px 16px; margin-bottom: 14px;
    }
    .box h3 { margin: 0 0 10px; font-size: 14px; }
    h2 { font-size: 18px; margin: 0 0 4px; }
    .lead { color: var(--muted); margin: 0 0 14px; }
    .caption { color: var(--muted); font-size: 12px; margin: 6px 0 0; }
    .warn { color: var(--orange); font-size: 12px; }
    .good { color: var(--green); font-size: 12px; }
    .row { display: flex; align-items: center; gap: 10px; margin: 8px 0; flex-wrap: wrap; }
    .row label.name { width: 90px; color: var(--muted); font-size: 13px; }
    .seg { display: inline-flex; border: 1px solid var(--border); border-radius: 8px; overflow: hidden; }
    .seg button { border: none; border-radius: 0; padding: 5px 12px; background: var(--panel); }
    .seg button + button { border-left: 1px solid var(--border); }
    .seg button.on { background: var(--accent); color: var(--accent-text); }
    .chip {
      display: inline-flex; gap: 6px; align-items: center; font-size: 12px; padding: 4px 10px;
      border-radius: 999px; background: color-mix(in srgb, var(--muted) 12%, transparent);
    }
    .queue { padding: 7px 10px; border-radius: 8px; margin-top: 8px; display: flex; gap: 10px; align-items: center; }
    .queue.running { background: color-mix(in srgb, var(--blue) 8%, transparent); }
    .queue.pending { background: color-mix(in srgb, var(--orange) 8%, transparent); }
    .queue .title { color: var(--muted); font-size: 12px; }
    .repo { display: flex; gap: 12px; align-items: flex-start; padding: 12px 0; border-top: 1px solid var(--border); }
    .repo:first-child { border-top: none; }
    .repo .fields { flex: 1; display: grid; gap: 6px; }
    .repo .path { font-family: var(--mono); font-size: 12px; color: var(--muted); word-break: break-all; }
    .hist { display: flex; gap: 12px; padding: 10px 0; border-top: 1px solid var(--border); }
    .hist:first-child { border-top: none; }
    .hist .icon { width: 24px; font-size: 18px; text-align: center; }
    .hist .body { flex: 1; min-width: 0; }
    .hist .msg { color: var(--muted); font-size: 12px; white-space: pre-wrap; word-break: break-word; }
    .hist .meta { text-align: right; color: var(--muted); font-size: 12px; white-space: nowrap; }
    .empty { text-align: center; color: var(--muted); padding: 40px 0; }
    .banner {
      position: fixed; left: 50%; bottom: 20px; transform: translateX(-50%); max-width: 700px;
      background: var(--panel); border: 1px solid var(--red); color: var(--text); padding: 10px 14px;
      border-radius: 10px; box-shadow: 0 8px 30px rgba(0,0,0,.25); display: none; gap: 12px; align-items: center;
    }
    .banner.show { display: flex; }
    footer { color: var(--muted); font-size: 12px; display: flex; gap: 14px; align-items: center; margin-top: 24px; }
    .price { width: 90px; }
    .kv { display: flex; gap: 8px; align-items: center; }
    </style>
    </head>
    <body>
    <div class="app">
      <header class="top">
        <div class="status-dot ok" id="statusDot">✓</div>
        <div>
          <h1>Review Bot</h1>
          <div class="status" id="statusText">Connecting…</div>
        </div>
        <div class="grow"></div>
        <span class="badge green" id="statusBadge">Active</span>
        <button class="primary" id="runNow">▶ Run now</button>
        <button id="togglePause">Pause</button>
      </header>

      <div class="box" id="queueBox">
        <div class="row">
          <span class="chip">✨ Running <b id="runningCount">0</b></span>
          <span class="chip">⏳ Pending <b id="pendingCount">0</b></span>
          <span class="grow"></span>
          <span class="caption" id="configSummary"></span>
        </div>
        <div id="queueList"></div>
      </div>

      <nav class="tabs" id="tabs">
        <button data-tab="repos" class="active">Repositories</button>
        <button data-tab="reviewers">Reviewers</button>
        <button data-tab="decisions">Decisions</button>
        <button data-tab="prompt">Prompt</button>
        <button data-tab="history">History</button>
      </nav>

      <section class="panel active" data-panel="repos">
        <div class="box">
          <h3>Monitoring</h3>
          <div class="row">
            <div class="grow">
              <div id="monitorStatus"><b>…</b></div>
              <div class="caption">Run now always performs one check, even while automatic monitoring is paused.</div>
            </div>
          </div>
          <div class="row">
            <label class="name">Check every</label>
            <select id="pollInterval">
              <option value="5">5 minutes</option>
              <option value="15">15 minutes</option>
              <option value="30">30 minutes</option>
              <option value="60">1 hour</option>
            </select>
            <span class="grow"></span>
            <span class="caption" id="lastChecked"></span>
          </div>
          <div class="row">
            <label class="name">At once</label>
            <input type="number" id="maxConcurrent" min="1" max="8" style="width:70px">
            <span id="maxConcurrentLabel"></span>
          </div>
          <div class="caption">Each pull request runs every enabled reviewer, so this many times that many CLI processes, and that much API traffic, can be in flight together. Pull requests from the same repository still prepare their worktrees one at a time.</div>
          <div class="row">
            <label><input type="checkbox" id="launchAtLogin"> Launch Review Bot when you sign in</label>
          </div>
        </div>

        <div class="row">
          <div class="grow">
            <h2>Repositories</h2>
            <p class="lead">Review Bot infers the GitHub repository from the folder's origin remote.</p>
          </div>
        </div>
        <div class="box">
          <div class="row">
            <input type="text" class="mono grow" id="newRepoPath" placeholder="C:\Users\you\src\my-repo" style="flex:1">
            <button class="primary" id="addRepo">＋ Add repository</button>
          </div>
          <div class="caption">Paste the full path of a local clone. Its <code>origin</code> remote must point at GitHub.</div>
        </div>
        <div class="box" id="repoList"></div>
      </section>

      <section class="panel" data-panel="reviewers">
        <h2>AI reviewers</h2>
        <p class="lead">Enabled reviewers run independently in parallel. The most severe parsed verdict determines the GitHub action.</p>

        <div class="box">
          <h3>Review scope</h3>
          <div class="row">
            <label class="name">Review</label>
            <div class="seg" id="reviewScope">
              <button data-value="full">Whole PR</button>
              <button data-value="incremental">New changes only</button>
            </div>
          </div>
          <div class="caption">“Whole PR” reviews the entire diff every time. “New changes only” reviews just what changed since the last posted review, so reviewers don't re-flag already-reviewed code — it falls back to the whole PR on the first review or a re-request with no new commits.</div>
        </div>

        <div class="box">
          <h3>Re-review limit</h3>
          <div class="row"><label><input type="checkbox" id="limitRounds"> Limit re-reviews per pull request</label></div>
          <div class="row" id="roundsRow"><label class="name">Up to</label><input type="number" id="maxRounds" min="1" max="50" style="width:80px"> <span>reviews per pull request</span></div>
          <div class="caption" id="roundsCaption"></div>
        </div>

        <div class="box">
          <h3>Failure budget</h3>
          <div class="row"><label><input type="checkbox" id="limitFailures"> Give up after repeated failures</label></div>
          <div class="row" id="failuresRow"><label class="name">Up to</label><input type="number" id="failureBudget" min="1" max="20" style="width:80px"> <span>attempts per review request</span></div>
          <div class="caption" id="failuresCaption"></div>
        </div>

        <div class="box">
          <h3>Usage and cost</h3>
          <div class="row"><label><input type="checkbox" id="includeUsage"> Include token usage and cost in the posted review</label></div>
          <div class="caption">Usage is always recorded in the activity history, whether or not it is posted. Only reviewers billed per token appear — a reviewer using its signed-in CLI is covered by that subscription, so no dollar figure is attributed to it.</div>
        </div>

        <div class="box">
          <div class="row">
            <span>🔗 GitHub CLI</span>
            <span class="grow"></span>
            <span id="ghStatus"></span>
          </div>
        </div>

        <div id="reviewerCards"></div>

        <div class="row">
          <span class="caption grow">At least one AI reviewer must be enabled. opencode is off by default; it runs the free <code>opencode/deepseek-v4-flash-free</code> model at max reasoning effort in a read-only sandbox. DeepSeek is off by default too — it has no CLI, so it needs an API key saved on its card above before it can review.</span>
          <button id="refreshTools">Refresh CLI status</button>
        </div>
      </section>

      <section class="panel" data-panel="decisions">
        <h2>Decision policy</h2>
        <p class="lead">Choose what Review Bot does on GitHub for each severity its reviewers report. When reviewers disagree across the request-changes line, Review Bot reconciles before deciding.</p>
        <div class="box">
          <h3>When the strictest verdict is…</h3>
          <div id="decisionRows"></div>
        </div>
        <div class="row">
          <span class="caption grow">ℹ️ “Leave it to me” posts a neutral comment — no approval and no change request — so you make the call. A reviewer that fails or returns an unreadable verdict always falls back to a neutral comment.</span>
          <button id="resetPolicy">Reset to defaults</button>
        </div>
      </section>

      <section class="panel" data-panel="prompt">
        <h2>Custom review instructions</h2>
        <p class="lead">These instructions are appended to Review Bot's built-in review and verdict contract for every repository.</p>
        <textarea class="mono" id="customPrompt" spellcheck="false"></textarea>
        <div class="row">
          <span class="caption grow">Examples: project-specific architecture rules, test commands, or areas to scrutinize.</span>
          <span class="caption" id="promptCount"></span>
          <button id="clearPrompt">Clear</button>
        </div>
      </section>

      <section class="panel" data-panel="history">
        <div class="row">
          <div class="grow">
            <h2>Activity history</h2>
            <p class="lead">Review requests, starts, GitHub decisions, and failures are retained locally.</p>
          </div>
          <button id="openData">Show data folder</button>
          <button class="danger" id="clearHistory">Clear history</button>
        </div>
        <div class="box" id="historyList"><div class="empty">Loading…</div></div>
      </section>

      <footer>
        <span id="versionLabel"></span>
        <span class="grow"></span>
        <span id="dataFolder" style="font-family: var(--mono)"></span>
        <button class="danger" id="quit">Quit Review Bot</button>
      </footer>
    </div>

    <div class="banner" id="banner"><span id="bannerText"></span><button id="bannerClose">Dismiss</button></div>

    <script>
    (function () {
      'use strict';

      // ---- token -------------------------------------------------------------------------
      // The tray opens the page as /?t=<token>. The token is moved out of the address bar into
      // sessionStorage (per tab, gone when the tab closes) so it does not sit in history.
      let token = null;
      try {
        const params = new URLSearchParams(location.search);
        if (params.get('t')) {
          token = params.get('t');
          sessionStorage.setItem('reviewBotToken', token);
          history.replaceState(null, '', location.pathname);
        } else {
          token = sessionStorage.getItem('reviewBotToken');
        }
      } catch (e) { /* storage unavailable: the in-memory token still works for this load */ }

      const $ = (id) => document.getElementById(id);
      const escapeHTML = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

      async function api(method, path, body) {
        const headers = { 'Authorization': 'Bearer ' + (token || '') };
        if (body !== undefined) headers['Content-Type'] = 'application/json';
        const response = await fetch('/api/' + path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
        if (response.status === 204) return null;
        const text = await response.text();
        let data = null;
        try { data = text ? JSON.parse(text) : null; } catch (e) { data = null; }
        if (!response.ok) throw new Error((data && data.error) || ('HTTP ' + response.status));
        return data;
      }

      // ---- state -------------------------------------------------------------------------
      let snapshot = null;
      let config = null;          // the client's working copy of the configuration
      let knownVersion = -1;      // the server version `config` was last synced with
      let saveTimer = null;
      let activeTab = 'repos';
      let reviewerDrafts = {};    // per-reviewer API key drafts and price field text

      function showError(message) {
        $('bannerText').textContent = message;
        $('banner').classList.add('show');
      }
      $('bannerClose').onclick = () => $('banner').classList.remove('show');

      function configInputFocused() {
        const el = document.activeElement;
        return el && el.closest && el.closest('[data-config]') !== null;
      }

      function queueSave() {
        clearTimeout(saveTimer);
        saveTimer = setTimeout(saveConfig, 350);
      }

      async function saveConfig() {
        if (!config) return;
        try {
          const result = await api('PUT', 'config', config);
          if (result && typeof result.configurationVersion === 'number') knownVersion = result.configurationVersion;
        } catch (e) { showError('Could not save settings: ' + e.message); }
      }

      function reviewerKey(name) { return name.toLowerCase(); }

      // ---- polling -----------------------------------------------------------------------
      async function poll() {
        try {
          const next = await api('GET', 'state');
          snapshot = next;
          if (next.errorMessage) showError(next.errorMessage);
          if (config === null || (next.configurationVersion !== knownVersion && !configInputFocused())) {
            config = next.configuration;
            knownVersion = next.configurationVersion;
            renderConfig();
          }
          renderLive();
          if (activeTab === 'history') refreshHistory();
        } catch (e) {
          $('statusText').textContent = token ? ('Not reachable: ' + e.message) : 'Open the dashboard from the Review Bot tray icon.';
          $('statusBadge').textContent = 'Offline'; $('statusBadge').className = 'badge red';
        }
      }

      // ---- live header -------------------------------------------------------------------
      function relative(iso) {
        if (!iso) return '';
        const seconds = Math.round((Date.now() - new Date(iso).getTime()) / 1000);
        if (seconds < 60) return 'just now';
        if (seconds < 3600) return Math.round(seconds / 60) + ' min ago';
        if (seconds < 86400) return Math.round(seconds / 3600) + ' h ago';
        return Math.round(seconds / 86400) + ' d ago';
      }

      function renderLive() {
        const s = snapshot;
        const paused = config.isPaused;
        const failed = s.historyCount > 0 && s.lastEventKind === 'failed';
        let cls = 'ok', badge = ['Active', 'green'], glyph = '✓';
        if (s.isRunning) { cls = 'running'; badge = ['Reviewing', 'blue']; glyph = '⟳'; }
        else if (paused) { cls = 'paused'; badge = ['Paused', 'orange']; glyph = '❚❚'; }
        else if (failed) { cls = 'failed'; badge = ['Attention', 'red']; glyph = '!'; }
        $('statusDot').className = 'status-dot ' + cls; $('statusDot').textContent = glyph;
        $('statusText').textContent = s.status;
        $('statusBadge').textContent = badge[0]; $('statusBadge').className = 'badge ' + badge[1];
        $('runNow').disabled = s.isRunning;
        $('togglePause').textContent = paused ? '▶ Resume' : '❚❚ Pause';
        $('monitorStatus').innerHTML = '<b>' + escapeHTML(paused ? 'Monitoring is paused' : s.status) + '</b>';
        $('lastChecked').textContent = s.lastCheckDate ? 'Last checked ' + relative(s.lastCheckDate) : '';
        $('launchAtLogin').checked = s.launchAtLoginEnabled;
        $('runningCount').textContent = s.runningReviews.length;
        $('pendingCount').textContent = s.pendingReviews.length;
        const minutes = config.pollIntervalMinutes;
        const enabledRepos = config.repositories.filter((r) => r.enabled).length;
        $('configSummary').textContent = '⏱ Every ' + (minutes === 60 ? '1 hour' : minutes + ' minutes') + ' · 📦 ' + enabledRepos + ' enabled';

        let queue = '';
        s.runningReviews.forEach((item) => { queue += queueRow(item, 'running', 'Running'); });
        s.pendingReviews.slice(0, 3).forEach((item) => { queue += queueRow(item, 'pending', 'Pending'); });
        if (s.pendingReviews.length > 3) queue += '<div class="caption">+ ' + (s.pendingReviews.length - 3) + ' more pending</div>';
        $('queueList').innerHTML = queue;

        $('ghStatus').innerHTML = toolBadge(s.toolAvailability['gh'] === true, 'gh');
        renderReviewerLive();
        $('versionLabel').textContent = 'Review Bot ' + s.version;
        $('dataFolder').textContent = s.dataFolder;
      }

      function queueRow(item, cls, state) {
        return '<div class="queue ' + cls + '"><span>' + (cls === 'running' ? '⟳' : '●') + '</span><div class="grow"><b>' + escapeHTML(item.repositoryName) + ' #' + item.pullRequestNumber + '</b><div class="title">' + escapeHTML(item.pullRequestTitle) + '</div></div><span class="caption">' + state + '</span></div>';
      }

      function toolBadge(available, command) {
        return available ? '<span class="good">✓ ' + escapeHTML(command) + ' found</span>' : '<span class="warn">⚠ ' + escapeHTML(command) + ' not found</span>';
      }

      // ---- config forms ------------------------------------------------------------------
      function renderConfig() {
        $('pollInterval').value = String(config.pollIntervalMinutes);
        $('maxConcurrent').value = config.maxConcurrentReviews;
        $('maxConcurrentLabel').textContent = config.maxConcurrentReviews === 1 ? 'pull request at a time' : 'pull requests at once';
        $('includeUsage').checked = config.includeUsageInReview;
        seg($('reviewScope'), config.reviewScope);

        const rounds = config.maxReviewRoundsPerPR;
        $('limitRounds').checked = rounds != null;
        $('roundsRow').style.display = rounds != null ? '' : 'none';
        if (rounds != null) $('maxRounds').value = rounds;
        $('roundsCaption').textContent = rounds == null
          ? 'Unlimited: every new commit or re-request is reviewed.'
          : 'Counts reviews that were posted. After the limit is reached, further commits and re-requests on that PR are skipped.';

        const budget = config.failureBudget; // 0 means unlimited
        $('limitFailures').checked = budget > 0;
        $('failuresRow').style.display = budget > 0 ? '' : 'none';
        if (budget > 0) $('failureBudget').value = budget;
        $('failuresCaption').textContent = budget > 0
          ? 'A review that doesn\'t post — a reviewer errored, returned no verdict, or GitHub rejected the post — is retried with a widening delay, then abandoned. Every attempt re-runs the reviewers, so any reviewer billed to your own API key is charged again. A new commit, a re-request, or Run now starts over.'
          : 'A request whose reviewers keep failing is retried forever, with a widening delay between attempts. Every attempt re-runs the reviewers, so any reviewer billed to your own API key is charged again.';

        $('customPrompt').value = config.customPrompt;
        $('promptCount').textContent = config.customPrompt.length + ' characters';
        $('clearPrompt').disabled = config.customPrompt.length === 0;

        renderRepositories();
        renderReviewers();
        renderDecisions();
      }

      function seg(container, value) {
        container.querySelectorAll('button').forEach((b) => b.classList.toggle('on', b.dataset.value === value));
      }

      // Repositories
      function renderRepositories() {
        const list = $('repoList');
        if (config.repositories.length === 0) {
          list.innerHTML = '<div class="empty">📂 No repositories<br><span class="caption">Add a local GitHub repository to start watching its review requests.</span></div>';
          return;
        }
        list.innerHTML = config.repositories.map((r, i) => '<div class="repo" data-config>'
          + '<label title="Enabled"><input type="checkbox" data-repo="' + i + '" data-field="enabled"' + (r.enabled ? ' checked' : '') + '></label>'
          + '<span style="font-size:22px">📦</span>'
          + '<div class="fields">'
          + '<input type="text" data-repo="' + i + '" data-field="name" value="' + escapeHTML(r.name) + '" placeholder="Display name" style="font-weight:600">'
          + '<div class="kv"><span class="caption" style="width:48px">GitHub</span><input type="text" class="mono" data-repo="' + i + '" data-field="githubSlug" value="' + escapeHTML(r.githubSlug) + '" placeholder="owner/repository" style="flex:1"></div>'
          + '<div class="kv"><span class="caption" style="width:48px">Folder</span><span class="path">' + escapeHTML(r.path) + '</span></div>'
          + '</div>'
          + '<button class="danger" data-remove-repo="' + escapeHTML(r.id) + '" title="Remove this repository from Review Bot">🗑</button>'
          + '</div>').join('');
        list.querySelectorAll('[data-repo]').forEach((input) => {
          input.addEventListener('input', () => {
            const repo = config.repositories[Number(input.dataset.repo)];
            if (!repo) return;
            repo[input.dataset.field] = input.type === 'checkbox' ? input.checked : input.value;
            queueSave();
          });
        });
        list.querySelectorAll('[data-remove-repo]').forEach((button) => {
          button.onclick = async () => {
            const repo = config.repositories.find((r) => r.id === button.dataset.removeRepo);
            if (!repo || !confirm('Remove ' + repo.name + '?\n\nReview Bot stops watching this repository. Your local files are not affected.')) return;
            try { await api('DELETE', 'repositories/' + encodeURIComponent(repo.id)); knownVersion = -1; await poll(); }
            catch (e) { showError(e.message); }
          };
        });
      }

      // Reviewers
      const smallModelMarkers = ['mimo', 'laguna', 'lightning', 'big-pickle', 'hy3', 'mini'];

      function renderReviewers() {
        const container = $('reviewerCards');
        container.innerHTML = snapshot.reviewers.map((d) => {
          const key = reviewerKey(d.name);
          const c = config[key];
          const draft = reviewerDrafts[key] || (reviewerDrafts[key] = { key: '' });
          const usesSavedKey = d.supportsAPIKeyAuth && (c.authMode === 'apiKey' || !d.supportsSessionAuth);
          const disabled = c.enabled ? '' : ' disabled';
          let html = '<div class="box" data-config data-reviewer="' + escapeHTML(d.name) + '">';
          html += '<div class="row"><label style="font-weight:600"><input type="checkbox" data-rv="' + key + '" data-field="enabled"' + (c.enabled ? ' checked' : '') + '> Enable ' + escapeHTML(d.name) + '</label><span class="grow"></span><span data-reviewer-badge="' + escapeHTML(d.name) + '"></span></div>';
          html += '<div class="row"><label class="name">Model</label><input type="text" class="mono grow" style="flex:1" data-rv="' + key + '" data-field="model" value="' + escapeHTML(c.model) + '"' + disabled + '></div>';
          if (d.usesEffortSetting) {
            html += '<div class="row"><label class="name">Effort</label><div class="seg" data-seg="effort" data-rv="' + key + '">' + d.efforts.map((e) => '<button data-value="' + e.value + '"' + (c.effort === e.value ? ' class="on"' : '') + disabled + '>' + escapeHTML(e.label) + '</button>').join('') + '</div></div>';
          }
          html += '<div class="row"><label class="name">Time limit</label><input type="number" min="1" max="240" style="width:80px" data-rv="' + key + '" data-field="timeoutMinutes" value="' + c.timeoutMinutes + '"' + disabled + '> <span>min</span></div>';
          html += '<div class="caption">How long ' + escapeHTML(d.name) + ' may spend on one review before it is cut off. A review that runs out of time contributes nothing, so a large pull request may need more than the default.' + (c.authMode === 'apiKey' ? ' This reviewer is billed to your own key, so a longer limit is also a larger bill for a review that may still not finish.' : '') + '</div>';
          html += '<hr style="border:none;border-top:1px solid var(--border);margin:12px 0">';
          if (d.supportsSessionAuth && d.supportsAPIKeyAuth) {
            html += '<div class="row"><label class="name">Sign-in</label><div class="seg" data-seg="authMode" data-rv="' + key + '"><button data-value="session"' + (c.authMode === 'session' ? ' class="on"' : '') + disabled + '>Signed-in CLI</button><button data-value="apiKey"' + (c.authMode === 'apiKey' ? ' class="on"' : '') + disabled + '>API key</button></div></div>';
            html += '<div class="caption">' + (c.authMode === 'session'
              ? 'Uses whatever <code>' + escapeHTML(d.commandName) + '</code> is already logged in as. Review Bot sends no credentials.'
              : 'Runs <code>' + escapeHTML(d.commandName) + '</code> with <code>' + escapeHTML(d.apiKeyEnvironmentVariable) + '</code> set from the Windows Credential Manager, billing that key instead of the CLI\'s own login.') + '</div>';
          } else if (!d.supportsAPIKeyAuth) {
            html += '<div class="caption">Uses whatever <code>' + escapeHTML(d.commandName) + '</code> is already logged in as. It takes no API key from Review Bot — its provider is chosen in its own configuration — so nothing it spends is billed to a key kept here.</div>';
          }
          if (usesSavedKey) {
            const hasKey = snapshot.reviewersWithSavedKey.includes(d.name);
            html += '<div class="row"><label class="name">API key</label><input type="password" style="flex:1" data-keydraft="' + key + '" placeholder="' + (hasKey ? 'A key is saved — type a new one to replace it' : 'Paste your ' + escapeHTML(d.name) + ' API key') + '" value="' + escapeHTML(draft.key) + '"' + disabled + '><button data-savekey="' + escapeHTML(d.name) + '"' + (draft.key.trim() && c.enabled ? '' : ' disabled') + '>Save</button><button class="danger" data-removekey="' + escapeHTML(d.name) + '"' + (hasKey && c.enabled ? '' : ' disabled') + '>Remove</button></div>';
            html += '<div class="' + (hasKey ? 'good' : 'warn') + '">' + (hasKey ? '🔑 Saved in the Windows Credential Manager, never in config.json.' : '⚠ No key saved. ' + escapeHTML(d.name) + ' reviews will fail until you add one.') + '</div>';
            if (d.needsConfiguredPricing) {
              const p = c.pricing || { inputPerMillion: 0, cachedInputPerMillion: 0, outputPerMillion: 0 };
              const unpriced = p.inputPerMillion <= 0 && p.cachedInputPerMillion <= 0 && p.outputPerMillion <= 0;
              html += '<div class="row" style="margin-top:10px"><label class="name">Prices</label>'
                + priceField(key, 'inputPerMillion', 'Input', p.inputPerMillion, disabled)
                + priceField(key, 'cachedInputPerMillion', 'Cached', p.cachedInputPerMillion, disabled)
                + priceField(key, 'outputPerMillion', 'Output', p.outputPerMillion, disabled)
                + (d.defaultPricing ? '<button data-resetprice="' + key + '"' + (JSON.stringify(p) === JSON.stringify(d.defaultPricing) ? ' disabled' : '') + '>Reset</button>' : '')
                + '</div>';
              html += '<div class="caption">USD per million tokens, written with a dot or a comma. ' + escapeHTML(d.name) + ' reports tokens but not cost, so these rates are what turn them into a dollar figure — check them against your provider\'s current pricing. Set all three to 0 to report tokens only.</div>';
              if (unpriced) html += '<div class="warn">⚠ No rates set, so reviews will report tokens with no cost.</div>';
            } else if (d.reportsTokenUsage) {
              html += '<div class="caption">✓ ' + escapeHTML(d.name) + ' reports its own tokens and cost, so there are no prices to configure.</div>';
            } else {
              html += '<div class="caption">? This CLI does not report token usage, so its cost cannot be tracked.</div>';
            }
          }
          if (smallModelMarkers.some((m) => c.model.toLowerCase().includes(m))) {
            html += '<div class="warn" style="margin-top:8px">⚠ This model is small or experimental: it measurably degrades under adversarial pull-request content, so Review Bot gates its approvals behind injection checks (and never approves when a <code>VERDICT:</code> line appears in the thread or diff).</div>';
          }
          html += '</div>';
          return html;
        }).join('');

        container.querySelectorAll('[data-rv][data-field]').forEach((input) => {
          input.addEventListener('input', () => {
            const c = config[input.dataset.rv];
            const field = input.dataset.field;
            if (input.type === 'checkbox') c[field] = input.checked;
            else if (input.type === 'number') { const n = parseInt(input.value, 10); if (!isNaN(n)) c[field] = Math.min(240, Math.max(1, n)); }
            else c[field] = input.value;
            queueSave();
            if (field === 'enabled') renderReviewers();
          });
        });
        container.querySelectorAll('[data-seg]').forEach((segEl) => {
          segEl.querySelectorAll('button').forEach((button) => {
            button.onclick = () => {
              config[segEl.dataset.rv][segEl.dataset.seg] = button.dataset.value;
              queueSave();
              renderReviewers();
              if (segEl.dataset.seg === 'authMode') setTimeout(poll, 500);
            };
          });
        });
        container.querySelectorAll('[data-keydraft]').forEach((input) => {
          input.addEventListener('input', () => {
            reviewerDrafts[input.dataset.keydraft].key = input.value;
            const save = container.querySelector('[data-savekey="' + input.closest('[data-reviewer]').dataset.reviewer + '"]');
            if (save) save.disabled = input.value.trim() === '';
          });
        });
        container.querySelectorAll('[data-savekey]').forEach((button) => {
          button.onclick = async () => {
            const name = button.dataset.savekey, key = reviewerKey(name);
            const value = reviewerDrafts[key].key;
            reviewerDrafts[key].key = '';
            try { await api('PUT', 'keys/' + encodeURIComponent(name), { key: value }); await poll(); renderReviewers(); }
            catch (e) { showError(e.message); }
          };
        });
        container.querySelectorAll('[data-removekey]').forEach((button) => {
          button.onclick = async () => {
            try { await api('DELETE', 'keys/' + encodeURIComponent(button.dataset.removekey)); await poll(); renderReviewers(); }
            catch (e) { showError(e.message); }
          };
        });
        container.querySelectorAll('[data-price]').forEach((input) => {
          input.addEventListener('input', () => {
            const parsed = parseRate(input.value);
            input.style.color = parsed === null ? 'var(--red)' : '';
            if (parsed === null) return;
            const c = config[input.dataset.rv];
            c.pricing = c.pricing || { inputPerMillion: 0, cachedInputPerMillion: 0, outputPerMillion: 0 };
            c.pricing[input.dataset.price] = parsed;
            queueSave();
          });
          input.addEventListener('blur', () => { if (parseRate(input.value) === null) renderReviewers(); });
        });
        container.querySelectorAll('[data-resetprice]').forEach((button) => {
          button.onclick = () => {
            const d = snapshot.reviewers.find((r) => reviewerKey(r.name) === button.dataset.resetprice);
            config[button.dataset.resetprice].pricing = Object.assign({}, d.defaultPricing);
            queueSave(); renderReviewers();
          };
        });
        renderReviewerLive();
      }

      function priceField(key, field, label, value, disabled) {
        return '<span style="display:inline-grid;gap:2px"><span class="caption" style="margin:0">' + label + '</span><input type="text" class="mono price" data-rv="' + key + '" data-price="' + field + '" value="' + renderRate(value) + '"' + disabled + '></span>';
      }

      function parseRate(text) {
        const normalized = String(text).trim().replace(',', '.');
        if (normalized === '') return null;
        const value = Number(normalized);
        return isFinite(value) && value >= 0 ? value : null;
      }
      function renderRate(value) { return String(Number(value)); }

      function renderReviewerLive() {
        if (!snapshot || !config) return;
        snapshot.reviewers.forEach((d) => {
          const el = document.querySelector('[data-reviewer-badge="' + d.name + '"]');
          if (!el) return;
          if (d.commandName) el.innerHTML = toolBadge(snapshot.toolAvailability[d.commandName] === true, d.commandName);
          else if (snapshot.reviewersWithSavedKey.includes(d.name)) el.innerHTML = '<span class="caption">🌐 HTTP API — key saved</span>';
          else el.innerHTML = '<span class="warn">🌐 HTTP API — no key saved</span>';
        });
      }

      // Decisions
      const decisions = [['approve', 'Approve'], ['request_changes', 'Request changes'], ['comment', 'Leave it to me']];
      function renderDecisions() {
        const rows = [
          { key: null, verdict: 'Blocking', detail: 'Always requests changes.', value: 'request_changes' },
          { key: 'shouldFix', verdict: 'Should-fix', detail: 'Substantive issues that are not release-blocking.' },
          { key: 'nitsOnly', verdict: 'Nits only', detail: 'Minor, optional suggestions.' },
          { key: 'clean', verdict: 'Clean', detail: 'No issues found.' },
        ];
        $('decisionRows').innerHTML = rows.map((row) => {
          const value = row.key ? config.decisionPolicy[row.key] : row.value;
          return '<div class="row" data-config style="padding:6px 0;border-top:' + (row.key === 'shouldFix' ? '1px solid var(--border)' : 'none') + '"><div style="width:220px"><b>' + row.verdict + '</b><div class="caption" style="margin:0">' + row.detail + '</div></div><div class="seg" data-decision="' + (row.key || '') + '">'
            + decisions.map((d) => '<button data-value="' + d[0] + '"' + (value === d[0] ? ' class="on"' : '') + (row.key ? '' : ' disabled') + '>' + d[1] + '</button>').join('') + '</div></div>';
        }).join('');
        $('decisionRows').querySelectorAll('[data-decision]').forEach((segEl) => {
          if (!segEl.dataset.decision) return;
          segEl.querySelectorAll('button').forEach((button) => {
            button.onclick = () => { config.decisionPolicy[segEl.dataset.decision] = button.dataset.value; queueSave(); renderDecisions(); };
          });
        });
        const isDefault = config.decisionPolicy.shouldFix === 'request_changes' && config.decisionPolicy.nitsOnly === 'approve' && config.decisionPolicy.clean === 'approve';
        $('resetPolicy').disabled = isDefault;
      }
      $('resetPolicy').onclick = () => { config.decisionPolicy = { shouldFix: 'request_changes', nitsOnly: 'approve', clean: 'approve' }; queueSave(); renderDecisions(); };

      // ---- history -----------------------------------------------------------------------
      const kinds = {
        requestDetected: ['🔔', 'Review requested', 'blue'], reviewStarted: ['✨', 'Review started', 'blue'],
        approved: ['✅', 'Approved', 'green'], changesRequested: ['🛑', 'Changes requested', 'orange'],
        commented: ['💬', 'Comment posted', 'purple'], failed: ['❌', 'Failed', 'red'],
      };
      let historyTimer = null;
      async function refreshHistory() {
        try {
          const entries = await api('GET', 'history');
          const list = $('historyList');
          $('clearHistory').disabled = entries.length === 0;
          if (entries.length === 0) { list.innerHTML = '<div class="empty">🕓 No activity yet<br><span class="caption">Events will appear after Review Bot checks your repositories.</span></div>'; return; }
          list.innerHTML = entries.map((e) => {
            const k = kinds[e.kind] || ['•', e.kind, 'blue'];
            const where = e.pullRequestNumber != null ? e.repositoryName + ' #' + e.pullRequestNumber : e.repositoryName;
            const usage = e.usage ? (e.usage.costUSD != null ? '$' + (e.usage.costUSD >= 1 ? e.usage.costUSD.toFixed(2) : e.usage.costUSD.toFixed(4)) : abbreviate(e.usage.inputTokens + e.usage.cachedInputTokens + e.usage.outputTokens) + ' tok') : '';
            return '<div class="hist"><div class="icon" style="color:var(--' + k[2] + ')">' + k[0] + '</div><div class="body"><b>' + k[1] + '</b> <span class="caption">' + escapeHTML(where) + '</span>'
              + (e.pullRequestTitle ? '<div>' + escapeHTML(e.pullRequestTitle) + '</div>' : '') + '<div class="msg">' + escapeHTML(e.message) + '</div></div>'
              + '<div class="meta">' + escapeHTML(new Date(e.date).toLocaleString()) + (usage ? '<br>' + escapeHTML(usage) : '') + (e.pullRequestURL ? '<br><a href="' + escapeHTML(e.pullRequestURL) + '" target="_blank" rel="noopener">Open PR</a>' : '') + '</div></div>';
          }).join('');
        } catch (e) { /* the header poll reports connectivity */ }
      }
      function abbreviate(n) { return n >= 1e6 ? (n / 1e6).toFixed(1) + 'M' : n >= 1e3 ? (n / 1e3).toFixed(1) + 'k' : String(n); }

      // ---- wiring ------------------------------------------------------------------------
      $('tabs').querySelectorAll('button').forEach((button) => {
        button.onclick = () => {
          activeTab = button.dataset.tab;
          $('tabs').querySelectorAll('button').forEach((b) => b.classList.toggle('active', b === button));
          document.querySelectorAll('.panel').forEach((p) => p.classList.toggle('active', p.dataset.panel === activeTab));
          if (activeTab === 'history') refreshHistory();
        };
      });
      $('runNow').onclick = () => api('POST', 'run-now').then(poll).catch((e) => showError(e.message));
      $('togglePause').onclick = () => api('POST', 'toggle-paused').then(() => { knownVersion = -1; return poll(); }).catch((e) => showError(e.message));
      $('refreshTools').onclick = () => api('POST', 'refresh-tools').then(poll).catch((e) => showError(e.message));
      $('openData').onclick = () => api('POST', 'open-data-folder').catch((e) => showError(e.message));
      $('clearHistory').onclick = () => { if (confirm('Clear all activity history?\n\nGenerated review files and detailed logs will remain on disk.')) api('POST', 'history/clear').then(refreshHistory).catch((e) => showError(e.message)); };
      $('quit').onclick = () => { if (confirm('Quit Review Bot? Monitoring stops until you start it again.')) api('POST', 'quit').catch(() => {}); };
      $('launchAtLogin').onchange = () => api('PUT', 'launch-at-login', { enabled: $('launchAtLogin').checked }).then(poll).catch((e) => showError(e.message));
      $('pollInterval').onchange = () => { config.pollIntervalMinutes = Number($('pollInterval').value); queueSave(); renderLive(); };
      $('maxConcurrent').oninput = () => { const n = parseInt($('maxConcurrent').value, 10); if (n >= 1 && n <= 8) { config.maxConcurrentReviews = n; $('maxConcurrentLabel').textContent = n === 1 ? 'pull request at a time' : 'pull requests at once'; queueSave(); } };
      $('includeUsage').onchange = () => { config.includeUsageInReview = $('includeUsage').checked; queueSave(); };
      $('reviewScope').querySelectorAll('button').forEach((b) => { b.onclick = () => { config.reviewScope = b.dataset.value; queueSave(); seg($('reviewScope'), config.reviewScope); }; });
      $('limitRounds').onchange = () => { config.maxReviewRoundsPerPR = $('limitRounds').checked ? 3 : null; queueSave(); renderConfig(); };
      $('maxRounds').oninput = () => { const n = parseInt($('maxRounds').value, 10); if (n >= 1) { config.maxReviewRoundsPerPR = n; queueSave(); } };
      $('limitFailures').onchange = () => { config.failureBudget = $('limitFailures').checked ? 5 : 0; queueSave(); renderConfig(); };
      $('failureBudget').oninput = () => { const n = parseInt($('failureBudget').value, 10); if (n >= 1) { config.failureBudget = n; queueSave(); } };
      $('customPrompt').oninput = () => { config.customPrompt = $('customPrompt').value; $('promptCount').textContent = config.customPrompt.length + ' characters'; $('clearPrompt').disabled = config.customPrompt.length === 0; queueSave(); };
      $('clearPrompt').onclick = () => { config.customPrompt = ''; queueSave(); renderConfig(); };
      $('addRepo').onclick = async () => {
        const folder = $('newRepoPath').value.trim();
        if (!folder) return;
        $('addRepo').disabled = true;
        try { await api('POST', 'repositories', { folder }); $('newRepoPath').value = ''; knownVersion = -1; await poll(); }
        catch (e) { showError(e.message); }
        finally { $('addRepo').disabled = false; }
      };
      $('newRepoPath').onkeydown = (event) => { if (event.key === 'Enter') $('addRepo').click(); };
      document.querySelectorAll('#customPrompt, #pollInterval, #maxConcurrent, #includeUsage, #maxRounds, #failureBudget, #newRepoPath').forEach((el) => el.setAttribute('data-config', ''));

      poll();
      setInterval(poll, 2000);
    })();
    </script>
    </body>
    </html>
    """#
}
