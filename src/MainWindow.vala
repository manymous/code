// -*- Mode: vala; indent-tabs-mode: nil; tab-width: 4 -*-
/***
  BEGIN LICENSE

  Copyright (C) 2011-2013 Mario Guerriero <mefrio.g@gmail.com>
  This program is free software: you can redistribute it and/or modify it
  under the terms of the GNU Lesser General Public License version 3, as published
  by the Free Software Foundation.

  This program is distributed in the hope that it will be useful, but
  WITHOUT ANY WARRANTY; without even the implied warranties of
  MERCHANTABILITY, SATISFACTORY QUALITY, or FITNESS FOR A PARTICULAR
  PURPOSE.  See the GNU General Public License for more details.

  You should have received a copy of the GNU General Public License along
  with this program.  If not, see <http://www.gnu.org/licenses/>

  END LICENSE
***/

using Gtk;
using Gdk;
using Pango;
 
#if HAVE_ZEITGEIST
using Zeitgeist;
#endif

using Granite.Widgets;
using Granite.Services;

namespace Scratch {
    
    public class MainWindow : Gtk.Window {
        public weak ScratchApp app;

        // Widgets
        public Scratch.Widgets.Toolbar toolbar;
        public Scratch.Widgets.Toolbar fullscreen_toolbar;
        private Gtk.Overlay overlay;
        private Gtk.EventBox fullscreen_eventbox;
        private Gtk.Revealer search_revealer;
        private Gtk.Revealer fullscreen_revealer;
        public Scratch.Widgets.SearchManager search_manager;
        public Scratch.Widgets.LoadingView loading_view;
        public Scratch.Widgets.SplitView split_view;

        // Plugins
        private Scratch.Services.PluginsManager plugins;

        // Widgets for Plugins
        public Gtk.Notebook sidebar;
        public Gtk.Notebook contextbar;
        public Gtk.Notebook bottombar;
        
        private Granite.Widgets.ThinPaned hp1;
        private Granite.Widgets.ThinPaned hp2;
        private Granite.Widgets.ThinPaned vp;

        // GtkActions
        public Gtk.ActionGroup main_actions;
        public Gtk.UIManager ui;

#if HAVE_ZEITGEIST
        // Zeitgeist integration
        private Zeitgeist.DataSourceRegistry registry;
#endif
        
        // Delegates
        delegate void HookFunc ();
        
        public MainWindow (Scratch.ScratchApp scratch_app) {
            this.app = scratch_app;
            set_application (this.app);
            this.title = this.app.app_cmd_name;
            this.window_position = Gtk.WindowPosition.CENTER;
            this.set_size_request (450, 400);
            restore_saved_state ();
            this.icon_name = "accessories-text-editor";

            plugins = new Scratch.Services.PluginsManager (this, app.app_cmd_name.down ());

            // Set up GtkActions
            init_actions ();

            // Set up layout
            init_layout ();

            // Restore session
            restore_saved_state_extra ();

#if HAVE_ZEITGEIST
            // Set up the Data Source Registry for Zeitgeist
            registry = new DataSourceRegistry ();

            var ds_event = new Zeitgeist.Event ();
            ds_event.actor = "application://scratch-text-editor.desktop";
            ds_event.add_subject (new Zeitgeist.Subject ());
            GenericArray<Zeitgeist.Event> ds_events = new GenericArray<Zeitgeist.Event>();
            ds_events.add(ds_event);
            var ds = new DataSource.full ("scratch-logger",
                                          _("Zeitgeist Datasource for Scratch"),
                                          "A data source which logs Open, Close, Save and Move Events",
                                          ds_events); // FIXME: templates!
            registry.register_data_source.begin (ds, null, (obj, res) => {
                try {
                    registry.register_data_source.end (res);
                } catch (GLib.Error reg_err) {
                    warning ("%s", reg_err.message);
                }
            });
#endif

            Unix.signal_add (Posix.SIGINT, quit_source_func, Priority.HIGH);
            Unix.signal_add (Posix.SIGTERM, quit_source_func, Priority.HIGH);
        }

