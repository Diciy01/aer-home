# clipboard probe: "set TEXT SECONDS" keeps ownership; "get" prints current text
import os, sys
os.environ["GDK_BACKEND"]="x11"
import gi; gi.require_version("Gtk","3.0"); from gi.repository import Gtk, Gdk, GLib
cb = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
if sys.argv[1] == "set":
    cb.set_text(sys.argv[2], -1); cb.store()
    GLib.timeout_add_seconds(int(sys.argv[3]), Gtk.main_quit); Gtk.main()
else:
    print(cb.wait_for_text())
