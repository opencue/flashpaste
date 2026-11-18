// Removes GNOME Shell's own "Screenshot captured" notifications.
//
// They come from a shell-internal source (ui/screenshot.js), not from an
// application, so Settings → Notifications has no switch for them and they
// pile up in the notification list. The source is recognised by its icon name,
// which — unlike its title — is not translated.
import GLib from 'gi://GLib';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const SCREENSHOT_SOURCE_ICON = 'screenshot-recorded-symbolic';

export default class HideScreenshotNotifications extends Extension {
    enable() {
        this._idleIds = new Set();
        this._sources = new Map();
        this._trayId = Main.messageTray.connect('source-added',
            (_tray, source) => this._watch(source));
        for (const source of Main.messageTray.getSources())
            this._watch(source);
    }

    disable() {
        if (this._trayId)
            Main.messageTray.disconnect(this._trayId);
        this._trayId = 0;
        for (const [source, id] of this._sources) {
            try {
                source.disconnect(id);
            } catch (_e) {
                // the source is already gone
            }
        }
        this._sources = null;
        for (const id of this._idleIds)
            GLib.source_remove(id);
        this._idleIds = null;
    }

    _watch(source) {
        if (source?.iconName !== SCREENSHOT_SOURCE_ICON || this._sources.has(source))
            return;
        const id = source.connect('notification-added',
            (_source, notification) => this._dismissLater(notification));
        this._sources.set(source, id);
        source.connect('destroy', () => this._sources?.delete(source));
        for (const notification of [...(source.notifications ?? [])])
            this._dismissLater(notification);
    }

    // Not inside the signal emission: the tray is still wiring the notification up.
    _dismissLater(notification) {
        const id = GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
            this._idleIds?.delete(id);
            try {
                notification.destroy();
            } catch (_e) {
                // already dismissed
            }
            return GLib.SOURCE_REMOVE;
        });
        this._idleIds.add(id);
    }
}