        private void init_actions () {
            // Actions
            main_actions = new Gtk.ActionGroup ("MainActionGroup"); /* Actions and UIManager */
            main_actions.set_translation_domain (Constants.GETTEXT_PACKAGE);
            main_actions.add_actions (main_entries, this);
            main_actions.add_toggle_actions (toggle_entries, this);

            // UIManager
            ui = new Gtk.UIManager ();

            try {
                ui.add_ui_from_file (Utils.UI_PATH);
            }
            catch(Error e) {
                error ("Couldn't load the UI: %s", e.message);
            }

            Gtk.AccelGroup accel_group = ui.get_accel_group();
            add_accel_group (accel_group);

            ui.insert_action_group (main_actions, 0);
            ui.ensure_update ();

        }

        private void init_layout () {
            var main_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

            // Toolbar
            this.toolbar = new Scratch.Widgets.Toolbar (main_actions);
            this.toolbar.title = this.title;
            this.toolbar.show_close_button = true;
            this.set_titlebar (this.toolbar);
            toolbar.menu = ui.get_widget ("ui/AppMenu") as Gtk.Menu;
            var app_menu = (app as Granite.Application).create_appmenu (toolbar.menu);
            toolbar.pack_end (app_menu);
            
            //Fullscreen Toolbar
            this.fullscreen_toolbar = new Scratch.Widgets.Toolbar (main_actions);
            this.fullscreen_revealer = new Gtk.Revealer ();
            fullscreen_revealer.set_can_focus (false);
            fullscreen_revealer.set_valign (Gtk.Align.START);
            this.overlay = new Gtk.Overlay ();
            this.fullscreen_eventbox = new Gtk.EventBox ();
            this.fullscreen_eventbox.set_size_request (-1, 1);
            this.fullscreen_eventbox.set_can_focus (false);
            fullscreen_eventbox.set_valign (Gtk.Align.START);
            this.fullscreen_eventbox.add (this.fullscreen_revealer);

            // SearchManager
            this.search_revealer = new Gtk.Revealer ();
            this.search_manager = new Scratch.Widgets.SearchManager (this);
            this.search_manager.get_style_context ().add_class ("secondary-toolbar");
            this.search_revealer.add (this.search_manager);

            // SlitView
            this.split_view = new Scratch.Widgets.SplitView (this);
    
            // LoadingView
            this.loading_view = new Scratch.Widgets.LoadingView ();
                
            // Signals
            this.split_view.welcome_shown.connect (() => {
                set_widgets_sensitive (false);
                this.toolbar.subtitle = null;
                
            });
            this.split_view.welcome_hidden.connect (() => {
                set_widgets_sensitive (true);
            });
            this.split_view.document_change.connect ((doc) => {
                this.search_manager.set_text_view (doc.source_view);
                // Update MainWindow title
                if (doc != null && doc.file != null) {
                    var home_dir = Environment.get_home_dir ();
                    var path = Path.get_dirname (doc.file.get_uri ()).replace (home_dir, "~");
                    path = path.replace ("file://", "");

                    if ("trash://" in path)
                        path = _("Trash");

                    path = Uri.unescape_string (path);
                    this.toolbar.subtitle = doc.file.get_basename () + " (%s)".printf(path);
                }
                else {
                    this.toolbar.subtitle = null;
                }
                // Set actions sensitive property
                main_actions.get_action ("SaveFile").visible = (!settings.autosave || doc.file == null);
                doc.check_undoable_actions ();
            });
            this.fullscreen_eventbox.enter_notify_event.connect (()=>{
                this.fullscreen_revealer.set_reveal_child (true);
                return false;
            });
            this.fullscreen_eventbox.leave_notify_event.connect (()=>{
                this.fullscreen_revealer.set_reveal_child (false);
                return false;
            });

            // Plugins widgets
            this.sidebar = new Gtk.Notebook ();
            this.sidebar.no_show_all = true;
            this.sidebar.page_added.connect (() => { on_plugin_toggled (sidebar); });
            this.sidebar.page_removed.connect (() => { on_plugin_toggled (sidebar); });

            this.contextbar = new Gtk.Notebook ();
            this.contextbar.no_show_all = true;
            this.contextbar.page_added.connect (() => { on_plugin_toggled (contextbar); });
            this.contextbar.page_removed.connect (() => { on_plugin_toggled (contextbar); });

            this.bottombar = new Gtk.Notebook ();
            this.bottombar.no_show_all = true;
            this.bottombar.page_added.connect (() => { on_plugin_toggled (bottombar); });
            this.bottombar.page_removed.connect (() => { on_plugin_toggled (bottombar); });

            hp1 = new Granite.Widgets.ThinPaned ();
            hp2 = new Granite.Widgets.ThinPaned ();
            vp = new Granite.Widgets.ThinPaned ();
            vp.orientation = Orientation.VERTICAL;
            
            // Set a proper position for ThinPaned widgets
            int width, height;
            this.get_size (out width, out height);
            
            hp1.position = 180;
            hp2.position = (width - 180);
            vp.position = (height - 150);

            hp1.pack1 (sidebar, false, false);
            hp1.pack2 (split_view, true, false);
            hp2.pack1 (hp1, true, false);
            hp2.pack2 (contextbar, false, false);
            vp.pack1 (hp2, true, false);
            vp.pack2 (bottombar, false, false);

            // Add everything to the window
            main_box.pack_start (search_revealer, false, true, 0);
            main_box.pack_start (loading_view, true, true, 0);
            main_box.pack_start (vp, false, true, 0);
            overlay.add (main_box);
            overlay.add_overlay (fullscreen_eventbox);
            this.add (this.overlay);

            // Show/Hide widgets
            show_all ();
            
            this.fullscreen_revealer.set_reveal_child (false);
            this.search_revealer.set_reveal_child (false);
            
            main_actions.get_action ("SaveFile").visible = !settings.autosave;
            main_actions.get_action ("Templates").visible = plugins.plugin_iface.template_manager.template_available;
            plugins.plugin_iface.template_manager.notify["template_available"].connect ( () => {
                main_actions.get_action ("Templates").visible = plugins.plugin_iface.template_manager.template_available;
            });

            // Show welcome by default
            this.split_view.show_welcome ();

            // Plugins hook
            HookFunc hook_func = () => {
                plugins.hook_window (this);
                plugins.hook_toolbar (this.toolbar);
                plugins.hook_main_menu (this.toolbar.menu);
                plugins.hook_share_menu (this.toolbar.share_menu);
                plugins.hook_notebook_sidebar (this.sidebar);
                plugins.hook_notebook_context (this.contextbar);
                plugins.hook_notebook_bottom (this.bottombar);
                this.split_view.document_change.connect ((doc) => {
                    plugins.hook_document (doc);
                });
                plugins.hook_split_view (this.split_view);
            };
            plugins.extension_added.connect (() => {
                hook_func ();
            });
            hook_func ();

        }

