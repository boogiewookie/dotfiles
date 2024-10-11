#!/usr/bin/env python3
import re
import psycopg2
import psycopg2.extensions
import webbrowser
import configparser, os
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk #, Gdk, GdkPixbuf, GLib
from urllib.parse import urlparse

def escape(s):
    return s.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')

def unescape(s):
    return s.replace('&lt;','<').replace('&gt;','>').replace('&amp;','&')

class TagURIt(Gtk.Window):
    def __init__(self):
        Gtk.Window.__init__(self, title="TagUrIt, the URI tagger")

        self.set_default_size(300, 400)

        self.visible_tagset = None
        '''A item is visible when its tags match all of these.'''

        self.regex = None
        '''A item is visible if title or url match this regex.'''

        self.visible_item_count = 0
        '''Count of visible items'''

        self.urlstore = Gtk.ListStore(int,str,str,str,str)
        self.filtered_urlstore = self.urlstore.filter_new()
        self.filtered_urlstore.set_visible_func(self.is_item_visible)

        self.known_tagset = set()
        '''Complete set of known tags.'''

        config = configparser.ConfigParser()
        config.read([os.path.expanduser('~/.tagurit.ini'), os.path.expanduser('~/.database.ini')])
        self.conn = psycopg2.connect(
                database='tagurit',
                host=config['tagurit']['host'],
                user=config['tagurit']['user'],
                password=config['tagurit']['password'])
        self.conn.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_AUTOCOMMIT)

        cur = self.conn.cursor()

        cur.execute("""SELECT iid,title,url,notes,tags FROM items ORDER BY title;""")
        for row in cur:
            iid,title,url,notes,tags = row
            #tooltips use pango markup so you must escape &, <, >, etc
            notes = escape(notes)
            # tags in database are surrounded by spaces for easy sql matching
            tags = tags.strip()
            self.urlstore.append((iid,title,url,notes,tags))
            self.known_tagset.update({x for x in tags.split()})

        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.add(vbox)

        # selected item id value
        self.iid = None

        # title entry line
        self.title_entry = Gtk.Entry()
        self.title_entry.set_icon_from_icon_name(Gtk.EntryIconPosition.SECONDARY,"edit-clear")
        self.title_entry.connect("icon_press",self.on_clear_icon_clicked)
        hbox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        hbox.pack_start(Gtk.Label.new("Title"), False, False, 0)
        hbox.pack_start(self.title_entry, True, True, 0)
        vbox.pack_start(hbox, False, False, 0)

        # url entry line
        self.url_entry = Gtk.Entry()
        self.url_entry.set_icon_from_icon_name(Gtk.EntryIconPosition.SECONDARY,"edit-clear")
        self.url_entry.connect("icon_press",self.on_clear_icon_clicked)
        self.url_entry.connect("changed",self.on_url_changed)
        self.url_entry.connect("paste-clipboard",self.on_url_changed)
        hbox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        hbox.pack_start(Gtk.Label.new("URL"), False, False, 0)
        hbox.pack_start(self.url_entry, True, True, 0)
        button = Gtk.Button.new_with_label("Go")
        button.connect("clicked",self.on_go_clicked)
        hbox.pack_start(button, False, False, 0)
        vbox.pack_start(hbox, False, False, 0)

        # notes entry line
        self.notes_entry = Gtk.Entry()
        self.notes_entry.set_icon_from_icon_name(Gtk.EntryIconPosition.SECONDARY,"edit-clear")
        self.notes_entry.connect("icon_press",self.on_clear_icon_clicked)
        hbox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        hbox.pack_start(Gtk.Label.new("Notes"), False, False, 0)
        hbox.pack_start(self.notes_entry, True, True, 0)
        vbox.pack_start(hbox, False, False, 0)

        # tags entry line
        self.tags_entry = Gtk.Entry()
        self.tags_entry.set_icon_from_icon_name(Gtk.EntryIconPosition.SECONDARY,"edit-clear")
        self.tags_entry.connect("icon_press",self.on_clear_icon_clicked)
        hbox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        button = Gtk.Button.new_with_label("Tags")
        button.connect("clicked",self.on_tags_clicked)
        hbox.pack_start(button, False, False, 0)
        hbox.pack_start(self.tags_entry, True, True, 0)
        vbox.pack_start(hbox, False, False, 0)

        # buttons 
        hbox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        button = Gtk.Button.new_with_label("Sync")
        button.connect("clicked",self.on_sync_clicked)
        hbox.pack_start(button, True, True, 0)
        button = Gtk.Button.new_with_label("Clear")
        button.connect("clicked",self.on_clear_clicked)
        hbox.pack_start(button, True, True, 0)
        button = Gtk.Button.new_with_label("Delete")
        button.connect("clicked",self.on_delete_clicked)
        hbox.pack_start(button, True, True, 0)
        vbox.pack_start(hbox, False, False, 0)

        # seperator
        vbox.pack_start(Gtk.HSeparator(), False, False, 0)

        # urls tree
        self.item_tree = Gtk.TreeView.new_with_model(self.filtered_urlstore)
        self.item_tree.append_column(
                Gtk.TreeViewColumn("Title", Gtk.CellRendererText(), text=1))
        self.item_tree.set_tooltip_column(3)
        select = self.item_tree.get_selection()
        select.connect("changed",self.on_selection_changed)
        sw = Gtk.ScrolledWindow.new(None,None)
        sw.add(self.item_tree) 
        sw.set_min_content_height(200)
        vbox.pack_start(sw, True, True, 0)

        # filter label
        vbox.pack_start(Gtk.Label.new("Filter"), False, False, 0)

        # filter tags entry line
        self.filter_entry = Gtk.Entry()
        self.filter_entry.set_icon_from_icon_name(Gtk.EntryIconPosition.SECONDARY,"edit-clear")
        self.filter_entry.connect("icon_press",self.on_clear_filter_icon_clicked)
        self.filter_entry.connect("activate",self.on_filter_activate)
        hbox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        button = Gtk.Button.new_with_label("Tags")
        button.connect("clicked",self.on_filter_clicked)
        hbox.pack_start(button, False, False, 0)
        hbox.pack_start(self.filter_entry, True, True, 0)
        vbox.pack_start(hbox, False, False, 0)

        # pattern entry line
        self.regex_entry = Gtk.Entry()
        self.regex_entry.set_icon_from_icon_name(Gtk.EntryIconPosition.SECONDARY,"edit-clear")
        self.regex_entry.connect("icon_press",self.on_clear_filter_icon_clicked)
        self.regex_entry.connect("activate",self.on_regex_activate)
        hbox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        hbox.pack_start(Gtk.Label.new("Regex"), False, False, 0)
        hbox.pack_start(self.regex_entry, True, True, 0)
        vbox.pack_start(hbox, False, False, 0)

        # seperator
        vbox.pack_start(Gtk.HSeparator(), False, False, 0)

        # status line
        self.status = Gtk.Label.new("")
        vbox.pack_start(self.status, False, False, 3)

    def is_same_url(self,model,path,treeiter,url):
        '''Compare one urlstore row's url to url.'''
        if model[treeiter][2] == url or model[treeiter][2].strip('/') == url or model[treeiter][2] == url.strip('/'):
            self.dup = True
        return self.dup

    def is_duplicate_url(self,url):
        '''Return True iff url is already in the urlstore.'''
        self.dup = False
        self.urlstore.foreach(self.is_same_url,url)
        return self.dup

    def set_status(self,msg):
        self.status.set_text(msg)

    def get_iid(self):
        return self.iid

    def set_iid(self,iid):
        self.iid = iid

    def get_title(self):
        return self.title_entry.get_text().strip()

    def set_title(self,title):
        title = title.strip()
        self.title_entry.set_text(title)

    def get_url(self):
        return self.url_entry.get_text().strip()

    def set_url(self,url):
        url = url.strip()
        self.url_entry.set_text(url)

    def get_notes(self):
        return self.notes_entry.get_text().strip()

    def set_notes(self,notes):
        notes = unescape(notes.strip())
        self.notes_entry.set_text(notes)

    def get_tags(self):
        return self.tags_entry.get_text().strip().lower()

    def set_tags(self,tags):
        tags = tags.strip().lower()
        self.tags_entry.set_text(tags)
        self.tags_entry.set_position(-1)

    def clear_data(self):
        self.set_iid(None)
        self.set_title("")
        self.set_url("")
        self.set_notes("")
        self.set_tags("")
        self.set_status("")

    #called when you click in the url tree
    def on_selection_changed(self,selection):
        model, treeiter = selection.get_selected()
        if treeiter != None:
            row = model[treeiter]
            self.set_iid(model[treeiter][0])
            self.set_title(model[treeiter][1])
            self.set_url(model[treeiter][2])
            self.set_notes(model[treeiter][3])
            self.set_tags(model[treeiter][4])

    def on_clear_icon_clicked(self,entry,pos,event):
        if pos == Gtk.EntryIconPosition.SECONDARY:
            entry.set_text("")

    def on_clear_filter_icon_clicked(self,entry,pos,event):
        if pos == Gtk.EntryIconPosition.SECONDARY:
            entry.set_text("")
        self.refilter_items()

    def on_go_clicked(self,button):
        webbrowser.open_new(self.url_entry.get_text())

    def on_sync_clicked(self,button):
        iid = self.get_iid()
        title = self.get_title()
        url = self.get_url().rstrip('/')
        notes = self.get_notes()
        tags = self.get_tags()
        tags = self.fix_plural_tags(tags)
        self.known_tagset.update(tags.split())  #in case we entered any novel tags
        # tags in database are surrounded by spaces for easy sql matching
        tags = ' ' + self.fix_plural_tags(tags) + ' '
        if not title or not url:
            self.set_status("Both Title and URL must be set")
            return
        print((iid,title,url,notes,tags))   #FIXME: debug
        cur = self.conn.cursor()
        if iid: # it already exists in the database
            sel = self.item_tree.get_selection()
            model, treeiter = sel.get_selected()
            assert model and treeiter
            model.set_value(treeiter,1,title)
            model.set_value(treeiter,2,url)
            #tooltips use pango markup so you must escape &, <, >, etc(?)
            model.set_value(treeiter,3,escape(notes))
            model.set_value(treeiter,4,tags)
            cur.execute(
                    """UPDATE items
                       SET title = %s,url = %s,notes = %s,tags = %s
                       WHERE iid = %s;""",
                    (title,url,notes,tags,iid))
            sel.unselect_all()
        else:
            if self.is_duplicate_url(url):
                self.set_status("That url is already stored")
                return
            else:
                # tags in database are surrounded by spaces for easy sql matching
                cur.execute(
                        """INSERT INTO items (title,url,notes,tags) VALUES
                        (%s,%s,%s,%s) RETURNING iid,title,url,notes,tags;""",
                        (title,url,notes,tags))
                self.urlstore.append(cur.fetchone())
        self.clear_data()

    def on_tags_clicked(self,button):
        tags = self.fix_plural_tags(self.get_tags())
        dialog = TagsDialog(self, self.known_tagset, tags)
        response = dialog.run()
        if response == Gtk.ResponseType.OK:
            self.tags_entry.set_text(dialog.get_tags())
            self.known_tagset.update(dialog.get_newtag_set())
        dialog.destroy()

    def on_clear_clicked(self,button):
        self.selected_url = None
        self.clear_data()
        self.item_tree.get_selection().unselect_all()

    def on_delete_clicked(self,button):
        sel = self.item_tree.get_selection()
        model, treeiter = sel.get_selected()
        if model and treeiter:
            dialog = Gtk.MessageDialog(
                    parent=self,
                    flags=Gtk.DialogFlags.MODAL,
                    type=Gtk.MessageType.QUESTION,
                    buttons=Gtk.ButtonsType.YES_NO,
                    message_format="Do you really want to delete '{}'?".format(model[treeiter][1]))
            response = dialog.run()
            if response == Gtk.ResponseType.YES:
                self.clear_data()
                treeiter = model.convert_iter_to_child_iter(treeiter)
                model = model.get_model()
                iid = model[treeiter][0]
                cur = self.conn.cursor()
                cur.execute("""DELETE FROM items WHERE iid = %s;""",(iid,))
                model.remove(treeiter)
            dialog.destroy()
        else:
            self.set_status("Select an item first")

    def on_filter_clicked(self,button):
        dialog = TagsDialog(self, self.known_tagset,
                self.filter_entry.get_text().strip())
        response = dialog.run()
        if response == Gtk.ResponseType.OK:
            self.filter_entry.set_text(dialog.get_tags())
            self.refilter_items()
            self.known_tagset.update(dialog.get_newtag_set())
        dialog.destroy()

    def on_filter_activate(self,entry):
        self.refilter_items()

    def on_url_changed(self,entry):
        if self.get_title() == '':
            title = urlparse(entry.get_text()).netloc
            if title.startswith("www."):
                title = title[4:]
            if title.endswith(".com") or title.endswith(".org"):
                title = title[:-4]
            self.set_title(title)

    def on_regex_activate(self,entry):
        self.refilter_items()

    def refilter_items(self):
        self.visible_tagset = {x for x in self.filter_entry.get_text().split()}
        pattern = self.regex_entry.get_text()
        if pattern:
            self.regex = re.compile(pattern,flags=re.IGNORECASE)
        else:
            self.regex = None
        self.filtered_urlstore.refilter()   #see Gtk.TreeModelFilter
        self.set_status("{0} items after applying filters".format(self.count_visible_items()))

    def is_item_visible(self,model,treeiter,data):
        iid,title,url,notes,tags = model[treeiter]
        if self.visible_tagset:
            url_tagset = {x for x in tags.split()}
            if not self.visible_tagset <= url_tagset:
                return False
        if self.regex:
            if not self.regex.search(title) \
                    and not self.regex.search(url) \
                    and not self.regex.search(notes) :
                return False
        return True

    def bump_visible_item_count(self,model,path,treeiter):
        if self.is_item_visible(model,treeiter,None):
            self.visible_item_count += 1

    def count_visible_items(self):
        self.visible_item_count = 0
        self.urlstore.foreach(self.bump_visible_item_count)
        return self.visible_item_count

    def fix_plural_tags(self,tags):
        '''replace "new" tags that differ only by a trailing 's' with the existing tag'''
        tagset = set(tags.split())
        for tag in tagset.difference(self.known_tagset):
            if tag.endswith('s') and tag[0:-1] in self.known_tagset:
                print("converting {0} to {1}".format(tag,tag[0:-1]))
                tagset.remove(tag)
                tagset.add(tag[0:-1])
            elif (tag + 's') in self.known_tagset:
                print("converting {0} to {1}".format(tag,tag+'s'))
                tagset.remove(tag)
                tagset.add(tag+'s')
        return ' '.join(tagset)

