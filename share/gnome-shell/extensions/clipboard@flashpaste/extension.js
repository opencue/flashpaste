import Gio from 'gi://Gio';
import GioUnix from 'gi://GioUnix';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const NAME = 'org.flashpaste.Clipboard';
const XML = `<node><interface name="${NAME}">
  <method name="ReadPaste">
    <arg name="token" type="s" direction="in"/>
    <arg name="output" type="h" direction="in"/>
    <arg name="kind" type="s" direction="out"/>
  </method>
</interface></node>`;
const TEXT = ['text/plain;charset=utf-8', 'text/plain', 'UTF8_STRING', 'TEXT', 'STRING'];

export default class FlashPasteClipboard extends Extension {
    enable() {
        // A sandbox with session bus access alone must not be able to read the
        // clipboard. The capability stays in the user's private runtime dir.
        this._tokenFile = Gio.File.new_for_path(
            GLib.build_filenamev([GLib.get_user_runtime_dir(), 'flashpaste-clipboard.token']));
        const entropy = Gio.File.new_for_path('/dev/urandom').read(null);
        try {
            this._token = GLib.compute_checksum_for_bytes(GLib.ChecksumType.SHA256,
                entropy.read_bytes(32, null));
        } finally {
            entropy.close(null);
        }
        this._tokenFile.replace_contents(new TextEncoder().encode(this._token), null, false,
            Gio.FileCreateFlags.PRIVATE | Gio.FileCreateFlags.REPLACE_DESTINATION, null);
        this._service = Gio.DBusExportedObject.wrapJSObject(XML, this);
        this._service.export(Gio.DBus.session, '/org/flashpaste/Clipboard');
        this._nameId = Gio.bus_own_name_on_connection(Gio.DBus.session, NAME,
            Gio.BusNameOwnerFlags.NONE, null, null);
    }

    disable() {
        this._transfer?.cancel();
        Gio.bus_unown_name(this._nameId);
        this._service.unexport();
        this._tokenFile.delete(null);
    }

    async ReadPasteAsync([token, handle], invocation) {
        const reply = kind => invocation.return_value(new GLib.Variant('(s)', [kind]));
        if (token !== this._token || this._transfer || Main.sessionMode.isLocked || Main.sessionMode.isGreeter) {
            reply('');
            return;
        }

        let output;
        const cancellable = new Gio.Cancellable();
        this._transfer = cancellable;
        try {
            // Never read on behalf of a different account, even if the session
            // bus allows that account to connect.
            const [uid] = await new Promise((resolve, reject) => {
                const bus = invocation.get_connection();
                bus.call('org.freedesktop.DBus', '/org/freedesktop/DBus',
                    'org.freedesktop.DBus', 'GetConnectionUnixUser',
                    new GLib.Variant('(s)', [invocation.get_sender()]),
                    new GLib.VariantType('(u)'), Gio.DBusCallFlags.NONE, 150,
                    cancellable, (_, result) => {
                        try {
                            resolve(bus.call_finish(result).deepUnpack());
                        } catch (error) {
                            reject(error);
                        }
                    });
            });
            if (uid !== new Gio.Credentials().get_unix_user() ||
                Main.sessionMode.isLocked || Main.sessionMode.isGreeter || cancellable.is_cancelled()) {
                reply('');
                return;
            }

            const selection = global.display.get_selection();
            const type = Meta.SelectionType.SELECTION_CLIPBOARD;
            const types = selection.get_mimetypes(type) ?? [];
            const hasOtherText = types.some(item => item.startsWith('text/') &&
                item.split(';')[0] !== 'text/html');
            const mime = TEXT.find(item => types.includes(item)) ??
                (!hasOtherText && types.includes('image/png') ? 'image/png' : null);
            if (!mime) {
                reply('');
                return;
            }
            const image = mime === 'image/png';
            const limit = image ? 16 * 1024 * 1024 : 1024 * 1024;
            output = GioUnix.OutputStream.new(invocation.get_message().get_unix_fd_list().get(handle), true);
            let timer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 600, () => {
                timer = 0;
                cancellable.cancel();
                return GLib.SOURCE_REMOVE;
            });
            try {
                await new Promise((resolve, reject) => {
                    selection.transfer_async(type, mime, limit + 1, output, cancellable, (_, result) => {
                        try {
                            selection.transfer_finish(result);
                            resolve();
                        } catch (error) {
                            reject(error);
                        }
                    });
                });
            } finally {
                if (timer)
                    GLib.source_remove(timer);
            }
            reply(image ? 'png' : 'text');
        } catch (_error) {
            reply('');
        } finally {
            try {
                output?.close(null);
            } finally {
                this._transfer = null;
            }
        }
    }
}
