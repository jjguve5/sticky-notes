#!/usr/bin/env python3
"""Keeps a window out of the taskbar, the dock and Alt+Tab on X11 (also XWayland under GNOME): asks the window
manager to add _NET_WM_STATE_SKIP_TASKBAR and _NET_WM_STATE_SKIP_PAGER. Electron's setSkipTaskbar doesn't reach
GNOME here, so main.js runs this with the window's id.  Usage: skip-taskbar.py <window id, hex or decimal>"""
import ctypes, sys
x = ctypes.cdll.LoadLibrary("libX11.so.6")
x.XOpenDisplay.restype = ctypes.c_void_p
x.XInternAtom.restype = ctypes.c_ulong
x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
x.XDefaultRootWindow.restype = ctypes.c_ulong
x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
class XClientMessageEvent(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int), ("display", ctypes.c_void_p),
                ("window", ctypes.c_ulong), ("message_type", ctypes.c_ulong), ("format", ctypes.c_int), ("data", ctypes.c_long * 5)]
class XEvent(ctypes.Union):
    _fields_ = [("xclient", XClientMessageEvent), ("pad", ctypes.c_long * 24)]
d = x.XOpenDisplay(None)
win = int(sys.argv[1], 0)
ev = XEvent()
ev.xclient.type = 33
ev.xclient.send_event = 1
ev.xclient.display = d
ev.xclient.window = win
ev.xclient.message_type = x.XInternAtom(d, b"_NET_WM_STATE", 0)
ev.xclient.format = 32
ev.xclient.data[0] = 1
ev.xclient.data[1] = x.XInternAtom(d, b"_NET_WM_STATE_SKIP_TASKBAR", 0)
ev.xclient.data[2] = x.XInternAtom(d, b"_NET_WM_STATE_SKIP_PAGER", 0)
ev.xclient.data[3] = 1
x.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.c_void_p]
x.XSendEvent(d, x.XDefaultRootWindow(d), 0, (1 << 20) | (1 << 19), ctypes.byref(ev))
x.XFlush.argtypes = [ctypes.c_void_p]
x.XFlush(d)
