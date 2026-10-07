/* gtkbtn: GTK 2 button/dialog event probe for xtiny. Logs, per action-area
 * button, the GDK crossing/press/release events and the GtkButton and
 * GtkDialog signals, to stderr. */
#include <gtk/gtk.h>
#include <stdio.h>

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

int main(int argc, char **argv) {
  gtk_init(&argc, &argv);
  /* like Sylpheed's setup wizard: a modal dialog over a main window */
  GtkWidget *main_win = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(main_win), "gtkbtn main");
  gtk_window_set_default_size(GTK_WINDOW(main_win), 500, 350);
  gtk_widget_show_all(main_win);
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
