// WinScrollView.swift -- a scroll view whose scroll bars behave like Win32's (feel3, the user's
// finding 3: "a vertical scroll bar shows when the app opens; touching it makes it vanish and a
// horizontal one appears").
//
// That was AppKit's *overlay* scroller style (System Settings > Appearance > Show scroll bars:
// "Automatically based on mouse or trackpad" with a trackpad): an overlay scroller is flashed when
// the view first appears and whenever it scrolls, whether or not anything overflows in that
// direction a moment later. A Win32 list (WS_VSCROLL / WS_HSCROLL managed by the list view) shows
// a bar only while the content overflows on that axis, and then always, taking its 17 px from the
// client area. The legacy style with auto-hiding is exactly that, so this view pins it: AppKit
// resets `scrollerStyle` on every scroll view when the preference changes
// (NSPreferredScrollerStyleDidChangeNotification), and the override ignores that.

import AppKit

class WinScrollView: NSScrollView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        super.scrollerStyle = .legacy
        autohidesScrollers = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        super.scrollerStyle = .legacy
        autohidesScrollers = true
    }

    override var scrollerStyle: NSScroller.Style {
        get { .legacy }
        set { super.scrollerStyle = .legacy }
    }
}
