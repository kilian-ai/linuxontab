/* gtkbtn: GTK 2 button/dialog event probe for xtiny. Logs, per action-area
 * button, the GDK crossing/press/release events and the GtkButton and
 * GtkDialog signals, to stderr. */
#include <gtk/gtk.h>
#include <stdio.h>
#include <stdlib.h>

static gboolean on_ev(GtkWidget *w, GdkEvent *e, gpointer name) {
  const char *t = "?";
  switch (e->type) {
  case GDK_ENTER_NOTIFY: t = "enter"; break;
  case GDK_LEAVE_NOTIFY: t = "leave"; break;
  case GDK_BUTTON_PRESS: t = "press"; break;
  case GDK_2BUTTON_PRESS: t = "2press"; break;
  case GDK_BUTTON_RELEASE: t = "release"; break;
  default: return FALSE;
  }
  if (e->type == GDK_ENTER_NOTIFY || e->type == GDK_LEAVE_NOTIFY)
    fprintf(stderr, "[gtkbtn] %s %s detail %d mode %d at %.0f,%.0f time %u\n", (char *)name, t,
            e->crossing.detail, e->crossing.mode, e->crossing.x, e->crossing.y, e->crossing.time);
  else
    fprintf(stderr, "[gtkbtn] %s %s button %u at %.0f,%.0f time %u in_button %d down %d\n", (char *)name, t,
            e->button.button, e->button.x, e->button.y, e->button.time,
            GTK_BUTTON(w)->in_button, GTK_BUTTON(w)->button_down);
  return FALSE;
}
static void on_sig(GtkWidget *w, gpointer name) {
  fprintf(stderr, "[gtkbtn] %s signal (in_button %d)\n", (char *)name, GTK_BUTTON(w)->in_button);
}
static void on_response(GtkDialog *d, gint id, gpointer data) {
  (void)d; (void)data;
  fprintf(stderr, "[gtkbtn] dialog response %d\n", id);
}
static void watch(GtkWidget *b, const char *name) {
  g_signal_connect(b, "enter-notify-event", G_CALLBACK(on_ev), (gpointer)name);
  g_signal_connect(b, "leave-notify-event", G_CALLBACK(on_ev), (gpointer)name);
  g_signal_connect(b, "button-press-event", G_CALLBACK(on_ev), (gpointer)name);
  g_signal_connect(b, "button-release-event", G_CALLBACK(on_ev), (gpointer)name);
  g_signal_connect(b, "pressed", G_CALLBACK(on_sig), "pressed");
  g_signal_connect(b, "released", G_CALLBACK(on_sig), "released");
  g_signal_connect(b, "clicked", G_CALLBACK(on_sig), "clicked");
}

