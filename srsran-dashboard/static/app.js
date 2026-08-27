/* Клиент дашборда: получение снимка состояния и поток событий (SSE). */
(function () {
  "use strict";

  const els = {
    modeBadge: document.getElementById("mode-badge"),
    connStatus: document.getElementById("conn-status"),
    uptime: document.getElementById("uptime"),
    logState: document.getElementById("log-state"),
    updated: document.getElementById("updated"),
    kpiAttached: document.getElementById("kpi-attached"),
    kpiSubs: document.getElementById("kpi-subscribers"),
    kpiBs: document.getElementById("kpi-bs"),
    kpiActiveUe: document.getElementById("kpi-active-ue"),
    subsBody: document.getElementById("subs-body"),
    bsBody: document.getElementById("bs-body"),
    events: document.getElementById("events"),
    radioCard: document.getElementById("radio-card"),
    radioBody: document.getElementById("radio-body"),
  };

  const mode = document.body.dataset.mode || "epc";
  els.modeBadge.textContent = mode === "epc" ? "Режим: ядро EPC" : "Режим: БС (eNB)";

  const stateMap = {
    attached: "подключен",
    connecting: "подключение…",
    detached: "отключен",
    unknown: "неизвестно",
  };

  function ago(sec) {
    if (sec === null || sec === undefined) return "—";
    if (sec < 60) return Math.round(sec) + " с";
    if (sec < 3600) return Math.round(sec / 60) + " мин";
    return (sec / 3600).toFixed(1) + " ч";
  }

  function fmtBytesKbps(v) {
    v = Number(v) || 0;
    if (v >= 1000) return (v / 1000).toFixed(1) + " Мбит/с";
    return v.toFixed(1) + " кбит/с";
  }

  function renderSubscribers(subs) {
    if (!subs || subs.length === 0) {
      els.subsBody.innerHTML = '<tr><td colspan="6" class="empty">Абонентов пока нет</td></tr>';
      return;
    }
    els.subsBody.innerHTML = subs.map(function (s) {
      return "<tr>" +
        "<td>" + s.imsi + "</td>" +
        "<td>" + (s.ip || "—") + "</td>" +
        '<td><span class="state-badge state-' + s.state + '">' + (stateMap[s.state] || s.state) + "</span></td>" +
        "<td>" + (s.enb_ue_s1ap_id || "—") + "</td>" +
        "<td>" + ago(s.last_attach_ago) + "</td>" +
        "<td>" + ago(s.last_seen_ago) + "</td>" +
        "</tr>";
    }).join("");
  }

  function renderBaseStations(bs) {
    if (!bs || bs.length === 0) {
      els.bsBody.innerHTML = '<tr><td colspan="4" class="empty">Нет базовых станций</td></tr>';
      return;
    }
    els.bsBody.innerHTML = bs.map(function (b) {
      return "<tr>" +
        "<td>" + (b.name || "—") + "</td>" +
        "<td>" + (b.enb_id || "—") + "</td>" +
        "<td>" + ago(b.connected_ago) + "</td>" +
        "<td>" + ago(b.last_seen_ago) + "</td>" +
        "</tr>";
    }).join("");
  }

  function renderMetrics(m) {
    const ues = (m && m.ues) || [];
    els.kpiActiveUe.textContent = ues.length;
    if (mode !== "enb") return;
    els.radioCard.style.display = "block";
    if (ues.length === 0) {
      els.radioBody.innerHTML = '<tr><td colspan="8" class="empty">Нет активных UE</td></tr>';
      return;
    }
    els.radioBody.innerHTML = ues.map(function (u) {
      return "<tr>" +
        "<td>" + (u.ue_rnti !== undefined ? u.ue_rnti : "—") + "</td>" +
        "<td>" + (u.dl_cqi !== undefined ? u.dl_cqi : "—") + "</td>" +
        "<td>" + (u.dl_mcs !== undefined ? u.dl_mcs : "—") + "</td>" +
        "<td>" + (u.ul_mcs !== undefined ? u.ul_mcs : "—") + "</td>" +
        "<td>" + (u.dl_bitrate !== undefined ? fmtBytesKbps(u.dl_bitrate * 8) : "—") + "</td>" +
        "<td>" + (u.ul_bitrate !== undefined ? fmtBytesKbps(u.ul_bitrate * 8) : "—") + "</td>" +
        "<td>" + (u.dl_bler !== undefined ? (u.dl_bler * 100).toFixed(1) + "%" : "—") + "</td>" +
        "<td>" + (u.ul_snr !== undefined ? u.ul_snr : "—") + "</td>" +
        "</tr>";
    }).join("");
  }

  function renderEvents(events) {
    if (events && events.length) {
      const html = events.map(function (e) {
        return '<div class="event ' + e.level + '"><span class="t">' + e.ts_str + "</span> " +
          "<b>[" + e.source + " / " + e.category + "]</b> " + e.message + "</div>";
      }).join("");
      els.events.innerHTML = html;
    }
  }

  function renderSnapshot(snap) {
    if (!snap) return;
    els.kpiAttached.textContent = snap.attached_count || 0;
    els.kpiSubs.textContent = snap.subscribers_count || 0;
    els.kpiBs.textContent = snap.base_stations_count || 0;
    els.uptime.textContent = "аптайм " + ago(snap.uptime);
    renderBaseStations(snap.base_stations);

    const sys = snap.system || {};
    if (sys.log_file) {
      els.logState.textContent = "лог: " + sys.log_file + " (" + (sys.bytes_parsed || 0) + " Б)";
    }
    renderMetrics(snap.metrics);
    els.updated.textContent = new Date().toLocaleTimeString("ru-RU");
  }

  async function loadSnapshot() {
    try {
      const r = await fetch("/api/snapshot");
      const snap = await r.json();
      renderSnapshot(snap);
      renderSubscribers(snap.subscribers || []);
      renderEvents(null);
      els.connStatus.textContent = "онлайн";
      els.connStatus.className = "pill green";
    } catch (e) {
      els.connStatus.textContent = "нет связи";
      els.connStatus.className = "pill red";
    }
  }

  async function loadSubscribers() {
    try {
      const r = await fetch("/api/subscribers");
      renderSubscribers(await r.json());
    } catch (e) { /* ignored */ }
  }

  async function loadEvents() {
    try {
      const r = await fetch("/api/events?limit=60");
      renderEvents(await r.json());
    } catch (e) { /* ignored */ }
  }

  function connectSSE() {
    const es = new EventSource("/api/stream");
    es.onmessage = function (ev) {
      let msg;
      try { msg = JSON.parse(ev.data); } catch (e) { return; }
      if (msg.type === "snapshot" && msg.snapshot) {
        renderSnapshot(msg.snapshot);
      }
      if (msg.type === "events" && msg.events && msg.events.length) {
        const first = [msg.events[0]];
        renderEvents(first);
      }
    };
    es.onerror = function () {
      els.connStatus.textContent = "переподключение…";
      els.connStatus.className = "pill gray";
      es.close();
      setTimeout(connectSSE, 3000);
    };
  }

  // начальная загрузка
  loadSnapshot();
  loadSubscribers();
  loadEvents();
  connectSSE();

  // периодическое обновление списка абонентов (лексически в дополнение к SSE)
  setInterval(loadSubscribers, 5000);
})();