class TagsDialog(Gtk.Dialog):
    '''Dialog to select a group of tags from tagset.'''

    def __init__(self, parent, tagset, tags):
        Gtk.Dialog.__init__(self, "Tags", parent, 0,
                (Gtk.STOCK_CANCEL,
                Gtk.ResponseType.CANCEL,
                Gtk.STOCK_OK,
                Gtk.ResponseType.OK))

        pretagged = {x for x in tags.split()}
        self.newtagset = pretagged.difference(tagset)   #in case we typed any novel tags

        linelen = 0
        self.tag_buttons = list()
        #FIXME: I'd rather this use a FlowBox, but it's missing from my PythonGI
        vbox = Gtk.VBox()
        hbox = Gtk.HBox()
        self.get_content_area().add(vbox)
        for tag in sorted(tagset.union(self.newtagset)):
            button = Gtk.CheckButton(tag)
            if tag in pretagged:
                button.set_active(True)
            if tag in self.newtagset:
                button.get_child().set_markup(
                        """<span color='red'>{0}</span>""".format(escape(tag)))
            self.tag_buttons.append(button)
            linelen += len(tag)+3
            if linelen > 64:
                vbox.pack_start(hbox, False, False, 0)
                hbox = Gtk.HBox()
                linelen = len(tag)+3
            hbox.pack_start(button, False, False, 6)
        vbox.pack_start(hbox, False, False, 0)

        button = Gtk.Button.new_with_label("Clear")
        button.connect("clicked",self.on_clear_clicked)
        vbox.pack_start(button, False, False, 0)

        self.show_all()

    def on_clear_clicked(self,button):
        for button in self.tag_buttons:
            button.set_active(False)

    def get_tags(self):
        tags = list()
        for button in self.tag_buttons:
            if button.get_active():
                tags.append(button.get_label())
        return " ".join(tags)

    def get_newtag_set(self):
        return self.newtagset



win = TagURIt()
win.connect("delete-event", Gtk.main_quit)
win.show_all()
Gtk.main()
