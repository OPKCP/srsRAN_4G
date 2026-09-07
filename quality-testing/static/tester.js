/* =============================================================================
 * srsRAN_4G -- клиент тестера канала (самостоятельный, без внешних библиотек).
 * Задачи:
 *   1. Непрерывный "пинг" шлюза (HTTP-RTT), скользящее среднее, потери за 100.
 *   2. Тест скорости: скачивает /api/stream (бесконечный поток), считает Мбит/с.
 *   3. WebSocket /ws: heartbeat состояния + приём команд (reload, speed start/stop).
 * Модель: pull. Сервер шлёт команды по WS; клиент по команде reload делает reload.
 * ============================================================================= */

(function () {
  "use strict";

  // --- Конфиг ---
  // "Шлюз" для пинга: сам веб-сервер (10.0.0.1:8080). Замеряем RTT HTTP.
  var GATEWAY_URL = "/";
  var WS_URL = (location.protocol === "https:" ? "wss://" : "ws://")
    + location.host + "/ws";
  var STREAM_URL = "/api/stream";
  var PING_INTERVAL = 1000;      // 1 пинг в секунду
  var LOSS_WINDOW = 100;         // сколько последних пингов учитываем для потерь
  var AVG_WINDOW = 20;           // окно скользящего среднего пинга
  var SPEED_REPORT_MS = 1000;    // частота обновления цифры скорости
  var MIN_PING_TIMEOUT = 3000;   // мин. таймаут пинга (мс)
  var MAX_PING_TIMEOUT = 20000;  // макс. таймаут пинга (мс)

  var clientIp = window.__CLIENT_IP__ || "unknown";
  var $ = function (id) { return document.getElementById(id); };

  // ---- Элементы ----
  var elPingNow = $("ping-now"), elPingAvg = $("ping-avg"), elPingLoss = $("ping-loss");
  var elSpeed = $("speed"), elSpeedState = $("speed-state");
  var elWsState = $("ws-state");
  var btnStart = $("speed-start"), btnStop = $("speed-stop");
  var sparkEl = $("spark");
  var elSessionTimer = $("session-timer");
  var elEnb = $("enb-name");

  $("client-ip").textContent = clientIp;

  // ---- Таймер времени с момента загрузки страницы (сессии) ----
  var pageLoadTs = Date.now();
  function updateSessionTimer() {
    if (!elSessionTimer) return;
    var s = Math.floor((Date.now() - pageLoadTs) / 1000);
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
    var mm = m < 10 ? "0" + m : "" + m;
    var ss = sec < 10 ? "0" + sec : "" + sec;
    elSessionTimer.textContent = (h > 0 ? h + ":" : "") + mm + ":" + ss;
  }
  setInterval(updateSessionTimer, 1000);
  updateSessionTimer();

  // ---- Состояние пинга ----
  var pingResults = [];           // массив {t, ok, ms}, последние LOSS_WINDOW
  var lastPingOk = null;
  var lastPingMs = null;

  // ---- Состояние скорости ----
  var speedActive = false;
  var speedController = null;     // AbortController
  var speedMbps = null;
  var speedBytes = 0;
  var speedStartTs = 0;
  var speedRetryTimer = null;     // таймер повторного подключения после обрыва
  var speedReconnectMs = 2000;    // базовый интервал повторного подключения стрима

  // ---- WebSocket ----
  var ws = null;
  var wsConnected = false;
  var wsHeartbeatTimer = null;
  var wsReconnectTimer = null;

  // ===========================================================================
  // Пинг шлюза (HTTP RTT)
  // ===========================================================================
  // Текущий динамический таймаут пинга (обновляется по среднему пингу)
  var pingTimeout = MIN_PING_TIMEOUT;

  function dynamicTimeout() {
    // удвоенное среднее, но в пределах [MIN, MAX]
    var okMs = pingResults.filter(function (p) { return p.ok && p.ms != null; })
      .map(function (p) { return p.ms; });
    var recent = okMs.slice(-AVG_WINDOW);
    if (!recent.length) return MIN_PING_TIMEOUT;
    var avg = recent.reduce(function (a, b) { return a + b; }, 0) / recent.length;
    var t = Math.round(avg * 2);
    return Math.max(MIN_PING_TIMEOUT, Math.min(t, MAX_PING_TIMEOUT));
  }

  function doPing() {
    pingTimeout = dynamicTimeout();
    var t0 = performance.now();
    var controller = new AbortController();
    var timer = setTimeout(function () { controller.abort(); }, pingTimeout);
    fetch(GATEWAY_URL, { cache: "no-store", signal: controller.signal, method: "GET" })
      .then(function (r) { return r.text(); })
      .then(function () {
        clearTimeout(timer);
        var ms = performance.now() - t0;
        recordPing(true, ms);
      })
      .catch(function () {
        clearTimeout(timer);
        recordPing(false, null);
      });
  }

  function recordPing(ok, ms) {
    pingResults.push({ t: Date.now(), ok: ok, ms: ms });
    if (pingResults.length > LOSS_WINDOW) pingResults.shift();

    lastPingOk = ok;
    lastPingMs = ok ? ms : null;

    // Мгновенное
    elPingNow.textContent = ok ? ms.toFixed(1) + " мс" : "потеря";
    elPingNow.className = "val" + (ok ? "" : " bad");

    // Скользящее среднее по ok-пингам из окна
    var okMs = pingResults.filter(function (p) { return p.ok && p.ms != null; })
      .map(function (p) { return p.ms; });
    var recent = okMs.slice(-AVG_WINDOW);
    var avg = recent.length
      ? recent.reduce(function (a, b) { return a + b; }, 0) / recent.length
      : null;
    elPingAvg.textContent = avg != null ? avg.toFixed(1) + " мс" : "—";

    // Потери за последние 100
    var window = pingResults.slice(-LOSS_WINDOW);
    var lost = window.filter(function (p) { return !p.ok; }).length;
    elPingLoss.textContent = lost + " / " + window.length;

    drawSpark();
    reportState();
  }

  // Сброс счётчика потерь и истории пингов (для замеров на окне перехода).
  function resetPingCounters() {
    pingResults = [];
    lastPingOk = null;
    lastPingMs = null;
    if (elPingNow) elPingNow.textContent = "—";
    if (elPingAvg) elPingAvg.textContent = "—";
    if (elPingLoss) elPingLoss.textContent = "0";
    if (sparkEl) sparkEl.innerHTML = "";
    reportState();
  }

  // ---- Мини-график (canvas из div-полосок, чтобы не тянуть библиотеки) ----
  // Рисуем фиксированное "окно" последних пинов, равномерно распределённых по
  // ширине блока. За счёт flex (каждая полоска flex:1) и overflow:hidden у
  // контейнера график никогда не вылезает за пределы блока/экрана.
  var SPARK_WINDOW = 60;   // сколько последних пингов показывать на графике

  function drawSpark() {
    if (!sparkEl) return;
    var data = pingResults.slice(-SPARK_WINDOW);
    if (!data.length) { sparkEl.innerHTML = ""; return; }
    var maxMs = Math.max.apply(null, data.map(function (p) { return p.ms || 0; }).concat([50]));
    var html = "";
    for (var i = 0; i < data.length; i++) {
      var p = data[i];
      var h = p.ok ? Math.max(4, (p.ms / maxMs) * 42) : 42;
      var col = p.ok ? "#198754" : "#dc3545";
      html += '<i title="' + (p.ok ? p.ms.toFixed(1) + "ms" : "loss")
        + '" style="height:' + h.toFixed(0) + 'px;background:' + col + '"></i>';
    }
    sparkEl.innerHTML = html;
  }

  // ===========================================================================
  // Тест скорости (загрузка бесконечного потока /api/stream)
  // Устойчивость к обрыву сети: при разрыве стрим разрывается, но тест НЕ
  // завершается — повторно подключаемся и продолжаем (после восстановления сети).
  // ===========================================================================
  function startSpeed() {
    if (speedActive) return;
    speedActive = true;
    speedBytes = 0;
    speedStartTs = performance.now();
    speedMbps = null;
    setSpeedState("working");
    btnStart.disabled = true;
    btnStop.disabled = false;
    reportState();
    openSpeedStream();   // начинает загрузку (и переподключение при обрыве)
  }

  // Открывает/переоткрывает поток /api/stream.
  function openSpeedStream() {
    if (!speedActive) return;
    if (speedRetryTimer) { clearTimeout(speedRetryTimer); speedRetryTimer = null; }

    speedController = new AbortController();
    fetch(STREAM_URL, { cache: "no-store", signal: speedController.signal })
      .then(function (r) {
        if (!r.ok || !r.body) throw new Error("bad stream");
        var reader = r.body.getReader();
        setSpeedState("working");

        // сброс точки отсчёта при (пере)подключении, чтобы скорость была честной
        speedBytes = 0;
        speedStartTs = performance.now();

        function onChunk() {
          var now = performance.now();
          var dt = (now - speedStartTs) / 1000;
          if (dt > 0.5) {
            speedMbps = (speedBytes * 8) / dt / 1e6;  // бит/с -> Мбит/с
            elSpeed.textContent = speedMbps.toFixed(2) + " Мбит/с";
            reportState();
          }
        }

        function pump() {
          return reader.read().then(function (res) {
            if (res.done) { onStreamClosed(); return; }
            speedBytes += res.value ? res.value.byteLength : 0;
            onChunk();
            if (speedActive) return pump();
            else return reader.cancel();
          }).catch(function () {
            if (speedActive) onStreamClosed();
          });
        }
        return pump();
      })
      .catch(function () {
        if (speedActive) onStreamClosed();
      });
  }

  // Вызывается при обрыве/окончании потока, пока тест активен -> переподключаемся.
  function onStreamClosed() {
    if (!speedActive) return;
    setSpeedState("reconnecting");
    elSpeed.textContent = "… (переподключение)";
    reportState();
    // Не грузим канал, пока сеть полностью не восстановилась? Наоборот —
    // пытаемся снова; интервал берём побольше, чтобы не долбить в пустоту.
    speedRetryTimer = setTimeout(openSpeedStream, speedReconnectMs);
  }

  function stopSpeed() {
    speedActive = false;
    if (speedController) try { speedController.abort(); } catch (e) {}
    if (speedRetryTimer) { clearTimeout(speedRetryTimer); speedRetryTimer = null; }
    finishSpeed(false);
  }

  function finishSpeed(complete) {
    if (speedRetryTimer) { clearTimeout(speedRetryTimer); speedRetryTimer = null; }
    speedActive = false;
    if (speedController) try { speedController.abort(); } catch (e) {}
    btnStart.disabled = false;
    btnStop.disabled = true;
    if (!complete && !speedMbps) elSpeed.textContent = "—";
    else if (speedMbps) elSpeed.textContent = speedMbps.toFixed(2) + " Мбит/с (итог)";
    setSpeedState(complete ? "done" : "stopped");
    reportState();
  }

  function setSpeedState(s) {
    elSpeedState.textContent = s;
    reportState();
  }

  // ===========================================================================
  // Отчёт о состоянии клиента на сервер (heartbeat + по событию)
  // ===========================================================================
  function currentState() {
    var okMs = pingResults.filter(function (p) { return p.ok && p.ms != null; })
      .map(function (p) { return p.ms; });
    var avg = okMs.slice(-AVG_WINDOW);
    var avgV = avg.length ? avg.reduce(function (a, b) { return a + b; }, 0) / avg.length : null;
    var win = pingResults.slice(-LOSS_WINDOW);
    var lost = win.filter(function (p) { return !p.ok; }).length;
    return {
      ping_ms: lastPingMs != null ? Math.round(lastPingMs * 10) / 10 : null,
      ping_avg_ms: avgV != null ? Math.round(avgV * 10) / 10 : null,
      lost_last100: lost,
      ping_window: win.length,
      speed_mbps: speedMbps != null ? Math.round(speedMbps * 100) / 100 : null,
      speed_state: speedActive ? "working" : "idle",
      now: Date.now(),
    };
  }

  function reportState() {
    if (ws && wsConnected && ws.readyState === WebSocket.OPEN) {
      try {
        ws.send(JSON.stringify({ type: "status", data: currentState() }));
      } catch (e) {}
    }
  }

  // ===========================================================================
  // WebSocket: heartbeat + команды
  // ===========================================================================
  function connectWs() {
    if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;
    try { ws = new WebSocket(WS_URL); } catch (e) { scheduleReconnect(); return; }
    ws.onopen = function () {
      wsConnected = true;
      elWsState.textContent = "подключено";
      elWsState.className = "ok";
      ws.send(JSON.stringify({ type: "hello" }));
      reportState();
      // heartbeat каждые 7с
      wsHeartbeatTimer = setInterval(function () { reportState(); }, 7000);
      clearTimeout(wsReconnectTimer);
    };
    ws.onmessage = function (ev) {
      try { handleMessage(JSON.parse(ev.data)); } catch (e) {}
    };
    ws.onclose = function () {
      wsConnected = false;
      elWsState.textContent = "отключено";
      elWsState.className = "bad";
      if (wsHeartbeatTimer) clearInterval(wsHeartbeatTimer);
      scheduleReconnect();
    };
    ws.onerror = function () { try { ws.close(); } catch (e) {} };
  }

  function scheduleReconnect() {
    clearTimeout(wsReconnectTimer);
    wsReconnectTimer = setTimeout(connectWs, 3000);
  }

  function handleMessage(msg) {
    if (!msg) return;

    // Подтверждение идентификации (IP) + текущая БС
    if (msg.type === "welcome") {
      if (msg.enb && elEnb) elEnb.textContent = msg.enb;
      return;
    }

    // Серверный ping -> обязаны ответить pong (для отслеживания живости)
    if (msg.type === "srv-ping") {
      if (ws && ws.readyState === WebSocket.OPEN) {
        try { ws.send(JSON.stringify({ type: "pong", ts: msg.ts })); } catch (e) {}
      }
      return;
    }

    // Карта клиент -> БС из логов ядра
    if (msg.type === "enb-map") {
      var map = msg.map || {};
      if (map[clientIp] && elEnb) {
        elEnb.textContent = map[clientIp];
      }
      return;
    }

    // Персональная актуальная БС клиента (шлётся регулярно)
    if (msg.type === "enb") {
      if (msg.enb && elEnb) elEnb.textContent = msg.enb;
      return;
    }

    if (msg.type !== "cmd") return;
    var cmd = msg.cmd;
    if (cmd === "reload") {
      location.reload();
    } else if (cmd === "speed") {
      var act = msg.data && msg.data.action;
      if (act === "start") startSpeed();
      else if (act === "stop") stopSpeed();
    } else if (cmd === "ping-once") {
      doPing();
    } else if (cmd === "reset-ping") {
      // сброс счётчика потерь/истории пингов (перед окном перехода)
      resetPingCounters();
    } else if (cmd === "page-state") {
      // отладочный канал: сервер просит клиента прислать состояние страницы
      if (ws && ws.readyState === WebSocket.OPEN) {
        try {
          ws.send(JSON.stringify({ type: "page-state",
            data: {
              ip: clientIp,
              enb: elEnb ? elEnb.textContent : "",
              url: location.href,
              title: document.title,
              ws_state: elWsState ? elWsState.textContent : "",
              speed_state: elSpeedState ? elSpeedState.textContent : "",
              ping_now: elPingNow ? elPingNow.textContent : "",
              ping_avg: elPingAvg ? elPingAvg.textContent : "",
              ping_loss: elPingLoss ? elPingLoss.textContent : "",
              speed: elSpeed ? elSpeed.textContent : "",
              session: elSessionTimer ? elSessionTimer.textContent : "",
              ts: Date.now(),
            }
          }));
        } catch (e) {}
      }
    }
  }

  // ===========================================================================
  // Запуск
  // ===========================================================================
  btnStart.addEventListener("click", startSpeed);
  btnStop.addEventListener("click", stopSpeed);

  doPing();
  setInterval(doPing, PING_INTERVAL);
  connectWs();
})();
