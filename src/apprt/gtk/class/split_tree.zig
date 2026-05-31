const std = @import("std");
const assert = @import("../../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const apprt = @import("../../../apprt.zig");
const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Application = @import("application.zig").Application;
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;
const Surface = @import("surface.zig").Surface;
const SurfaceScrolledWindow = @import("surface_scrolled_window.zig").SurfaceScrolledWindow;

const log = std.log.scoped(.gtk_ghostty_split_tree);

pub const SplitTree = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySplitTree",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// The active surface is the surface that should be receiving all
        /// surface-targeted actions. This is usually the focused surface,
        /// but may also not be focused if the user has selected a non-surface
        /// widget.
        pub const @"active-surface" = struct {
            pub const name = "active-surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface,
                        .{
                            .getter = getActiveSurface,
                        },
                    ),
                },
            );
        };

        pub const @"has-surfaces" = struct {
            pub const name = "has-surfaces";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{
                            .getter = getHasSurfaces,
                        },
                    ),
                },
            );
        };

        pub const @"is-zoomed" = struct {
            pub const name = "is-zoomed";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{
                            .getter = getIsZoomed,
                        },
                    ),
                },
            );
        };

        pub const tree = struct {
            pub const name = "tree";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface.Tree,
                .{
                    .accessor = .{
                        .getter = getTreeValue,
                        .setter = setTreeValue,
                    },
                },
            );
        };

        pub const @"is-split" = struct {
            pub const name = "is-split";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{
                            .getter = getIsSplit,
                        },
                    ),
                },
            );
        };
    };

    pub const signals = struct {
        /// Emitted whenever the tree property has changed, with access
        /// to the previous and new values.
        pub const changed = struct {
            pub const name = "changed";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{ ?*const Surface.Tree, ?*const Surface.Tree },
                void,
            );
        };
    };

    const Private = struct {
        /// The tree datastructure containing all of our surface views.
        tree: ?*Surface.Tree,

        // Template bindings
        tree_bin: *adw.Bin,

        /// Last focused surface in the tree. We need this to handle various
        /// tree change states.
        last_focused: WeakRef(Surface) = .empty,

        /// The source that we use to rebuild the tree. This is also
        /// used to debounce updates.
        rebuild_source: ?c_uint = null,

        /// The source that we use to restore focus. With enough nested
        /// splits, some surfaces might initially be allocated a width or
        /// height of 0 which causes them to get unmapped and lose focus.
        /// We can reliably restore focus to the last focused surface only
        /// once it is mapped again.
        restore_focus_source: ?c_uint = null,

        /// Used to store state about a pending surface close for the
        /// close dialog.
        pending_close: ?Surface.Tree.Node.Handle,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // Initialize our actions
        self.initActionMap();

        // Initialize some basic state
        const priv = self.private();
        priv.pending_close = null;
    }

    fn initActionMap(self: *Self) void {
        const s_variant_type = glib.ext.VariantType.newFor([:0]const u8);
        defer s_variant_type.free();

        const actions = [_]ext.actions.Action(Self){
            // All of these will eventually take a target surface parameter.
            // For now all our targets originate from the focused surface.
            .init("new-split", actionNewSplit, s_variant_type),
            .init("equalize", actionEqualize, null),
            .init("zoom", actionZoom, null),
        };

        _ = ext.actions.addAsGroup(Self, self, "split-tree", &actions);
    }

    /// Create a new split in the given direction from the currently
    /// active surface.
    ///
    /// If the tree is empty this will create a new tree with a new surface
    /// and ignore the direction.
    ///
    /// The parent will be used as the parent of the surface regardless of
    /// if that parent is in this split tree or not. This allows inheriting
    /// surface properties from anywhere.
    pub fn newSplit(
        self: *Self,
        direction: Surface.Tree.Split.Direction,
        parent_: ?*Surface,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) Allocator.Error!void {
        const alloc = Application.default().allocator();

        // Create our new surface.
        const surface: *Surface = .new(.{
            .command = overrides.command,
            .working_directory = overrides.working_directory,
            .title = overrides.title,
        });
        defer surface.unref();
        _ = surface.refSink();

        // Inherit properly if we were asked to.
        if (parent_) |p| {
            if (p.core()) |core| {
                surface.setParent(core, .split);
            }
        }

        // Bind is-split property for new surface
        _ = self.as(gobject.Object).bindProperty(
            "is-split",
            surface.as(gobject.Object),
            "is-split",
            .{ .sync_create = true },
        );

        // Create our tree
        var single_tree = try Surface.Tree.init(alloc, surface);
        defer single_tree.deinit();

        // We want to move our focus to the new surface no matter what.
        // But we need to be careful to restore state if we fail.
        const old_last_focused = self.private().last_focused.get();
        defer if (old_last_focused) |v| v.unref(); // unref strong ref from get
        self.private().last_focused.set(surface);
        errdefer self.private().last_focused.set(old_last_focused);

        // If we have no tree yet, then this becomes our tree and we're done.
        const old_tree = self.getTree() orelse {
            self.setTree(&single_tree);
            return;
        };

        // The handle we create the split relative to. Today this is the active
        // surface but this might be the handle of the given parent if we want.
        const handle = self.getActiveSurfaceHandle() orelse .root;

        // Create our split!
        var new_tree = try old_tree.split(
            alloc,
            handle,
            direction,
            0.5, // Always split equally for new splits
            &single_tree,
        );
        defer new_tree.deinit();
        log.debug(
            "new split at={} direction={} old_tree={f} new_tree={f}",
            .{ handle, direction, old_tree, &new_tree },
        );

        // Replace our tree
        self.setTree(&new_tree);
    }

    /// Pop the given surface out of this split tree and into a brand-new
    /// window. The surface is removed from this tree (its sibling is promoted
    /// in its place via the core `detach` helper) and re-homed as the sole
    /// pane of a fresh window.
    ///
    /// No-op (returns false) if `surface` isn't found in this tree or if this
    /// tree is a single pane (nothing to pop out of). Returns true if the pane
    /// was popped out.
    ///
    /// NOTE(gtk-untested): this is net-new behavior with no prototype
    /// reference. The flow is:
    ///   1. find the leaf handle of `surface` in our current tree;
    ///   2. guard against single-pane trees (root is a leaf);
    ///   3. call core `detach(handle)` -> { remaining, detached };
    ///   4. set `remaining` as our tree (sibling promoted, surface gone);
    ///   5. ask the Application to open a new window adopting `detached`.
    /// Ownership: `detach` hands us two independently-owned trees. We pass
    /// `&remaining`/`&detached` to `setTree`/`newWindowWithTree`, which CLONE
    /// (boxedCopy) them, so we still own and must `deinit` both locally.
    pub fn popoutSurface(self: *Self, surface: *Surface) bool {
        const tree = self.getTree() orelse return false;

        // A single-pane tree has nothing to pop out of: the root is a leaf.
        switch (tree.nodes[@as(Surface.Tree.Node.Handle, .root).idx()]) {
            .leaf => return false,
            .split => {},
        }

        // Find the handle of the surface within our tree.
        const handle: Surface.Tree.Node.Handle = handle: {
            var it = tree.iterator();
            while (it.next()) |entry| {
                if (entry.view == surface) break :handle entry.handle;
            }
            // Surface isn't in this tree (shouldn't happen for a child).
            return false;
        };

        const alloc = Application.default().allocator();

        // Detach: produces a `remaining` tree (with the leaf removed and its
        // sibling promoted) and a fresh single-leaf `detached` tree.
        var detached = tree.detach(alloc, handle) catch |err| {
            log.warn("failed to detach surface for pop-out err={}", .{err});
            return false;
        };
        defer detached.remaining.deinit();
        defer detached.detached.deinit();

        log.debug(
            "popping out surface handle={} remaining={f} detached={f}",
            .{ handle, &detached.remaining, &detached.detached },
        );

        // Open a new window adopting the detached subtree FIRST. If this
        // fails we leave our own tree untouched so the surface isn't lost.
        Application.default().newWindowWithTree(&detached.detached) catch |err| {
            log.warn("failed to open new window for pop-out err={}", .{err});
            return false;
        };

        // Now drop the surface from our tree (sibling promoted).
        self.setTree(&detached.remaining);
        return true;
    }

    pub fn resize(
        self: *Self,
        direction: Surface.Tree.Split.Direction,
        amount: u16,
    ) Allocator.Error!bool {
        // Avoid useless work
        if (amount == 0) return false;

        const old_tree = self.getTree() orelse return false;
        const active = self.getActiveSurfaceHandle() orelse return false;

        // Get all our dimensions we're going to need to turn our
        // amount into a percentage.
        const priv = self.private();
        const width = priv.tree_bin.as(gtk.Widget).getWidth();
        const height = priv.tree_bin.as(gtk.Widget).getHeight();
        if (width == 0 or height == 0) return false;
        const width_f64: f64 = @floatFromInt(width);
        const height_f64: f64 = @floatFromInt(height);
        const amount_f64: f64 = @floatFromInt(amount);

        // Get our ratio and use positive/neg for directions.
        const ratio: f64 = switch (direction) {
            .right => amount_f64 / width_f64,
            .left => -(amount_f64 / width_f64),
            .down => amount_f64 / height_f64,
            .up => -(amount_f64 / height_f64),
        };

        const layout: Surface.Tree.Split.Layout = switch (direction) {
            .left, .right => .horizontal,
            .up, .down => .vertical,
        };

        var new_tree = try old_tree.resize(
            Application.default().allocator(),
            active,
            layout,
            @floatCast(ratio),
        );
        defer new_tree.deinit();
        self.setTree(&new_tree);
        return true;
    }

    /// Move focus from the currently focused surface to the given
    /// direction. Returns true if focus switched to a new surface.
    pub fn goto(self: *Self, to: Surface.Tree.Goto) bool {
        const tree = self.getTree() orelse return false;
        const active = self.getActiveSurfaceHandle() orelse return false;
        const target = if (tree.goto(
            Application.default().allocator(),
            active,
            to,
        )) |handle_|
            handle_ orelse return false
        else |err| switch (err) {
            // Nothing we can do in this scenario. This is highly unlikely
            // since split trees don't use that much memory. The application
            // is probably about to crash in other ways.
            error.OutOfMemory => return false,
        };

        // If we aren't changing targets then we did nothing.
        if (active == target) return false;

        // Get the surface at the target location and grab focus.
        const surface = tree.nodes[target.idx()].leaf;
        surface.grabFocus();

        // We also need to setup our last_focused to this because if we
        // trigger a tree change like below, the grab focus above never
        // actually triggers in time to set this and this ensures we
        // grab focus to the right thing.
        const old_last_focused = self.private().last_focused.get();
        defer if (old_last_focused) |v| v.unref(); // unref strong ref from get
        self.private().last_focused.set(surface);
        errdefer self.private().last_focused.set(old_last_focused);

        if (tree.zoomed != null) {
            const app = Application.default();
            const config_obj = app.getConfig();
            defer config_obj.unref();
            const config = config_obj.get();

            if (!config.@"split-preserve-zoom".navigation) {
                tree.zoomed = null;
            } else {
                tree.zoom(target);
            }

            // When the zoom state changes our tree state changes and
            // we need to send the proper notifications to trigger
            // relayout.
            const object = self.as(gobject.Object);
            object.notifyByPspec(properties.tree.impl.param_spec);
            object.notifyByPspec(properties.@"is-zoomed".impl.param_spec);
        }

        return true;
    }

    fn disconnectSurfaceHandlers(self: *Self) void {
        const tree = self.getTree() orelse return;
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            _ = gobject.signalHandlersDisconnectMatched(
                surface.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );
        }
    }

    fn connectSurfaceHandlers(self: *Self) void {
        const tree = self.getTree() orelse return;
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            _ = Surface.signals.@"close-request".connect(
                surface,
                *Self,
                surfaceCloseRequest,
                self,
                .{},
            );
            _ = gobject.Object.signals.notify.connect(
                surface,
                *Self,
                propSurfaceFocused,
                self,
                .{ .detail = "focused" },
            );
            _ = gobject.Object.signals.notify.connect(
                surface,
                *Self,
                propSurfaceMapped,
                self,
                .{ .detail = "mapped" },
            );
        }
    }

    //---------------------------------------------------------------
    // Properties

    /// Returns true if this split tree needs confirmation before quitting based
    /// on the various Ghostty configurations.
    pub fn getNeedsConfirmQuit(self: *Self) bool {
        const tree = self.getTree() orelse return false;
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.core()) |core| {
                if (core.needsConfirmQuit()) {
                    return true;
                }
            }
        }

        return false;
    }

    /// Get the currently active surface. See the "active-surface" property.
    /// This does not ref the value.
    pub fn getActiveSurface(self: *Self) ?*Surface {
        const tree = self.getTree() orelse return null;
        const handle = self.getActiveSurfaceHandle() orelse return null;
        return tree.nodes[handle.idx()].leaf;
    }

    fn getActiveSurfaceHandle(self: *Self) ?Surface.Tree.Node.Handle {
        const tree = self.getTree() orelse return null;
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.getFocused()) return entry.handle;
        }

        // If none are currently focused, the most previously focused
        // surface (if it exists) is our active surface. This lets things
        // like apprt actions and bell ringing continue to work in the
        // background.
        if (self.private().last_focused.get()) |v| {
            defer v.unref();

            // We need to find the handle of the last focused surface.
            it = tree.iterator();
            while (it.next()) |entry| {
                if (entry.view == v) return entry.handle;
            }
        }

        return null;
    }

    /// Returns the last focused surface in the tree.
    pub fn getLastFocusedSurface(self: *Self) ?*Surface {
        const surface = self.private().last_focused.get() orelse return null;
        // We unref because get() refs the surface. We don't use the weakref
        // in a multi-threaded context so this is safe.
        surface.unref();
        return surface;
    }

    pub fn getHasSurfaces(self: *Self) bool {
        const tree: *const Surface.Tree = self.private().tree orelse &.empty;
        return !tree.isEmpty();
    }

    pub fn getIsZoomed(self: *Self) bool {
        const tree: *const Surface.Tree = self.private().tree orelse &.empty;
        return tree.zoomed != null;
    }

    /// Get the tree data model that we're showing in this widget. This
    /// does not clone the tree.
    pub fn getTree(self: *Self) ?*Surface.Tree {
        return self.private().tree;
    }

    /// Set the tree data model that we're showing in this widget. This
    /// will clone the given tree.
    pub fn setTree(self: *Self, tree_: ?*const Surface.Tree) void {
        const priv = self.private();

        // We always normalize our tree parameter so that empty trees
        // become null so that we don't have to deal with callers being
        // confused about that.
        const tree: ?*const Surface.Tree = tree: {
            const tree = tree_ orelse break :tree null;
            if (tree.isEmpty()) break :tree null;
            break :tree tree;
        };

        // Emit the signal so that handlers can witness both the before and
        // after values of the tree.
        signals.changed.impl.emit(
            self,
            null,
            .{ priv.tree, tree },
            null,
        );

        if (priv.tree) |old_tree| {
            self.disconnectSurfaceHandlers();
            ext.boxedFree(Surface.Tree, old_tree);
            priv.tree = null;
        }

        if (tree) |new_tree| {
            assert(priv.tree == null);
            assert(!new_tree.isEmpty());
            priv.tree = ext.boxedCopy(Surface.Tree, new_tree);
            self.connectSurfaceHandlers();
        }

        self.as(gobject.Object).notifyByPspec(properties.tree.impl.param_spec);
    }

    fn getTreeValue(self: *Self, value: *gobject.Value) void {
        gobject.ext.Value.set(
            value,
            self.private().tree,
        );
    }

    fn setTreeValue(self: *Self, value: *const gobject.Value) void {
        self.setTree(gobject.ext.Value.get(
            value,
            ?*Surface.Tree,
        ));
    }

    pub fn getIsSplit(self: *Self) bool {
        const tree: *const Surface.Tree = self.private().tree orelse &.empty;
        if (tree.isEmpty()) return false;

        const root_handle: Surface.Tree.Node.Handle = .root;
        const root = tree.nodes[root_handle.idx()];
        return switch (root) {
            .leaf => false,
            .split => true,
        };
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.last_focused.set(null);
        if (priv.rebuild_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove rebuild source", .{});
            }
            priv.rebuild_source = null;
        }
        if (priv.restore_focus_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove restore_focus source", .{});
            }
            priv.restore_focus_source = null;
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.tree) |tree| {
            ext.boxedFree(Surface.Tree, tree);
            priv.tree = null;
        }

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal handlers

    pub fn actionNewSplit(
        _: *gio.SimpleAction,
        args_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const args = args_ orelse {
            log.warn("split-tree.new-split called without a parameter", .{});
            return;
        };

        var dir: ?[*:0]const u8 = null;
        args.get("&s", &dir);

        const direction = std.meta.stringToEnum(
            Surface.Tree.Split.Direction,
            std.mem.span(dir) orelse return,
        ) orelse {
            // Need to be defensive here since actions can be triggered externally.
            log.warn("invalid split direction for split-tree.new-split: {s}", .{dir.?});
            return;
        };

        self.newSplit(
            direction,
            self.getActiveSurface(),
            .none,
        ) catch |err| {
            log.warn("new split failed error={}", .{err});
        };
    }

    pub fn actionEqualize(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        _ = parameter_;

        const old_tree = self.getTree() orelse return;
        var new_tree = old_tree.equalize(Application.default().allocator()) catch |err| {
            log.warn("unable to equalize tree: {}", .{err});
            return;
        };
        defer new_tree.deinit();
        self.setTree(&new_tree);
    }

    pub fn actionZoom(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const tree = self.getTree() orelse return;
        if (tree.zoomed != null) {
            tree.zoomed = null;
        } else {
            const active = self.getActiveSurfaceHandle() orelse return;
            if (tree.zoomed == active) return;
            tree.zoom(active);
        }

        self.as(gobject.Object).notifyByPspec(properties.tree.impl.param_spec);
    }

    fn surfaceCloseRequest(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        const core = surface.core() orelse return;

        // Reset our pending close state
        const priv = self.private();
        priv.pending_close = null;

        // Find the surface in the tree to verify this is valid and
        // set our pending close handle.
        priv.pending_close = handle: {
            const tree = self.getTree() orelse return;
            var it = tree.iterator();
            while (it.next()) |entry| {
                if (entry.view == surface) {
                    break :handle entry.handle;
                }
            }

            return;
        };

        // If we don't need to confirm then just close immediately.
        if (!core.needsConfirmQuit()) {
            closeConfirmationClose(
                null,
                self,
            );
            return;
        }

        // Show a confirmation dialog
        const dialog: *CloseConfirmationDialog = .new(.surface);
        _ = CloseConfirmationDialog.signals.@"close-request".connect(
            dialog,
            *Self,
            closeConfirmationClose,
            self,
            .{},
        );
        dialog.present(self.as(gtk.Widget));
    }

    fn closeConfirmationClose(
        _: ?*CloseConfirmationDialog,
        self: *Self,
    ) callconv(.c) void {
        // Get the handle we're closing
        const priv = self.private();
        const handle = priv.pending_close orelse return;
        priv.pending_close = null;

        // Figure out our next focus target. The next focus target is
        // always the "previous" surface unless we're the leftmost then
        // its the next.
        const old_tree = self.getTree() orelse return;
        const next_focus: ?*Surface = next_focus: {
            const alloc = Application.default().allocator();
            const next_handle: Surface.Tree.Node.Handle =
                (old_tree.goto(alloc, handle, .previous) catch null) orelse
                (old_tree.goto(alloc, handle, .next) catch null) orelse
                break :next_focus null;
            if (next_handle == handle) break :next_focus null;

            // Note: we don't need to ref this or anything because its
            // guaranteed to remain in the new tree since its not part
            // of the handle we're removing.
            break :next_focus old_tree.nodes[next_handle.idx()].leaf;
        };

        // Remove it from the tree.
        var new_tree = old_tree.remove(
            Application.default().allocator(),
            handle,
        ) catch |err| {
            log.warn("unable to remove surface from tree: {}", .{err});
            return;
        };
        defer new_tree.deinit();
        self.setTree(&new_tree);

        // Grab focus. We have to set this on the "last focused" because our
        // focus will be set when the tree is redrawn.
        if (next_focus) |v| priv.last_focused.set(v);
    }

    fn propSurfaceFocused(
        surface: *Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // We never CLEAR our last_focused because the property is specifically
        // the last focused surface. We let the weakref clear itself when
        // the surface is destroyed.
        if (!surface.getFocused()) return;
        self.private().last_focused.set(surface);

        // Our active surface probably changed
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }

    fn propSurfaceMapped(
        surface: *Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        if (!surface.getMapped()) return;

        // We could add the idle callback only if this is actually the last
        // focused surface. But we can avoid that check because usually all
        // the surfaces get mapped at once, so the idle callback will run
        // only once anyway.
        const priv = self.private();
        if (priv.restore_focus_source == null) priv.restore_focus_source = glib.idleAdd(
            onRestoreFocus,
            self,
        );
    }

    fn propTree(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();

        // No matter what we notify
        self.as(gobject.Object).freezeNotify();
        defer self.as(gobject.Object).thawNotify();
        self.as(gobject.Object).notifyByPspec(properties.@"has-surfaces".impl.param_spec);
        self.as(gobject.Object).notifyByPspec(properties.@"is-zoomed".impl.param_spec);

        // If we were planning a rebuild or focus restore, always remove
        // that so we can start from a clean slate.
        if (priv.rebuild_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove rebuild source", .{});
            }
            priv.rebuild_source = null;
        }
        if (priv.restore_focus_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove restore_focus source", .{});
            }
            priv.restore_focus_source = null;
        }

        // If we transitioned to an empty tree, clear immediately instead of
        // waiting for an idle callback. Delaying teardown can keep the last
        // surface alive during shutdown if the main loop exits first.
        if (priv.tree == null) {
            priv.tree_bin.setChild(null);
            return;
        }

        // Build on an idle callback so rapid tree changes are debounced.
        // We keep the existing tree attached until the rebuild runs,
        // which avoids transient empty frames.
        assert(priv.rebuild_source == null);
        priv.rebuild_source = glib.idleAdd(
            onRebuild,
            self,
        );
    }

    fn onRebuild(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));

        // Always mark our rebuild source as null since we're done.
        const priv = self.private();
        priv.rebuild_source = null;

        // Rebuild our tree
        const tree: *const Surface.Tree = self.private().tree orelse &.empty;
        if (tree.isEmpty()) {
            priv.tree_bin.setChild(null);
        } else {
            const built = self.buildTree(
                tree,
                tree.zoomed orelse .root,
            );
            defer built.deinit();
            priv.tree_bin.setChild(built.widget);
        }

        // Replacing our tree widget hierarchy can reset focus state.
        // If we have a last-focused surface, restore focus to it.
        if (priv.last_focused.get()) |v| {
            defer v.unref();
            v.grabFocus();
        }

        // Our split status may have changed
        self.as(gobject.Object).notifyByPspec(properties.@"is-split".impl.param_spec);

        // Our active surface may have changed
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);

        return 0;
    }

    fn onRestoreFocus(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));

        // Always mark our source as null since we're done.
        const priv = self.private();
        priv.restore_focus_source = null;

        // If we have a last-focused surface and it is mapped, restore focus
        // to it. Depending on the available size, the surface might already
        // have focus because it never got unmapped. In that case grabbing
        // focus will have no effect.
        if (priv.last_focused.get()) |v| {
            defer v.unref();
            if (v.getMapped()) {
                v.grabFocus();
            }
        }
        return 0;
    }

    /// Builds the widget tree associated with a surface split tree.
    ///
    /// Returned widgets are expected to be attached to a parent by the caller.
    ///
    /// If `release_ref` is true then `widget` has an extra temporary
    /// reference that must be released once it is parented in the rebuilt
    /// tree.
    const BuildTreeResult = struct {
        widget: *gtk.Widget,
        release_ref: bool,

        pub fn initNew(widget: *gtk.Widget) BuildTreeResult {
            return .{ .widget = widget, .release_ref = false };
        }

        pub fn initReused(widget: *gtk.Widget) BuildTreeResult {
            // We add a temporary ref to the widget to ensure it doesn't
            // get destroyed while we're rebuilding the tree and detaching
            // it from its old parent. The caller is expected to release
            // this ref once the widget is attached to its new parent.
            _ = widget.as(gobject.Object).ref();

            // Detach after we ref it so that this doesn't mark the
            // widget for destruction.
            detachWidget(widget);

            return .{ .widget = widget, .release_ref = true };
        }

        pub fn deinit(self: BuildTreeResult) void {
            // If we have to release a ref, do it.
            if (self.release_ref) self.widget.as(gobject.Object).unref();
        }
    };

    fn buildTree(
        self: *Self,
        tree: *const Surface.Tree,
        current: Surface.Tree.Node.Handle,
    ) BuildTreeResult {
        return switch (tree.nodes[current.idx()]) {
            .leaf => |v| leaf: {
                const window = ext.getAncestor(
                    SurfaceScrolledWindow,
                    v.as(gtk.Widget),
                ) orelse {
                    // The surface isn't in a window already so we don't
                    // have to worry about reuse.
                    break :leaf .initNew(gobject.ext.newInstance(
                        SurfaceScrolledWindow,
                        .{ .surface = v },
                    ).as(gtk.Widget));
                };

                // Keep this widget alive while we detach it from the
                // old tree and adopt it into the new one.
                break :leaf .initReused(window.as(gtk.Widget));
            },
            .split => |s| split: {
                const left = self.buildTree(tree, s.left);
                defer left.deinit();
                const right = self.buildTree(tree, s.right);
                defer right.deinit();

                break :split .initNew(SplitTreeSplit.new(
                    tree,
                    current,
                    &s,
                    left.widget,
                    right.widget,
                ).as(gtk.Widget));
            },
        };
    }

    /// Detach a split widget from its current parent.
    ///
    /// We intentionally use parent-specific child APIs when possible
    /// (`GtkPaned.setStartChild/setEndChild`, `AdwBin.setChild`) instead of
    /// calling `gtk.Widget.unparent` directly. Container implementations track
    /// child pointers/properties internally, and those setters are the path
    /// that keeps container state and notifications in sync.
    fn detachWidget(widget: *gtk.Widget) void {
        const parent = widget.getParent() orelse return;

        // Surface will be in a paned when it is split.
        if (gobject.ext.cast(gtk.Paned, parent)) |paned| {
            if (paned.getStartChild()) |child| {
                if (child == widget) {
                    paned.setStartChild(null);
                    return;
                }
            }

            if (paned.getEndChild()) |child| {
                if (child == widget) {
                    paned.setEndChild(null);
                    return;
                }
            }
        }

        // Surface will be in a bin when it is not split.
        if (gobject.ext.cast(adw.Bin, parent)) |bin| {
            if (bin.getChild()) |child| {
                if (child == widget) {
                    bin.setChild(null);
                    return;
                }
            }
        }

        // Fallback for unexpected parents where we don't have a typed
        // container API available.
        widget.unparent();
    }

    //---------------------------------------------------------------
    // Class

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(Surface);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "split-tree",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"active-surface".impl,
                properties.@"has-surfaces".impl,
                properties.@"is-zoomed".impl,
                properties.tree.impl,
                properties.@"is-split".impl,
            });

            // Bindings
            class.bindTemplateChildPrivate("tree_bin", .{});

            // Template Callbacks
            class.bindTemplateCallback("notify_tree", &propTree);

            // Signals
            signals.changed.impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

