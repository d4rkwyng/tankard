// Theme-switch probe for Scripts/theme-geometry-check.sh. Loaded into a
// (re-signed) copy of Tankard with DYLD_INSERT_LIBRARIES, so it works on any
// build, including a signed release, without the app's TANKARD_* hooks.
//
// It switches themes the way a person does: opens Settings from the app
// menu, picks the Appearance tab and clicks the theme's radio button with
// a mouse event. After each click it writes the main window's geometry
// (every visible text, image, control and table cell, in window points)
// for every distinct frame drawn, and once settled, so a one-frame jump is
// caught as well as a lasting one; and the colour of every visible row.
//
//   PROBE_OUT=<dir>          where to write (required; nothing happens without it)
//   PROBE_START=15           seconds after launch before the first dump
//   PROBE_THEMES=Tankard,Dark  themes to click through, in order ("" = none)
//   PROBE_SAMPLES=2          seconds after each click to dump (the last
//                            one is the settled state; the frames between
//                            are recorded as they are drawn, see watchFrames)
//   PROBE_SNAP=1             also write a PNG of the window at each dump
//   PROBE_SIZE=1040x620      content size to set first
//
// Output: <name>.geom (sorted lines "kind x,y wxh"), <name>-fNN.geom (each
// distinct drawn frame after a click), <name>.rows (row background colours;
// also -scrolled and -back), <name>.png, probe.log.
#import <AppKit/AppKit.h>

static NSString *outDir;
static FILE *probeLog;
static BOOL snapEnabled;

static void plog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(probeLog, "%.3f %s\n", NSProcessInfo.processInfo.systemUptime, s.UTF8String);
    fflush(probeLog);
}

static NSWindow *mainWindow(void) {
    for (NSWindow *w in NSApp.windows)
        if (w.isVisible && w.toolbar && ([w.title isEqualToString:@"Tankard"] || [w.title isEqualToString:@"Intelbrew"])) return w;
    return nil;
}

static NSWindow *settingsWindow(void) {
    NSWindow *m = mainWindow();
    for (NSWindow *w in NSApp.windows)
        if (w != m && w.isVisible && w.toolbar) return w;
    return nil;
}

static void snap(NSWindow *w, NSString *name) {
    NSView *v = w.contentView.superview ?: w.contentView;
    NSRect b = v.bounds;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:(NSInteger)(b.size.width * 2) pixelsHigh:(NSInteger)(b.size.height * 2)
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
        bytesPerRow:0 bitsPerPixel:0];
    rep.size = b.size;
    [v cacheDisplayInRect:b toBitmapImageRep:rep];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:[outDir stringByAppendingPathComponent:[name stringByAppendingString:@".png"]] atomically:YES];
}

/// The kind of a view worth comparing, or nil to skip it (and, for
/// `descend`, whether to look inside). Backgrounds and fills
/// (_NSGraphicsView, visual-effect views, the table's background) are
/// colour, not layout, and some only exist when they aren't clear.
static NSString *kindOf(NSView *v) {
    NSString *c = NSStringFromClass(v.class);
    if ([c containsString:@"CGDrawingView"]) return @"draw";          // SwiftUI text, symbols, images
    if ([c containsString:@"NSSegmentItemLabelView"]) return @"seglabel";
    if ([c containsString:@"NSSegmentItemView"]) return @"segment";
    if ([c containsString:@"FocusRingView"]) return @"focusring";      // a SwiftUI button's bounds
    if ([c containsString:@"NSToolbarItemViewer"]) return @"toolbaritem";
    if ([c containsString:@"NSToolbarTitleField"] || [c containsString:@"NSToolbarSubtitleField"]) return @"title";
    if ([c containsString:@"NSTableHeaderView"]) return @"tableheader";
    if ([c containsString:@"NSClipView"]) return @"clip";
    if ([v isKindOfClass:NSSearchField.class]) return @"searchfield";
    if ([v isKindOfClass:NSTextField.class]) return @"label";
    if ([v isKindOfClass:NSSegmentedControl.class]) return @"segmented";
    if ([v isKindOfClass:NSButton.class]) return @"button";
    if ([v isKindOfClass:NSImageView.class]) return @"image";
    if ([v isKindOfClass:NSProgressIndicator.class]) return @"progress";
    if ([v isKindOfClass:NSSplitView.class]) return @"split";
    return nil;
}

