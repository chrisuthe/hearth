import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/hearth_colors.dart';
import '../../config/hub_config.dart';
import '../../modules/alarm_clock/alarm_editor_screen.dart';
import '../../modules/alarm_clock/alarm_models.dart';
import '../../modules/alarm_clock/alarm_service.dart';
import '../../modules/alarm_clock/sunrise_controller.dart';
import '../../services/home_assistant_service.dart';
import '../framework/plugin_router.dart';
import '../framework/web_context.dart';
import '../hearth_plugin.dart';

/// Alarm Clock plugin.
///
/// Alarms are managed by [AlarmService] (persisted to `alarms.json`), not
/// HubConfig — so the plugin's on-device panel watches the service and
/// hands off add/edit/delete to the existing [AlarmEditorScreen].
///
/// The web portal reaches the same [AlarmService] singleton through this
/// plugin's HTTP routes (the browser has no direct service access):
///   * GET  `alarms`        — the live alarm list, available builtin tones and
///     the lights a sunrise can ramp.
///   * POST `alarms/save`   — upsert one alarm (add when its id is unknown,
///     otherwise update in place).
///   * POST `alarms/delete` — remove one alarm by id.
/// Because both surfaces mutate the one service, edits on web and on-device
/// stay consistent. The web-parity drift-guard only covers HubConfig fields,
/// so alarm CRUD is covered by explicit route tests instead.
///
/// Deferred for later sessions:
///   * Owning the PageView screen via [pageScreen]
class AlarmClockPlugin extends HearthPlugin {
  @override
  String get id => 'hearth.alarm_clock';

  @override
  String get name => 'Alarm Clock';

  @override
  IconData get icon => Icons.alarm;

  @override
  PluginCategory get category => PluginCategory.feature;

  @override
  int get order => 70;

  @override
  bool get isCommunity => false;

  @override
  PluginConfigStatus statusFor(HubConfig config) {
    // Alarms live in AlarmService, not HubConfig — there's no config the
    // user must fill in. Always report configured; the panel itself
    // surfaces the empty-state message.
    return PluginConfigStatus.configured;
  }

  @override
  Widget buildSettingsWidget(WidgetRef ref) {
    return const _AlarmClockPanel();
  }

  // Web settings: a live, editable alarm list. The fragment is self-contained
  // — it fetches the current alarms + tones from the `alarms` GET route and
  // persists add/edit/delete through the `alarms/save` and `alarms/delete`
  // routes below, all reached via `hearth.action` (scoped to this plugin's
  // prefix). No `data-config-path` marker: alarms live in AlarmService, not
  // HubConfig, so they're outside the web-parity drift-guard's ledger.
  @override
  String buildSettingsHtml(WebContext ctx) => _alarmsHtml;

  /// Routes backing the web alarm editor. All three reach the live
  /// [AlarmService] via [PluginRequest.readProvider] — the same singleton the
  /// on-device screen mutates, so the two surfaces never diverge.
  @override
  void registerHttpRoutes(PluginRouter router) {
    // GET alarms — the current alarm list (each with a human day summary for
    // the row) plus the builtin tones and lights the editor's pickers offer.
    router.get('alarms', (req) async {
      final service = req.readProvider(alarmServiceProvider);
      await req.respondJson({
        'alarms': [
          for (final a in service.alarms)
            {...a.toJson(), 'daySummary': a.daySummary},
        ],
        'tones': [
          for (final e in builtinTones.entries) {'id': e.key, 'name': e.value},
        ],
        'lights': [
          for (final light in sunriseLightChoices(
              req.readProvider(homeAssistantServiceProvider).entities.values))
            {'id': light.entityId, 'name': light.name},
        ],
      });
    });

    // POST alarms/save — upsert one alarm. A body without a known id is a new
    // alarm (id minted by Alarm.fromJson); a body whose id matches an existing
    // alarm updates it in place.
    router.post('alarms/save', (req) async {
      final service = req.readProvider(alarmServiceProvider);
      final alarm = Alarm.fromJson(req.body);
      final exists = service.alarms.any((a) => a.id == alarm.id);
      if (exists) {
        service.updateAlarm(alarm);
      } else {
        service.addAlarm(alarm);
      }
      await req.respondJson({'status': 'saved', 'id': alarm.id});
    });

    // POST alarms/delete — remove one alarm by id.
    router.post('alarms/delete', (req) async {
      final service = req.readProvider(alarmServiceProvider);
      final id = req.body['id'] as String?;
      if (id == null || id.isEmpty) {
        await req.respondError(400, 'Missing alarm id');
        return;
      }
      service.deleteAlarm(id);
      await req.respondJson({'status': 'deleted', 'id': id});
    });
  }
}