         private void on_plugin_toggled (Gtk.Notebook notebook) {
            var pages = notebook.get_n_pages ();
            notebook.set_show_tabs (pages > 1);
            notebook.no_show_all = (pages == 0);
            notebook.visible = (pages > 0);
        }

        protected override bool delete_event (Gdk.EventAny event) {
            handle_quit ();
            return !check_unsaved_changes ();
        }

        // Set sensitive property for 'delicate' Widgets/GtkActions while
        private void set_widgets_sensitive (bool val) {
            // SearchManager's stuffs
            main_actions.get_action ("Fetch").sensitive = val;
            main_actions.get_action ("ShowGoTo").sensitive = val;
            main_actions.get_action ("ShowReplace").sensitive = val;
            main_actions.get_action ("ShowReplace").sensitive = val;
            if (val == false)
                this.search_revealer.set_reveal_child (false);
            // Toolbar Actions
            main_actions.get_action ("SaveFile").sensitive = val;
            main_actions.get_action ("Undo").sensitive = val;
            main_actions.get_action ("Redo").sensitive = val;
            main_actions.get_action ("Revert").sensitive = val;
            this.toolbar.share_app_menu.sensitive = val;
        }

        // Get current view
        public Scratch.Widgets.DocumentView? get_current_view () {
            Scratch.Widgets.DocumentView? view = null;

            view = split_view.get_current_view ();

            if (view == null && !split_view.is_empty ()) {
                view = (split_view.get_child1 () ?? split_view.get_child2 ()) as Scratch.Widgets.DocumentView;
            }

            return view;
        }