static void walk(NSView *v, NSRect visible, NSMutableArray *out) {
    if (v.isHidden || v.alphaValue == 0) return;
    NSRect r = [v convertRect:v.bounds toView:nil];
    if ([v isKindOfClass:NSClipView.class]) visible = NSIntersectionRect(visible, r);
    if (r.size.width > 0 && r.size.height > 0 && !NSIntersectsRect(r, visible)) return;
    NSString *k = kindOf(v);
    if (k) [out addObject:[NSString stringWithFormat:@"%@ %.1f,%.1f %.1fx%.1f", k, r.origin.x, r.origin.y, r.size.width, r.size.height]];
    if ([v isKindOfClass:NSTableView.class]) {
        NSTableView *t = (NSTableView *)v;
        NSMutableArray *widths = [NSMutableArray array];
        for (NSTableColumn *col in t.tableColumns) [widths addObject:[NSString stringWithFormat:@"%.1f", col.width]];
        [out addObject:[NSString stringWithFormat:@"tablecolumns %@ x=%.1f rows=%ld rowheight0=%.1f", [widths componentsJoinedByString:@"/"],
                        r.origin.x, (long)t.numberOfRows, t.numberOfRows > 0 ? [t rectOfRow:0].size.height : 0]];
        // Each visible row's cells, by row and column, in window points.
        NSRange rows = [t rowsInRect:[t convertRect:visible fromView:nil]];
        for (NSUInteger i = rows.location; i < NSMaxRange(rows); i++) {
            for (NSInteger c = 0; c < t.numberOfColumns; c++) {
                NSView *cell = [t viewAtColumn:c row:(NSInteger)i makeIfNecessary:NO];
                if (!cell) continue;
                NSRect cr = [cell convertRect:cell.bounds toView:nil];
                [out addObject:[NSString stringWithFormat:@"cell r%lu c%ld %.1f,%.1f %.1fx%.1f", (unsigned long)i, (long)c,
                                cr.origin.x, cr.origin.y, cr.size.width, cr.size.height]];
            }
        }
    }
    for (NSView *s in v.subviews) walk(s, visible, out);
}