/// This is an internal-only widget that represents a split in the
/// split tree. This is a wrapper around gtk.Paned that allows us to handle
/// ratio (0 to 1) based positioning of the split, and also allows us to
/// write back the updated ratio to the split tree when the user manually
/// adjusts the split position.
///
/// Since this is internal, it expects to be nested within a SplitTree and
/// will use `getAncestor` to find the SplitTree it belongs to.
///
/// This is an _immutable_ widget. It isn't meant to be updated after
/// creation. As such, there are no properties or APIs to change the split,
/// access the paned, etc.
const SplitTreeSplit = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySplitTreeSplit",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        /// The handle of the node in the tree that this split represents.
        /// Assumed to be correct.
        handle: Surface.Tree.Node.Handle,

        /// The layout (orientation) of this split, cached from the tree at
        /// construction time. The Paned's orientation reflects this; storing
        /// it here saves us querying GtkOrientable on every drag/position
        /// callback.
        layout: Surface.Tree.Split.Layout = .horizontal,

        /// Source to handle repositioning the split when properties change.
        idle: ?c_uint = null,

        /// Whether the max-position/position property of the gtk.Paned widget
        /// changed. We use these to distinguish between a resize and the user
        /// manually moving the split divider. See the "on-idle" function.
        max_changed: bool = false,
        pos_changed: bool = false,

        // Template bindings
        paned: *gtk.Paned,
        overlay: *gtk.Overlay,

        /// Junction handle widgets, if this split has a perpendicular inner
        /// split on the corresponding side. Both null in the common
        /// no-junction case. The widgets are owned by `overlay` once added.
        junction_handle_left: ?*gtk.Widget = null,
        junction_handle_right: ?*gtk.Widget = null,

        /// References to the inner perpendicular SplitTreeSplits, used at
        /// drag time to look up and update their `Paned.position`. Cleared
        /// in `dispose`.
        junction_inner_left: ?*SplitTreeSplit = null,
        junction_inner_right: ?*SplitTreeSplit = null,

        /// State captured at drag-begin so drag-update can compute
        /// absolute positions from gesture offsets without re-reading the
        /// (now-moving) Paned positions mid-drag.
        drag_outer_start: c_int = 0,
        drag_inner_start: c_int = 0,
        /// If true, the current drag is a `+`-junction: update both inners
        /// in lockstep with the same new perpendicular position.
        drag_plus_lockstep: bool = false,
        drag_inner_other_start: c_int = 0,

        /// The handle widget currently being dragged, if any. While set, the
        /// `get-child-position` callback freezes that widget's allocation to
        /// `drag_handle_alloc` instead of recomputing it from the Paneds.
        /// This is what stops `GtkGestureDrag`'s widget-local offsets from
        /// drifting as the dividers move under the cursor.
        drag_active_widget: ?*gtk.Widget = null,
        drag_handle_alloc: gdk.Rectangle = .{
            .f_x = 0,
            .f_y = 0,
            .f_width = 0,
            .f_height = 0,
        },

        pub var offset: c_int = 0;
    };

    /// Create a new split.
    ///
    /// The reason we don't use GObject properties here is because this is
    /// an immutable widget and we don't want to deal with the overhead of
    /// all the boilerplate for properties, signals, bindings, etc.
    pub fn new(
        tree: *const Surface.Tree,
        handle: Surface.Tree.Node.Handle,
        split: *const Surface.Tree.Split,
        start_child: *gtk.Widget,
        end_child: *gtk.Widget,
    ) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const priv = self.private();
        priv.handle = handle;
        priv.layout = split.layout;

        // Setup our paned fields
        const paned = priv.paned;
        paned.setStartChild(start_child);
        paned.setEndChild(end_child);
        paned.as(gtk.Orientable).setOrientation(switch (split.layout) {
            .horizontal => .horizontal,
            .vertical => .vertical,
        });

        // Signals and so on are setup in the template.

        // If this split has perpendicular inner children, install junction
        // drag handles on top of the Paned via the overlay.
        self.setupJunction(tree, handle, start_child, end_child);

        return self;
    }

    /// Side length of the invisible junction hit zone. Sized slightly larger
    /// than GtkPaned's resize-handle width so it wins hit-testing inside the
    /// small corner area where two perpendicular dividers meet.
    const junction_hit_size: c_int = 12;

    /// Install junction-drag handles on the overlay for any perpendicular
    /// inner split. We query the CORE `junctionAt` helper to decide whether a
    /// junction exists (and on which sides), so the geometric definition of a
    /// junction stays in one place (`datastruct/split_tree.zig`).
    ///
    /// IMPORTANT (untested-on-macOS implementation note): unlike the core
    /// `junctionResize` helper — which produces a *new* tree with coordinated
    /// ratios — this widget performs the actual drag entirely in GtkPaned
    /// pixel space (`Paned.setPosition`) and never rebuilds the tree during
    /// the gesture. See `onJunctionDragUpdate` for why. The new ratios get
    /// persisted back into the tree through the EXISTING position-notify ->
    /// onIdle path once the Paned positions settle. We therefore deliberately
    /// do NOT call `junctionResize`; we only reuse `junctionAt` and the shared
    /// `junction_plus_epsilon` constant.
    fn setupJunction(
        self: *Self,
        tree: *const Surface.Tree,
        handle: Surface.Tree.Node.Handle,
        start_child: *gtk.Widget,
        end_child: *gtk.Widget,
    ) void {
        const j = tree.junctionAt(handle) orelse return;
        const priv = self.private();

        if (j.left != null) {
            if (gobject.ext.cast(SplitTreeSplit, start_child)) |inner| {
                priv.junction_inner_left = inner;
                priv.junction_handle_left = createJunctionHandle(self);
                priv.overlay.addOverlay(priv.junction_handle_left.?);
            }
        }
        if (j.right != null) {
            if (gobject.ext.cast(SplitTreeSplit, end_child)) |inner| {
                priv.junction_inner_right = inner;
                priv.junction_handle_right = createJunctionHandle(self);
                priv.overlay.addOverlay(priv.junction_handle_right.?);
            }
        }

        // Bail if we ended up not installing anything (e.g. the cast above
        // failed unexpectedly).
        if (priv.junction_handle_left == null and priv.junction_handle_right == null) return;

        // Position each handle dynamically: its location depends on the
        // outer Paned position (which the user may be dragging right now)
        // and the inner Paned position (which the user may also be dragging).
        _ = gtk.Overlay.signals.get_child_position.connect(
            priv.overlay,
            *Self,
            &onJunctionChildPosition,
            self,
            .{},
        );
    }

    fn createJunctionHandle(self: *Self) *gtk.Widget {
        const box = gtk.Box.new(.horizontal, 0);
        const widget = box.as(gtk.Widget);
        widget.setSizeRequest(junction_hit_size, junction_hit_size);
        widget.setCursorFromName("crosshair");
        // We don't want the overlay's main-child (the Paned) to expand to
        // fill our junction handle: keep our handle at its requested size.
        widget.setHalign(.start);
        widget.setValign(.start);

        const gesture = gtk.GestureDrag.new();
        _ = gtk.GestureDrag.signals.drag_begin.connect(
            gesture,
            *Self,
            &onJunctionDragBegin,
            self,
            .{},
        );
        _ = gtk.GestureDrag.signals.drag_update.connect(
            gesture,
            *Self,
            &onJunctionDragUpdate,
            self,
            .{},
        );
        _ = gtk.GestureDrag.signals.drag_end.connect(
            gesture,
            *Self,
            &onJunctionDragEnd,
            self,
            .{},
        );
        widget.addController(gesture.as(gtk.EventController));

        return widget;
    }

    /// Return the inner Paned associated with the given junction-handle
    /// widget, or null if `widget` isn't one of our two handles.
    fn innerPanedFor(self: *Self, widget: *gtk.Widget) ?*gtk.Paned {
        const priv = self.private();
        if (priv.junction_handle_left) |h| {
            if (h == widget) return priv.junction_inner_left.?.private().paned;
        }
        if (priv.junction_handle_right) |h| {
            if (h == widget) return priv.junction_inner_right.?.private().paned;
        }
        return null;
    }

    /// Return the "other" inner Paned — the one not bound to the dragged
    /// handle. Used for the `+`-junction lockstep update.
    fn otherInnerPaned(self: *Self, widget: *gtk.Widget) ?*gtk.Paned {
        const priv = self.private();
        if (priv.junction_handle_left) |h| {
            if (h == widget) {
                if (priv.junction_inner_right) |inner| return inner.private().paned;
                return null;
            }
        }
        if (priv.junction_handle_right) |h| {
            if (h == widget) {
                if (priv.junction_inner_left) |inner| return inner.private().paned;
                return null;
            }
        }
        return null;
    }

    fn onJunctionChildPosition(
        _: *gtk.Overlay,
        widget: *gtk.Widget,
        allocation: *gdk.Rectangle,
        self: *Self,
    ) callconv(.c) c_int {
        const priv = self.private();
        const inner_paned = self.innerPanedFor(widget) orelse return 0;

        // While a drag is in progress on this handle, freeze its allocation
        // to where it was at drag-start. Moving it under the cursor breaks
        // GtkGestureDrag's widget-local offset arithmetic and causes the
        // cursor-vs-handle gap to grow linearly with drag distance.
        if (priv.drag_active_widget) |dw| if (dw == widget) {
            allocation.* = priv.drag_handle_alloc;
            return 1;
        };

        const outer_pos = priv.paned.getPosition();
        const inner_pos = inner_paned.getPosition();
        const half = @divTrunc(junction_hit_size, 2);

        switch (priv.layout) {
            .horizontal => {
                allocation.f_x = outer_pos - half;
                allocation.f_y = inner_pos - half;
            },
            .vertical => {
                allocation.f_x = inner_pos - half;
                allocation.f_y = outer_pos - half;
            },
        }
        allocation.f_width = junction_hit_size;
        allocation.f_height = junction_hit_size;
        return 1;
    }

    fn onJunctionDragBegin(
        gesture: *gtk.GestureDrag,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const widget = gesture.as(gtk.EventController).getWidget() orelse return;
        const inner_paned = self.innerPanedFor(widget) orelse return;

        priv.drag_outer_start = priv.paned.getPosition();
        priv.drag_inner_start = inner_paned.getPosition();

        // Freeze the handle widget's allocation for the duration of the drag
        // so the gesture's reported offsets stay anchored to a stable frame.
        priv.drag_active_widget = widget;
        const half = @divTrunc(junction_hit_size, 2);
        switch (priv.layout) {
            .horizontal => {
                priv.drag_handle_alloc.f_x = priv.drag_outer_start - half;
                priv.drag_handle_alloc.f_y = priv.drag_inner_start - half;
            },
            .vertical => {
                priv.drag_handle_alloc.f_x = priv.drag_inner_start - half;
                priv.drag_handle_alloc.f_y = priv.drag_outer_start - half;
            },
        }
        priv.drag_handle_alloc.f_width = junction_hit_size;
        priv.drag_handle_alloc.f_height = junction_hit_size;

        // Decide whether this is a `+`-junction drag: both inners present,
        // currently at approximately the same perpendicular position. We
        // compare normalized ratios against the SHARED core epsilon
        // (`Surface.Tree.junction_plus_epsilon`) so the GTK lockstep
        // threshold can never drift from the core's lockstep threshold.
        priv.drag_plus_lockstep = false;
        if (self.otherInnerPaned(widget)) |other| {
            const other_pos = other.getPosition();
            const this_pos: f64 = @floatFromInt(priv.drag_inner_start);
            const other_pos_f: f64 = @floatFromInt(other_pos);
            const max_extent: f64 = perpendicularExtent: {
                // Use the perpendicular axis size of the outer Paned. For a
                // horizontal split (vertical divider) the perpendicular axis
                // is the height; for a vertical split it's the width.
                const paned_widget = priv.paned.as(gtk.Widget);
                const a: f64 = @floatFromInt(paned_widget.getHeight());
                const b: f64 = @floatFromInt(paned_widget.getWidth());
                break :perpendicularExtent switch (priv.layout) {
                    .horizontal => a,
                    .vertical => b,
                };
            };
            if (max_extent > 0) {
                const this_ratio = this_pos / max_extent;
                const other_ratio = other_pos_f / max_extent;
                const epsilon: f64 = Surface.Tree.junction_plus_epsilon;
                if (@abs(this_ratio - other_ratio) < epsilon) {
                    priv.drag_plus_lockstep = true;
                    priv.drag_inner_other_start = other_pos;
                }
            }
        }
    }

    fn onJunctionDragUpdate(
        gesture: *gtk.GestureDrag,
        offset_x: f64,
        offset_y: f64,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const widget = gesture.as(gtk.EventController).getWidget() orelse return;
        const inner_paned = self.innerPanedFor(widget) orelse return;

        const dx: c_int = @intFromFloat(@round(offset_x));
        const dy: c_int = @intFromFloat(@round(offset_y));

        // The outer divider moves along this split's own axis; the inner
        // (perpendicular) divider moves along the other axis. We drive both
        // GtkPaneds directly in pixel space. We intentionally do NOT call the
        // core `junctionResize` here: that helper returns a brand-new tree,
        // which would force a full widget-tree rebuild on every motion event,
        // tearing down and recreating the very SplitTreeSplit widgets (and the
        // GestureDrag) mid-gesture. Live GtkPaned manipulation keeps the drag
        // smooth; the resulting ratios are persisted to the tree afterwards by
        // the existing position-notify -> onIdle path.
        const outer_delta: c_int = switch (priv.layout) {
            .horizontal => dx,
            .vertical => dy,
        };
        const inner_delta: c_int = switch (priv.layout) {
            .horizontal => dy,
            .vertical => dx,
        };

        priv.paned.setPosition(priv.drag_outer_start + outer_delta);
        inner_paned.setPosition(priv.drag_inner_start + inner_delta);

        if (priv.drag_plus_lockstep) {
            if (self.otherInnerPaned(widget)) |other| {
                other.setPosition(priv.drag_inner_other_start + inner_delta);
            }
        }
    }

    fn onJunctionDragEnd(
        _: *gtk.GestureDrag,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.drag_active_widget = null;
        priv.drag_plus_lockstep = false;

        // The handle has been frozen in place throughout the drag. Now that
        // the drag is over, re-run the overlay's layout so the handle snaps
        // to its new geometric position (recomputed from the current Paned
        // positions).
        priv.overlay.as(gtk.Widget).queueResize();
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    // We need to keep the split ratios from the tree datastructure and
    // widget tree in sync. Using the max-position and position properties
    // of the gtk.Paned widget, we can distinguish a resize from a manual
    // update (e.g. the user dragging the divider).If max-position changes,
    // we always have a widget resize. Usually position will change as well
    // but it might not if the size change is small enough. If only position
    // changes, we have a manual human update.
    //
    // This is a hack, it relies on the timing of property notifcations.
    // From looking at the GTK source code, it should not be possible that
    // we interpret a position change from a resize as a manual update.
    // When a gtk.Paned is resized, internally the gtk_paned_calc_position
    // function will change both max-position and position and synchronously
    // call our propMaxPosition and propPosition functions. I.e. when the
    // widget is resized, it should not be possible for onIdle to run before
    // we have been notified of both property changes.
    fn onIdle(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        const paned = priv.paned;

        // Clear source and fields at the end. Otherwise if setPosition is
        // called below, propPosition is triggered and would add another
        // idle callback before this one is finished.
        defer priv.idle = null;
        defer priv.max_changed = false;
        defer priv.pos_changed = false;

        if (!priv.max_changed and !priv.pos_changed) {
            return 0;
        }

        // Get our split. This is the most dangerous part of this entire
        // widget. We assume that this widget is always a child of a
        // SplitTree, we assume that our handle is valid, and we assume
        // the handle is always a split node.
        const split_tree = ext.getAncestor(
            SplitTree,
            self.as(gtk.Widget),
        ) orelse return 0;
        const tree = split_tree.getTree() orelse return 0;
        const split: *const Surface.Tree.Split = &tree.nodes[priv.handle.idx()].split;

        // Current, min, and max positions as pixels.
        const pos = paned.getPosition();
        const min = min: {
            var val = gobject.ext.Value.new(c_int);
            defer val.unset();
            gobject.Object.getProperty(
                paned.as(gobject.Object),
                "min-position",
                &val,
            );
            break :min gobject.ext.Value.get(&val, c_int);
        };
        const max = max: {
            var val = gobject.ext.Value.new(c_int);
            defer val.unset();
            gobject.Object.getProperty(
                paned.as(gobject.Object),
                "max-position",
                &val,
            );
            break :max gobject.ext.Value.get(&val, c_int);
        };

        // We don't actually use min, but we don't expect this to ever
        // be non-zero, so let's add an assert to ensure that.
        assert(min == 0);

        // If our max is zero then we can't do any math. I don't know
        // if this is possible but I suspect it can be if you make a nested
        // split completely minimized.
        if (max == 0) return 0;

        // Determine our current ratio.
        const current_ratio: f64 = ratio: {
            const pos_f64: f64 = @floatFromInt(pos);
            const max_f64: f64 = @floatFromInt(max);
            break :ratio pos_f64 / max_f64;
        };
        const desired_ratio: f64 = @floatCast(split.ratio);

        // If our ratio is close enough to our desired ratio, then
        // we ignore the update. This is to avoid constant split updates
        // for lossy floating point math.
        if (std.math.approxEqAbs(
            f64,
            current_ratio,
            desired_ratio,
            0.001,
        )) {
            return 0;
        }

        if (priv.max_changed) {
            // Widget got resized, update position to match desired ratio.
            // Note that if max-position is small, it might not be possible
            // to accurately set the desired ratio. E.g. with max-position=2
            // you can only have ratios 0, 0.5 and 1.
            const desired_pos: c_int = desired_pos: {
                const max_f64: f64 = @floatFromInt(max);
                break :desired_pos @intFromFloat(@round(max_f64 * desired_ratio));
            };
            paned.setPosition(desired_pos);
        } else {
            // If only position changed, this is a manual human update and
            // we need to write our update back to the tree.
            tree.resizeInPlace(priv.handle, @floatCast(current_ratio));
        }
        return 0;
    }

    //---------------------------------------------------------------
    // Signal handlers

    fn propMaxPosition(
        _: *gtk.Paned,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.max_changed = true;
        if (priv.idle == null) priv.idle = glib.idleAdd(
            onIdle,
            self,
        );
    }

    fn propPosition(
        _: *gtk.Paned,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.pos_changed = true;
        if (priv.idle == null) priv.idle = glib.idleAdd(
            onIdle,
            self,
        );
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.idle) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove idle source", .{});
            }
            priv.idle = null;
        }

        // Clear the cached pointers to the inner perpendicular splits and
        // their handle widgets so nothing dangles after dispose. The handle
        // widgets are owned by `overlay` (disposed via disposeTemplate below);
        // the inner splits are owned by the Paned. We only null our borrowed
        // references here — we do not unref/unparent them ourselves.
        priv.junction_inner_left = null;
        priv.junction_inner_right = null;
        priv.junction_handle_left = null;
        priv.junction_handle_right = null;
        priv.drag_active_widget = null;

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "split-tree-split",
                }),
            );

            // Bindings
            class.bindTemplateChildPrivate("paned", .{});
            class.bindTemplateChildPrivate("overlay", .{});

            // Template Callbacks
            class.bindTemplateCallback("notify_max_position", &propMaxPosition);
            class.bindTemplateCallback("notify_position", &propPosition);

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
