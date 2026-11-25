// Shared by the page (app.js) and the service worker (sw.js). Classic script.
(function (root) {
  const HOUR = 3600e3;
  // Reminder thresholds, in hours before an event ends.
  const THRESHOLDS = [72, 24, 3];

  function remainingLabel(ms) {
    if (ms <= 0) return '終了';
    const h = Math.floor(ms / HOUR);
    if (h >= 24) return `あと${Math.floor(h / 24)}日${h % 24 ? `${h % 24}時間` : ''}`;
    if (h >= 1) return `あと${h}時間`;
    return `あと${Math.max(1, Math.floor(ms / 60e3))}分`;
  }

  // Returns { due: [{event, hours}], notified } where `notified` is the updated map.
  // Only the tightest newly-crossed threshold fires, so opening the app after a
  // long break produces one reminder per event instead of three.
  function collectDue(events, state, now) {
    const notified = Object.assign({}, state.notified);
    const enabled = (state.notify && state.notify.hours) || THRESHOLDS;
    const due = [];
    for (const ev of events) {
      if (state.done && state.done[ev.id]) continue;
      if (state.hiddenEv && state.hiddenEv[ev.id]) continue;
      if (state.hiddenGames && state.hiddenGames[ev.game]) continue;
      if (state.cats && state.cats[ev.cat] === false) continue;
      if (state.rewardOnly && !ev.reward) continue;
      const left = Date.parse(ev.end) - now;
      if (left <= 0 || Date.parse(ev.start) > now) continue;
      const crossed = enabled.filter((h) => left <= h * HOUR);
      if (!crossed.length) continue;
      const tightest = Math.min(...crossed);
      const fresh = !notified[`${ev.id}:${tightest}`];
      for (const h of crossed) notified[`${ev.id}:${h}`] = 1;
      if (fresh) due.push({ event: ev, hours: tightest, left });
    }
    due.sort((a, b) => a.left - b.left);
    return { due, notified };
  }

  function buildNotifications(due, gameName) {
    if (!due.length) return [];
    if (due.length > 3) {
      const first = due[0];
      return [{
        title: `もうすぐ終了するイベントが${due.length}件`,
        body: due.slice(0, 4).map((d) => `${remainingLabel(d.left)}：${gameName(d.event.game)} ${d.event.title}`).join('\n'),
        tag: `gc-summary-${first.event.id}`,
      }];
    }
    return due.map((d) => ({
      title: `${remainingLabel(d.left)}：${gameName(d.event.game)}`,
      body: d.event.title,
      tag: `gc-${d.event.id}`,
    }));
  }

  root.GCNotify = { THRESHOLDS, remainingLabel, collectDue, buildNotifications };
})(self);