static NSString *geometry(NSWindow *w) {
    NSView *root = w.contentView.superview ?: w.contentView;
    NSMutableArray *out = [NSMutableArray array];
    [out addObject:[NSString stringWithFormat:@"window %.1fx%.1f", w.frame.size.width, w.frame.size.height]];
    walk(root, [root convertRect:root.bounds toView:nil], out);
    [out sortUsingSelector:@selector(compare:)];
    return [[out componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
}

static void writeGeometry(NSString *name, NSString *text) {
    [text writeToFile:[outDir stringByAppendingPathComponent:[name stringByAppendingString:@".geom"]]
           atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void dump(NSString *name) {
    NSWindow *w = mainWindow();
    if (!w) { plog(@"dump %@: no main window", name); return; }
    writeGeometry(name, geometry(w));
    if (snapEnabled) snap(w, name);
    plog(@"dump %@", name);
}

// Frames: after each click, at the end of every run-loop pass (after
// AppKit has laid out and displayed the window, so this is what was on
// screen until the next pass), the geometry is recorded whenever it
// differs from the previous pass's. A timed dump can land between a
// change and the layout that follows it; this sees only drawn states.
static CFRunLoopObserverRef frameObserver;
static NSString *frameTag, *lastFrame;
static NSUInteger frameCount, framePasses;

static void watchFrames(NSString *tag, double seconds) {
    frameTag = tag;
    lastFrame = nil;
    frameCount = 0;
    framePasses = 0;
    if (!frameObserver) {
        frameObserver = CFRunLoopObserverCreateWithHandler(NULL, kCFRunLoopBeforeWaiting, true, LONG_MAX, ^(CFRunLoopObserverRef o, CFRunLoopActivity a) {
            if (!frameTag) return;
            NSWindow *w = mainWindow();
            if (!w) return;
            framePasses++;
            NSString *g = geometry(w);
            if ([g isEqualToString:lastFrame]) return;
            lastFrame = g;
            NSString *name = [NSString stringWithFormat:@"%@-f%02lu", frameTag, (unsigned long)frameCount++];
            writeGeometry(name, g);
            if (snapEnabled) snap(w, name);
            plog(@"frame %@", name);
        });
        CFRunLoopAddObserver(CFRunLoopGetMain(), frameObserver, kCFRunLoopCommonModes);
    }
    NSString *mine = tag;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (frameTag == mine) { plog(@"%@: %lu distinct frames in %lu passes", mine, (unsigned long)frameCount, (unsigned long)framePasses); frameTag = nil; }
    });
}

// Row colours: the background of every visible row, sampled from the
// rendered window just inside the row's left edge (x = row + 12 points,
// left of the first column's text, on the stripe/selection inset), as
// hex per row from the top. Then the table is scrolled 40 rows down and
// back to the top, and sampled each time, so row views coming back from
// AppKit's reuse pool are checked too.
static NSTableView *mainTable(NSWindow *w) {
    NSMutableArray *out = [NSMutableArray array];
    __block void (^find)(NSView *);
    find = ^(NSView *v) {
        if ([v isKindOfClass:NSTableView.class] && !v.isHidden && v.window) [out addObject:v];
        for (NSView *s in v.subviews) find(s);
    };
    find(w.contentView);
    find = nil;
    NSTableView *best = nil;
    for (NSTableView *t in out) if (!best || t.numberOfRows > best.numberOfRows) best = t;
    return best;
}

static NSString *rowColours(NSWindow *w) {
    NSTableView *t = mainTable(w);
    if (!t) return @"no table\n";
    NSView *root = w.contentView.superview ?: w.contentView;
    [root layoutSubtreeIfNeeded];
    NSRect b = root.bounds;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:(NSInteger)(b.size.width * 2) pixelsHigh:(NSInteger)(b.size.height * 2)
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bytesPerRow:0 bitsPerPixel:0];
    rep.size = b.size;
    [root cacheDisplayInRect:b toBitmapImageRep:rep];
    NSClipView *clip = t.enclosingScrollView.contentView;
    NSRect visible = [clip convertRect:clip.bounds toView:nil];
    NSRange rows = [t rowsInRect:[t convertRect:visible fromView:nil]];
    NSMutableArray *out = [NSMutableArray array];
    for (NSUInteger i = rows.location; i < NSMaxRange(rows); i++) {
        NSRect r = [t convertRect:[t rectOfRow:(NSInteger)i] toView:nil];
        double y = NSMidY(r);
        if (y < NSMinY(visible) + 2 || y > NSMaxY(visible) - 2) continue;
        NSInteger px = (NSInteger)((r.origin.x + 12) * 2), py = (NSInteger)((b.size.height - y) * 2);
        NSUInteger p[4] = {0};
        [rep getPixel:p atX:px y:py];
        [out addObject:[NSString stringWithFormat:@"row %lu %02lx%02lx%02lx", (unsigned long)i, (unsigned long)p[0], (unsigned long)p[1], (unsigned long)p[2]]];
    }
    return [[out componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
}

static void writeColours(NSString *name) {
    NSWindow *w = mainWindow();
    if (!w) return;
    [rowColours(w) writeToFile:[outDir stringByAppendingPathComponent:[name stringByAppendingString:@".rows"]]
                    atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (snapEnabled) snap(w, [name stringByAppendingString:@"-rows"]);
    plog(@"colours %@", name);
}

/// Scrolls 40 rows down and returns the clip view's origin before it.
static NSPoint scrollDown(void) {
    NSTableView *t = mainTable(mainWindow());
    if (!t) return NSZeroPoint;
    NSPoint origin = t.enclosingScrollView.contentView.bounds.origin;
    [t scrollRowToVisible:MIN(40, t.numberOfRows - 1)];
    return origin;
}

/// Scrolls back to exactly where `scrollDown` started.
static void scrollBack(NSPoint origin) {
    NSTableView *t = mainTable(mainWindow());
    NSClipView *clip = t.enclosingScrollView.contentView;
    if (!clip) return;
    [clip scrollToPoint:origin];
    [t.enclosingScrollView reflectScrolledClipView:clip];
}

/// Samples the colours at the top, 40 rows down and back at the top, then
/// calls `next`.
static void checkColours(NSString *name, dispatch_block_t next) {
    writeColours(name);
    NSPoint origin = scrollDown();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        writeColours([name stringByAppendingString:@"-scrolled"]);
        scrollBack(origin);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            writeColours([name stringByAppendingString:@"-back"]);
            next();
        });
    });
}

static void openSettings(void) {
    NSMenu *app = [NSApp.mainMenu itemAtIndex:0].submenu;
    for (NSInteger i = 0; i < app.numberOfItems; i++) {
        if ([[app itemAtIndex:i].title hasPrefix:@"Settings"]) { [app performActionForItemAtIndex:i]; plog(@"opened Settings"); return; }
    }
    plog(@"no Settings menu item");
}

static void showAppearanceTab(void) {
    NSWindow *sw = settingsWindow();
    for (NSToolbarItem *ti in sw.toolbar.items) {
        if ([ti.label isEqualToString:@"Appearance"]) {
            sw.toolbar.selectedItemIdentifier = ti.itemIdentifier;
            if (ti.action) [NSApp sendAction:ti.action to:ti.target from:ti];
            plog(@"Appearance tab");
        }
    }
}

static void collectRadios(NSView *v, NSMutableArray *out) {
    // SwiftUI's radio group: one small NSButton per option, no title.
    if ([v isKindOfClass:NSButton.class] && v.frame.size.width < 30 && v.frame.size.height < 30
        && ![NSStringFromClass(v.class) containsString:@"Toolbar"] && [(NSButton *)v title].length == 0) [out addObject:v];
    for (NSView *s in v.subviews) collectRadios(s, out);
}