static void on_item(GtkMenuItem *it, gpointer name) {
  (void)it;
  fprintf(stderr, "[gtkbtn] menu item %s activated\n", (char *)name);
}
static void on_menu_vis(GtkWidget *m, gpointer name) {
  GdkEvent *cur = gtk_get_current_event();
  fprintf(stderr, "[gtkbtn] menu %s %s (current event %d", (char *)name,
          GTK_WIDGET_VISIBLE(m) ? "shown" : "hidden", cur ? (int)cur->type : -1);
  if (cur && (cur->type == GDK_BUTTON_PRESS || cur->type == GDK_BUTTON_RELEASE))
    fprintf(stderr, " button at %.0f,%.0f time %u", cur->button.x, cur->button.y, cur->button.time);
  if (cur && (cur->type == GDK_ENTER_NOTIFY || cur->type == GDK_LEAVE_NOTIFY))
    fprintf(stderr, " crossing mode %d detail %d", cur->crossing.mode, cur->crossing.detail);
  fprintf(stderr, ")\n");
  if (cur) gdk_event_free(cur);
}
static gboolean on_grab_broken(GtkWidget *w, GdkEvent *e, gpointer name) {
  (void)w;
  fprintf(stderr, "[gtkbtn] grab-broken on %s (keyboard %d implicit %d)\n", (char *)name,
          e->grab_broken.keyboard, e->grab_broken.implicit);
  return FALSE;
}
static void on_deactivate(GtkMenuShell *ms, gpointer name) {
  (void)ms;
  GdkEvent *cur = gtk_get_current_event();
  fprintf(stderr, "[gtkbtn] %s deactivate (current event %d)\n", (char *)name, cur ? (int)cur->type : -1);
  if (cur) gdk_event_free(cur);
}
static GtkWidget *add_menu(GtkWidget *bar, const char *title, const char **items) {
  GtkWidget *top = gtk_menu_item_new_with_mnemonic(title);
  GtkWidget *menu = gtk_menu_new();
  for (; *items; items++) {
    GtkWidget *it = gtk_menu_item_new_with_label(*items);
    g_signal_connect(it, "activate", G_CALLBACK(on_item), (gpointer)*items);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), it);
  }
  g_signal_connect(menu, "show", G_CALLBACK(on_menu_vis), (gpointer)title);
  g_signal_connect(menu, "hide", G_CALLBACK(on_menu_vis), (gpointer)title);
  g_signal_connect(menu, "grab-broken-event", G_CALLBACK(on_grab_broken), (gpointer)title);
  gtk_menu_item_set_submenu(GTK_MENU_ITEM(top), menu);
  gtk_menu_shell_append(GTK_MENU_SHELL(bar), top);
  return top;
}

int main(int argc, char **argv) {
  gtk_init(&argc, &argv);
  /* like Sylpheed's setup wizard: a modal dialog over a main window */
  GtkWidget *main_win = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(main_win), "gtkbtn main");
  gtk_window_set_default_size(GTK_WINDOW(main_win), 500, 350);
  GtkWidget *vbox = gtk_vbox_new(FALSE, 0);
  GtkWidget *bar = gtk_menu_bar_new();
  static const char *file_items[] = { "Open", "Save", "Quit", NULL };
  static const char *edit_items[] = { "Cut", "Copy", "Paste", NULL };
  add_menu(bar, "_File", file_items);
  add_menu(bar, "_Edit", edit_items);
  g_signal_connect(bar, "deactivate", G_CALLBACK(on_deactivate), "menubar");
  g_signal_connect(bar, "grab-broken-event", G_CALLBACK(on_grab_broken), "menubar");
  gtk_box_pack_start(GTK_BOX(vbox), bar, FALSE, FALSE, 0);
  gtk_container_add(GTK_CONTAINER(main_win), vbox);
  gtk_widget_show_all(main_win);
  if (getenv("GTKBTN_NODIALOG")) { gtk_main(); return 0; }
  GtkWidget *d = gtk_dialog_new();
  gtk_window_set_modal(GTK_WINDOW(d), TRUE);
  gtk_window_set_transient_for(GTK_WINDOW(d), GTK_WINDOW(main_win));
  gtk_window_set_title(GTK_WINDOW(d), "gtkbtn");
  GtkWidget *l = gtk_label_new("Click the buttons; events go to stderr.");
  gtk_box_pack_start(GTK_BOX(GTK_DIALOG(d)->vbox), l, TRUE, TRUE, 20);
  GtkWidget *back = gtk_dialog_add_button(GTK_DIALOG(d), GTK_STOCK_GO_BACK, GTK_RESPONSE_REJECT);
  GtkWidget *fwd = gtk_dialog_add_button(GTK_DIALOG(d), GTK_STOCK_GO_FORWARD, GTK_RESPONSE_ACCEPT);
  GtkWidget *cancel = gtk_dialog_add_button(GTK_DIALOG(d), GTK_STOCK_CANCEL, GTK_RESPONSE_CANCEL);
  watch(back, "back"); watch(fwd, "forward"); watch(cancel, "cancel");
  g_signal_connect(d, "response", G_CALLBACK(on_response), NULL);
  g_signal_connect(d, "destroy", G_CALLBACK(gtk_main_quit), NULL);
  gtk_widget_set_size_request(d, 400, 200);
  gtk_widget_show_all(d);
  gtk_main();
  return 0;
}