        // Get current document
        public Scratch.Services.Document? get_current_document () {
            var view = this.get_current_view ();
            return view.get_current_document ();
        }

        // Add new view
        public Scratch.Widgets.DocumentView? add_view () {
            return split_view.add_view ();
        }
        
        // Show LoadingView
        public void start_loading () {
            this.loading_view.start ();
            this.vp.visible = false;
            this.toolbar.sensitive = false;
        }
        
        // Hide LoadingView
        public void stop_loading () {
            this.loading_view.stop ();
            this.vp.visible = true;
            this.toolbar.sensitive = true;
            // Load the content of the shown document
            var doc = this.get_current_document ();
            doc.load_content ();
        }
        
        // Open a document
        public void open_document (Scratch.Services.Document doc) {
            while (Gtk.events_pending ()) {
                Gtk.main_iteration ();
            }
            
            Scratch.Widgets.DocumentView? view = null;
            if (this.split_view.is_empty ()) {
                view = split_view.add_view ();
                view.open_document (doc);
            }
            else {
                view = split_view.get_focus_child () as Scratch.Widgets.DocumentView;
                if (view == null)
                    view = this.split_view.current_view;
                view.open_document (doc);
            }
        }
        
        // Close a document
        public void close_document (Scratch.Services.Document doc) {
            Scratch.Widgets.DocumentView? view = null;
            if (this.split_view.is_empty ()) {
                view = split_view.add_view ();
                view.close_document (doc);
            }
            else {
                view = split_view.get_focus_child () as Scratch.Widgets.DocumentView;
                if (view == null)
                    view = this.split_view.current_view;
                view.close_document (doc);
            }
        }

        // Return true if there are no documents
        public bool is_empty () {
            return split_view.is_empty ();
        }

        // Check if there no unsaved changes
        private bool check_unsaved_changes () {
            if (!is_empty ()) {
                foreach (var w in this.split_view.views) {
                    var view = w as Scratch.Widgets.DocumentView;
                    foreach (var doc in view.docs) {
                        if (!doc.close ()) {
                            view.set_current_document (doc);
                            return false;
                        }
                    }
                }
            }
            return true;
        }

        // Save windows size and state
        private void restore_saved_state () {
            default_width = Scratch.saved_state.window_width;
            default_height = Scratch.saved_state.window_height;
            
            if (Scratch.saved_state.window_state == ScratchWindowState.MAXIMIZED)
                maximize ();
            else if (Scratch.saved_state.window_state == ScratchWindowState.FULLSCREEN)
                fullscreen ();
            else
                this.move (Scratch.saved_state.window_x, Scratch.saved_state.window_y);
        }
        
        // Save session informations different from window state
        private void restore_saved_state_extra () {
            // Plugin panes size
            hp1.set_position (Scratch.saved_state.hp1_size);
            hp2.set_position (Scratch.saved_state.hp2_size);
            vp.set_position (Scratch.saved_state.vp_size);
            
            if ((get_window ().get_state () & WindowState.FULLSCREEN) != 0) {
                prepare_fullscreen_toolbar ();
                this.fullscreen_eventbox.show ();
            }
        }