/// Clicks the radio button for `theme` (by position: the options are in
/// AppTheme order, PROBE_ORDER) with a real mouse-down/up pair.
static BOOL clickTheme(NSString *theme, NSArray *order) {
    NSWindow *sw = settingsWindow();
    if (!sw) { plog(@"no Settings window"); return NO; }
    NSMutableArray *radios = [NSMutableArray array];
    collectRadios(sw.contentView, radios);
    [radios sortUsingComparator:^NSComparisonResult(NSView *a, NSView *b) {
        CGFloat ya = [a convertRect:a.bounds toView:nil].origin.y, yb = [b convertRect:b.bounds toView:nil].origin.y;
        return ya > yb ? NSOrderedAscending : ya < yb ? NSOrderedDescending : NSOrderedSame;
    }];
    NSUInteger i = [order indexOfObject:theme];
    if (radios.count != order.count || i == NSNotFound) {
        plog(@"click %@: %lu radio buttons for %lu themes", theme, (unsigned long)radios.count, (unsigned long)order.count);
        return NO;
    }
    NSView *r = radios[i];
    NSPoint p = [r convertPoint:NSMakePoint(NSMidX(r.bounds), NSMidY(r.bounds)) toView:nil];
    [sw makeKeyAndOrderFront:nil];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:p modifierFlags:0 timestamp:now
                                   windowNumber:sw.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
    NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:p modifierFlags:0 timestamp:now
                                 windowNumber:sw.windowNumber context:nil eventNumber:2 clickCount:1 pressure:0];
    [NSApp postEvent:up atStart:NO];   // the button's tracking loop reads it
    [sw sendEvent:down];
    plog(@"clicked %@", theme);
    return YES;
}

static void after(double seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

__attribute__((constructor)) static void probeStart(void) {
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    outDir = env[@"PROBE_OUT"];
    if (!outDir) return;
    [NSFileManager.defaultManager createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
    probeLog = fopen([outDir stringByAppendingPathComponent:@"probe.log"].UTF8String, "a");
    snapEnabled = [env[@"PROBE_SNAP"] isEqualToString:@"1"];
    NSString *themesEnv = env[@"PROBE_THEMES"] ?: @"";
    NSArray *themes = themesEnv.length ? [themesEnv componentsSeparatedByString:@","] : @[];
    NSArray *order = [env[@"PROBE_ORDER"] ?: @"Dark,Light,System,Tankard,Dracula" componentsSeparatedByString:@","];
    NSMutableArray *samples = [NSMutableArray array];
    for (NSString *s in [env[@"PROBE_SAMPLES"] ?: @"2" componentsSeparatedByString:@","])
        [samples addObject:@(s.doubleValue)];
    double start = [env[@"PROBE_START"] ?: @"15" doubleValue];
    NSArray *size = [env[@"PROBE_SIZE"] ?: @"1040x620" componentsSeparatedByString:@"x"];
    NSString *prefix = env[@"PROBE_PREFIX"] ?: @"run";

    // Size the window early, so it has settled long before the first dump.
    after(2, ^{
        NSWindow *w = mainWindow();
        [w setContentSize:NSMakeSize([size[0] doubleValue], [size[1] doubleValue])];
        [w setFrameOrigin:NSMakePoint(40, 120)];
    });
    after(start, ^{
        if (!mainWindow()) { plog(@"no main window after %.0f s", start); exit(3); }
        dump([prefix stringByAppendingString:@"-start"]);
        checkColours([prefix stringByAppendingString:@"-start"], ^{
        if (themes.count == 0) { after(0.2, ^{ exit(0); }); return; }
        openSettings();
        after(1.0, ^{ showAppearanceTab(); });
        // One theme at a time: the next click waits for the previous
        // theme's last dump (a switch can block the main thread for a
        // moment, so fixed timestamps would bunch up).
        double last = [[samples valueForKeyPath:@"@max.doubleValue"] doubleValue];
        __block void (^step)(NSUInteger);
        step = ^(NSUInteger n) {
            if (n == themes.count) { plog(@"done"); after(0.2, ^{ exit(0); }); return; }
            NSString *theme = themes[n];
            NSString *tag = [NSString stringWithFormat:@"%@-%02lu-%@", prefix, (unsigned long)n + 1, theme.lowercaseString];
            if (!clickTheme(theme, order)) exit(4);
            watchFrames(tag, last);
            for (NSNumber *d in samples) {
                after(d.doubleValue, ^{
                    dump([NSString stringWithFormat:@"%@-t%04.0f", tag, d.doubleValue * 1000]);
                    if (d.doubleValue == last) checkColours(tag, ^{ after(0.5, ^{ step(n + 1); }); });
                });
            }
        };
        after(2.0, ^{ step(0); });
        });
    });
}
