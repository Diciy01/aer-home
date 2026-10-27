import os, sys
os.environ["GDK_BACKEND"]="x11"
import gi; gi.require_version("Gdk","3.0"); from gi.repository import Gdk
root = Gdk.get_default_root_window()
pb = Gdk.pixbuf_get_from_window(root, 0, 0, root.get_width(), root.get_height())
pb.savev(sys.argv[1], "png", [], [])
print("saved", root.get_width(), root.get_height())