        private void update_saved_state () {

            // Save window state
            if ((get_window ().get_state () & WindowState.MAXIMIZED) != 0)
                Scratch.saved_state.window_state = ScratchWindowState.MAXIMIZED;
            else if ((get_window ().get_state () & WindowState.FULLSCREEN) != 0)
                Scratch.saved_state.window_state = ScratchWindowState.FULLSCREEN;
            else
                Scratch.saved_state.window_state = ScratchWindowState.NORMAL;

            // Save window size
            if (Scratch.saved_state.window_state == ScratchWindowState.NORMAL) {
                int width, height;
                get_size (out width, out height);
                Scratch.saved_state.window_width = width;
                Scratch.saved_state.window_height = height;
            }
            
            // Save window position
            int x, y;
            this.get_position (out x, out y);
            Scratch.saved_state.window_x = x;
            Scratch.saved_state.window_y = y;
            
            // Plugin panes size
            Scratch.saved_state.hp1_size = hp1.get_position ();
            Scratch.saved_state.hp2_size = hp2.get_position ();
            Scratch.saved_state.vp_size = vp.get_position ();
        }
        
        //move this.toolbar from fullscrean revaler to the windows titlebar
        void prepare_toolbar () {
            this.fullscreen_revealer.remove (this.toolbar);
            this.toolbar.set_show_close_button (true);
            this.set_titlebar (this.toolbar);
        }
        
        //move this.toolbar from windows titlebar to the fullscreen revealer
        void prepare_fullscreen_toolbar () {
            this.toolbar.set_show_close_button (false);
            this.set_titlebar (fullscreen_toolbar);
            this.fullscreen_revealer.add (this.toolbar);
        }

        // Update files-opened settings key
        void update_opened_files () {
            // File list
            var docs = new GLib.List<Scratch.Services.Document> ();
            this.split_view.views.foreach ((view) => {
                docs.concat (view.docs.copy ());
            });

            string[] opened_files = { "" };//new string[docs.length ()];
            docs.foreach ((doc) => {
                if (doc.file != null && doc.exists ())
                    opened_files += doc.file.get_uri ();
            });

            // Update the opened-files setting
            if (settings.show_at_start == "last-tabs")
               settings.schema.set_strv ("opened-files", opened_files);
        }

        // SIGTERM/SIGINT Handling
        public bool quit_source_func () {
            action_quit ();
            return false;
        }

        // For exit cleanup
        void handle_quit () {
            update_saved_state ();
            update_opened_files ();
        }

        // Actions functions
        void action_preferences () {
            var dialog = new Scratch.Dialogs.Preferences (plugins);
            dialog.show_all ();
        }

        void action_close_tab () {

        }

        void action_quit () {
            handle_quit ();
            check_unsaved_changes ();
            destroy ();
        }

        void action_restore_tab () {

        }

        void action_open () {
            // Show a GtkFileChooserDialog
            var filech = Utils.new_file_chooser_dialog (FileChooserAction.OPEN, _("Open some files"), this, true);

            if (filech.run () == ResponseType.ACCEPT) {
                foreach (string uri in filech.get_uris ()) {
                    // Update last visited path
                    Utils.last_path = Path.get_dirname (uri);
                    // Open the file
                    var file = File.new_for_uri (uri);
                    var doc = new Scratch.Services.Document (main_actions, file);
                    this.open_document (doc);
                }
            }

            filech.close ();
        }

        void action_save () {
            this.get_current_document ().save ();
        }

        void action_undo () {
            this.get_current_document ().undo ();
        }
        void action_redo () {
            this.get_current_document ().redo ();
        }

        void action_revert () {
            this.get_current_document ().revert ();
        }

        void action_duplicate () {
            this.get_current_document ().duplicate_selection ();
        }

        void action_new_tab () {
            Scratch.Widgets.DocumentView? view = null;
            if (this.split_view.is_empty ()) {
                view = split_view.add_view ();
                view.new_document ();
            }
            else {
                view = split_view.get_focus_child () as Scratch.Widgets.DocumentView;
                view.new_document ();
            }
        }