class _AlarmClockPanel extends ConsumerWidget {
  const _AlarmClockPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.hearthColors;
    final service = ref.watch(alarmServiceProvider);
    final alarms = service.alarms;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (alarms.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'No alarms set. Tap "Open Alarm Editor" below to add one.',
              style: TextStyle(
                color: c.textMuted,
                fontStyle: FontStyle.italic,
              ),
            ),
          )
        else
          for (final alarm in alarms)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.alarm,
                color: alarm.enabled ? c.text : c.textFaint,
              ),
              title: Text(
                alarm.time,
                style: TextStyle(
                  color: alarm.enabled ? c.text : c.textMuted,
                  fontSize: 18,
                ),
              ),
              subtitle: Text(
                alarm.label.isEmpty
                    ? alarm.daySummary
                    : '${alarm.label} • ${alarm.daySummary}',
                style: TextStyle(color: c.textMuted),
              ),
            ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.edit),
            label: const Text('Open Alarm Editor'),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  settings: const RouteSettings(name: 'alarm_editor'),
                  builder: (_) => const AlarmEditorScreen(),
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: c.accentFill,
              foregroundColor: c.onAccent,
            ),
          ),
        ),
      ],
    );
  }
}

/// Self-contained HTML + JS for the web alarm editor. No server-side
/// interpolation: the panel fetches its alarms, tones and lights at runtime from the
/// `alarms` GET route and persists through the `alarms/save` and
/// `alarms/delete` POST routes (both via `hearth.action`, which scopes to this
/// plugin's prefix). Values are written with `textContent` / form properties,
/// never string-built HTML, so user labels can't inject markup.
const _alarmsHtml = r'''
<style>
  #alarm-panel .al-row {
    display: flex; align-items: center; gap: 10px;
    padding: 10px 12px; background: #161618; border-radius: 6px; margin-bottom: 6px;
  }
  #alarm-panel .al-main { flex: 1; min-width: 0; }
  #alarm-panel .al-time { font-size: 16px; color: #e0e0e0; }
  #alarm-panel .al-sub { font-size: 12px; color: #888; }
  #alarm-panel .al-row.al-off .al-time,
  #alarm-panel .al-row.al-off .al-sub { color: #555; }
  #alarm-panel button.al-btn {
    background: none; border: none; color: #646cff; cursor: pointer;
    font-size: 13px; padding: 4px 8px;
  }
  #alarm-panel button.al-del { color: #ff5252; }
  #alarm-panel .al-add {
    display: inline-flex; align-items: center; gap: 6px; margin-top: 8px;
    padding: 8px 14px; background: #646cff; color: #fff; border: none;
    border-radius: 6px; cursor: pointer; font-size: 14px;
  }
  #alarm-editor {
    margin-top: 14px; padding: 14px; background: #0e0e10;
    border: 1px solid #2a2a2e; border-radius: 8px;
  }
  #alarm-editor label.al-flabel {
    display: block; font-size: 12px; color: #888; margin: 10px 0 4px;
  }
  #alarm-editor input[type=text], #alarm-editor input[type=time],
  #alarm-editor select {
    width: 100%; padding: 9px 12px; background: #161618; border: 1px solid #333;
    border-radius: 6px; color: #e0e0e0; font-size: 14px; outline: none;
    box-sizing: border-box;
  }
  #alarm-editor input:focus, #alarm-editor select:focus { border-color: #646cff; }
  #alarm-editor .al-days { display: flex; gap: 6px; flex-wrap: wrap; }
  #alarm-editor .al-day {
    width: 36px; height: 36px; border-radius: 50%; border: 1px solid #333;
    background: #161618; color: #aaa; cursor: pointer; font-size: 13px;
  }
  #alarm-editor .al-day.on { background: #646cff; color: #fff; border-color: #646cff; }
  #alarm-editor .al-check {
    display: flex; align-items: center; gap: 8px; margin-top: 12px;
    color: #e0e0e0; font-size: 14px;
  }
  #alarm-editor .al-check input { accent-color: #646cff; }
  #alarm-editor .al-actions { display: flex; gap: 10px; margin-top: 16px; }
  #alarm-editor .al-save {
    flex: 1; padding: 10px; background: #646cff; color: #fff; border: none;
    border-radius: 6px; cursor: pointer; font-size: 14px;
  }
  #alarm-editor .al-cancel {
    padding: 10px 14px; background: #222; color: #ccc; border: none;
    border-radius: 6px; cursor: pointer; font-size: 14px;
  }
  #alarm-status { font-size: 12px; color: #666; margin-top: 8px; }
</style>
<div class="field" id="alarm-panel">
  <label>Alarms</label>
  <div id="alarm-list">Loading alarms…</div>
  <button type="button" class="al-add" id="alarm-add">+ Add alarm</button>
  <div id="alarm-editor" hidden></div>
  <div id="alarm-status"></div>
</div>
<script>
(function () {
  // [label, ISO weekday] — Mon=1 .. Sun=7, matching Alarm.days.
  var DAYS = [['M', 1], ['T', 2], ['W', 3], ['T', 4], ['F', 5], ['S', 6], ['S', 7]];

  function init() {
    var listEl = document.getElementById('alarm-list');
    var addBtn = document.getElementById('alarm-add');
    var editorEl = document.getElementById('alarm-editor');
    var statusEl = document.getElementById('alarm-status');
    if (!listEl) return;
    var alarms = [];
    var tones = [];
    var lights = [];

    function status(msg) { statusEl.textContent = msg || ''; }

    function load() {
      hearth.action('alarms').then(function (data) {
        alarms = data.alarms || [];
        tones = data.tones || [];
        lights = data.lights || [];
        renderList();
      }).catch(function (e) {
        listEl.textContent = 'Failed to load alarms.';
        console.error(e);
      });
    }

    function renderList() {
      listEl.textContent = '';
      if (!alarms.length) {
        var empty = document.createElement('div');
        empty.style.cssText = 'color:#666;font-style:italic;padding:8px 0';
        empty.textContent = 'No alarms yet.';
        listEl.appendChild(empty);
        return;
      }
      alarms.forEach(function (a) {
        var row = document.createElement('div');
        row.className = 'al-row' + (a.enabled ? '' : ' al-off');
        var main = document.createElement('div');
        main.className = 'al-main';
        var t = document.createElement('div');
        t.className = 'al-time';
        t.textContent = a.time + (a.label ? ' · ' + a.label : '');
        var s = document.createElement('div');
        s.className = 'al-sub';
        s.textContent = a.daySummary + (a.enabled ? '' : ' · off');
        main.appendChild(t);
        main.appendChild(s);
        var edit = document.createElement('button');
        edit.type = 'button';
        edit.className = 'al-btn';
        edit.textContent = 'Edit';
        edit.addEventListener('click', function () { openEditor(a); });
        var del = document.createElement('button');
        del.type = 'button';
        del.className = 'al-btn al-del';
        del.textContent = 'Delete';
        del.addEventListener('click', function () { remove(a.id); });
        row.appendChild(main);
        row.appendChild(edit);
        row.appendChild(del);
        listEl.appendChild(row);
      });
    }

    function flabel(text) {
      var l = document.createElement('label');
      l.className = 'al-flabel';
      l.textContent = text;
      return l;
    }

    function openEditor(a) {
      editorEl.hidden = false;
      editorEl.textContent = '';
      addBtn.hidden = true;
      var editingId = a ? a.id : null;
      var selDays = a && a.days ? a.days.slice() : [];

      editorEl.appendChild(flabel('Time'));
      var time = document.createElement('input');
      time.type = 'time';
      time.value = a ? a.time : '07:00';
      editorEl.appendChild(time);

      editorEl.appendChild(flabel('Label'));
      var label = document.createElement('input');
      label.type = 'text';
      label.value = a ? (a.label || '') : '';
      label.placeholder = 'Optional';
      editorEl.appendChild(label);

      editorEl.appendChild(flabel('Repeat (none = one time)'));
      var daysWrap = document.createElement('div');
      daysWrap.className = 'al-days';
      DAYS.forEach(function (d) {
        var b = document.createElement('button');
        b.type = 'button';
        b.className = 'al-day' + (selDays.indexOf(d[1]) !== -1 ? ' on' : '');
        b.textContent = d[0];
        b.addEventListener('click', function () {
          var i = selDays.indexOf(d[1]);
          if (i === -1) selDays.push(d[1]); else selDays.splice(i, 1);
          b.classList.toggle('on');
        });
        daysWrap.appendChild(b);
      });
      editorEl.appendChild(daysWrap);

      editorEl.appendChild(flabel('Sound'));
      var sound = document.createElement('select');
      tones.forEach(function (tn) {
        var opt = document.createElement('option');
        opt.value = tn.id;
        opt.textContent = tn.name;
        if (a && a.soundId === tn.id) opt.selected = true;
        sound.appendChild(opt);
      });
      editorEl.appendChild(sound);

      editorEl.appendChild(flabel('Sunrise effect'));
      var sunrise = document.createElement('select');
      [0, 5, 10, 15, 20, 25, 30].forEach(function (m) {
        var opt = document.createElement('option');
        opt.value = String(m);
        opt.textContent = m === 0 ? 'Off' : m + ' min';
        if (a && a.sunriseDuration === m) opt.selected = true;
        sunrise.appendChild(opt);
      });
      editorEl.appendChild(sunrise);

      var lightsWrap = document.createElement('div');
      lightsWrap.appendChild(flabel('Sunrise lights (come on dim when the sunrise starts)'));
      var selLights = a && a.sunriseLights ? a.sunriseLights.slice() : [];
      // A picked light Home Assistant no longer offers can still be unpicked.
      var lightChoices = lights.slice();
      selLights.forEach(function (id) {
        if (!lights.some(function (l) { return l.id === id; })) {
          lightChoices.push({ id: id, name: id });
        }
      });
      if (lightChoices.length === 0) {
        var noLights = document.createElement('div');
        noLights.className = 'al-sub';
        noLights.textContent = 'No dimmable lights found in Home Assistant';
        lightsWrap.appendChild(noLights);
      }
      lightChoices.forEach(function (l) {
        var row = document.createElement('label');
        row.className = 'al-check';
        var box = document.createElement('input');
        box.type = 'checkbox';
        box.checked = selLights.indexOf(l.id) !== -1;
        box.addEventListener('change', function () {
          var i = selLights.indexOf(l.id);
          if (box.checked && i === -1) selLights.push(l.id);
          if (!box.checked && i !== -1) selLights.splice(i, 1);
        });
        var name = document.createElement('span');
        name.textContent = l.name;
        row.appendChild(box);
        row.appendChild(name);
        lightsWrap.appendChild(row);
      });
      function showLights() {
        lightsWrap.style.display = sunrise.value === '0' ? 'none' : 'block';
      }
      sunrise.addEventListener('change', showLights);
      showLights();
      editorEl.appendChild(lightsWrap);

      editorEl.appendChild(flabel('Snooze duration'));
      var snooze = document.createElement('select');
      var curSnooze = a ? a.snoozeDuration : 10;
      [5, 10, 15, 20].forEach(function (m) {
        var opt = document.createElement('option');
        opt.value = String(m);
        opt.textContent = m + ' min';
        if (curSnooze === m) opt.selected = true;
        snooze.appendChild(opt);
      });
      editorEl.appendChild(snooze);

      editorEl.appendChild(flabel('Volume'));
      var volume = document.createElement('input');
      volume.type = 'range';
      volume.min = '0';
      volume.max = '100';
      volume.value = String(Math.round((a ? a.volume : 0.7) * 100));
      volume.style.width = '100%';
      editorEl.appendChild(volume);

      var enWrap = document.createElement('label');
      enWrap.className = 'al-check';
      var enabled = document.createElement('input');
      enabled.type = 'checkbox';
      enabled.checked = a ? !!a.enabled : true;
      var enSpan = document.createElement('span');
      enSpan.textContent = 'Enabled';
      enWrap.appendChild(enabled);
      enWrap.appendChild(enSpan);
      editorEl.appendChild(enWrap);

      var actions = document.createElement('div');
      actions.className = 'al-actions';
      var save = document.createElement('button');
      save.type = 'button';
      save.className = 'al-save';
      save.textContent = 'Save';
      save.addEventListener('click', function () {
        var days = selDays.slice().sort(function (x, y) { return x - y; });
        var payload = {
          time: time.value || '07:00',
          label: label.value || '',
          enabled: enabled.checked,
          days: days,
          oneTime: days.length === 0,
          soundId: sound.value,
          sunriseDuration: parseInt(sunrise.value, 10),
          sunriseLights: selLights,
          snoozeDuration: parseInt(snooze.value, 10),
          volume: parseInt(volume.value, 10) / 100
        };
        if (editingId) payload.id = editingId;
        status('Saving…');
        hearth.action('alarms/save', payload).then(function () {
          closeEditor();
          load();
          status('Saved');
        }).catch(function (e) {
          status('Save failed');
          console.error(e);
        });
      });
      var cancel = document.createElement('button');
      cancel.type = 'button';
      cancel.className = 'al-cancel';
      cancel.textContent = 'Cancel';
      cancel.addEventListener('click', closeEditor);
      actions.appendChild(save);
      actions.appendChild(cancel);
      editorEl.appendChild(actions);
    }

    function closeEditor() {
      editorEl.hidden = true;
      editorEl.textContent = '';
      addBtn.hidden = false;
    }

    function remove(id) {
      status('Deleting…');
      hearth.action('alarms/delete', { id: id }).then(function () {
        load();
        status('Deleted');
      }).catch(function (e) {
        status('Delete failed');
        console.error(e);
      });
    }

    addBtn.addEventListener('click', function () { openEditor(null); });
    load();
  }

  // hearth.js is loaded after this panel fragment, so defer until the page is
  // fully parsed before reaching for window.hearth.
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
</script>
''';