        void action_new_view () {
            var view = split_view.add_view ();
            if (view != null)
                view.new_document ();
        }

        void action_remove_view () {
            split_view.remove_view ();
        }

        void action_fullscreen () {
            if ((get_window ().get_state () & WindowState.FULLSCREEN) != 0) {
                this.fullscreen_eventbox.hide ();
                prepare_toolbar ();
                this.unfullscreen ();
            }
            else {
                prepare_fullscreen_toolbar ();
                this.fullscreen_eventbox.show ();
                this.fullscreen ();
            }
        }

        void action_fetch () {
            if (toggle_searchbar ()) {
                var selected_text = this.get_current_document ().get_selected_text ();
                if (selected_text != "")
                    this.search_manager.search_entry.text = selected_text;
                this.search_manager.search_entry.grab_focus ();
            }
        }

        void action_go_to () {
            if (toggle_searchbar ()) {
                this.search_manager.go_to_entry.grab_focus ();
            }
        }

        bool toggle_searchbar () {
            if (!this.search_revealer.get_child_revealed () ||
                this.search_manager.search_entry.has_focus ||
                this.search_manager.replace_entry.has_focus ||
                this.search_manager.go_to_entry.has_focus) {

                this.search_revealer.set_reveal_child (!this.search_revealer.get_child_revealed ());
                this.search_manager.highlight_none ();
                this.toolbar.find_button.set_tooltip_text (
                    (this.search_revealer.get_child_revealed ())
                    ? _("Hide search bar")
                    : main_actions.get_action ("Fetch").tooltip);
            }
            return this.search_revealer.get_reveal_child ();
        }

        void action_templates () {
            plugins.plugin_iface.template_manager.show_window (this);
        }
        
        void action_next_tab () {
            Scratch.Widgets.DocumentView? view = null;
            view = split_view.get_focus_child () as Scratch.Widgets.DocumentView;
            view.next_document ();
        }
        
        void action_previous_tab () {
            Scratch.Widgets.DocumentView? view = null;
            view = split_view.get_focus_child () as Scratch.Widgets.DocumentView;
            view.previous_document ();
        }
        
        void action_to_lower_case () {
            Scratch.Widgets.DocumentView? view = null;
            view = split_view.get_focus_child () as Scratch.Widgets.DocumentView;
            var doc = view.get_current_document ();
            if (doc == null) return;
            var source_view = doc.source_view;
            
            TextIter start, end;
            source_view.buffer.get_selection_bounds (out start, out end);
            string selected = source_view.buffer.get_text (start, end, true);

            source_view.buffer.delete (ref start, ref end);
            source_view.buffer.insert (ref start, selected.down (), -1);
        }
        
        void action_to_upper_case () {
            Scratch.Widgets.DocumentView? view = null;
            view = split_view.get_focus_child () as Scratch.Widgets.DocumentView;
            var doc = view.get_current_document ();
            if (doc == null) return;
            var source_view = doc.source_view;
            
            TextIter start, end;
            source_view.buffer.get_selection_bounds (out start, out end);
            string selected = source_view.buffer.get_text (start, end, true);

            source_view.buffer.delete (ref start, ref end);
            source_view.buffer.insert (ref start, selected.up (), -1);
        }

        // Actions array
        static const Gtk.ActionEntry[] main_entries = {
            { "Fetch", Gtk.Stock.FIND,
          /* label, accelerator */       N_("Find…"), "<Control>f",
          /* tooltip */                  N_("Find…"),
                                         action_fetch },
           { "ShowGoTo", Gtk.Stock.OK,
          /* label, accelerator */       N_("Go to line…"), "<Control>i",
          /* tooltip */                  N_("Go to line…"),
                                         action_go_to },
           { "Quit", Gtk.Stock.QUIT,
          /* label, accelerator */       N_("Quit"), "<Control>q",
          /* tooltip */                  N_("Quit"),
                                         action_quit },
           { "CloseTab", Gtk.Stock.CLOSE,
          /* label, accelerator */       N_("Close"), "<Control>w",
          /* tooltip */                  N_("Close"),
                                         action_close_tab },
           { "ShowReplace", Gtk.Stock.OK,
          /* label, accelerator */       N_("Replace"), "<Control>r",
          /* tooltip */                  N_("Replace"),
                                         action_fetch },
           { "RestoreTab", null,
          /* label, accelerator */       N_("Reopen closed document"), "<Control><Shift>t",
          /* tooltip */                  N_("Open last closed document in a new tab"),
                                         action_restore_tab },
           { "NewTab", Gtk.Stock.NEW,
          /* label, accelerator */       N_("Add New Tab"), "<Control>n",
          /* tooltip */                  N_("Add a new tab"),
                                         action_new_tab },
           { "NewView", Gtk.Stock.NEW,
          /* label, accelerator */       N_("Add New View"), "F3",
          /* tooltip */                  N_("Add a new view"),
                                         action_new_view },
           { "RemoveView", Gtk.Stock.CLOSE,
          /* label, accelerator */       N_("Remove Current View"), null,
          /* tooltip */                  N_("Remove this view"),
                                         action_remove_view },
           { "Undo", Gtk.Stock.UNDO,
          /* label, accelerator */       N_("Undo"), "<Control>z",
          /* tooltip */                  N_("Undo the last action"),
                                         action_undo },
           { "Redo", Gtk.Stock.REDO,
          /* label, accelerator */       N_("Redo"), "<Control><shift>z",
          /* tooltip */                  N_("Redo the last undone action"),
                                         action_redo },
          { "Revert", Gtk.Stock.REVERT_TO_SAVED,
          /* label, accelerator */       N_("Revert"), "<Control><shift>o",
          /* tooltip */                  N_("Restore this file"),
                                         action_revert },
           { "Duplicate", null,
          /* label, accelerator */       N_("Duplicate selected strings"), "<Control>d",
          /* tooltip */                  N_("Duplicate selected strings"),
                                         action_duplicate },
           { "Open", Gtk.Stock.OPEN,
          /* label, accelerator */       N_("Open"), "<Control>o",
          /* tooltip */                  N_("Open a file"),
                                         action_open },
           { "SaveFile", Gtk.Stock.SAVE,
          /* label, accelerator */       N_("Save"), "<Control>s",
          /* tooltip */                  N_("Save the current file"),
                                         action_save },
           { "Templates", "text-x-generic-template",
          /* label, accelerator */       N_("Templates"), null,
          /* tooltip */                  N_("Project templates"),
                                         action_templates },
           { "Preferences", Gtk.Stock.PREFERENCES,
          /* label, accelerator */       N_("Preferences"), null,
          /* tooltip */                  N_("Change Scratch settings"),
                                         action_preferences },
           { "NextTab", "next-tab",
          /* label, accelerator */       N_("Next Tab"), "<Control><Alt>Page_Up",
          /* tooltip */                  N_("Next Tab"),
                                         action_next_tab },
           { "PreviousTab", "previous-tab",
          /* label, accelerator */       N_("Previous Tab"), "<Control><Alt>Page_Down",
          /* tooltip */                  N_("Previous Tab"),
                                         action_previous_tab },
                                         
           { "ToLowerCase", null,
          /* label, accelerator */       null, "<Control>l",
          /* tooltip */                  null,
                                         action_to_lower_case },
                                         
            { "ToUpperCase", null,
          /* label, accelerator */       null, "<Control>u",
          /* tooltip */                  null,
                                         action_to_upper_case }                           
        };

         static const Gtk.ToggleActionEntry[] toggle_entries = {
           { "Fullscreen", Gtk.Stock.FULLSCREEN,
          /* label, accelerator */       N_("Fullscreen"), "F11",
          /* tooltip */                  N_("Fullscreen"),
                                         action_fullscreen }
        };
    }
}
