#!/usr/bin/env python3
# mc 4.8.33: same wasm call_indirect signature fixes as glib (see
# glib-2.56-wasm-call-indirect.py). Run from the extracted mc source root.
def patch(path, subs, prelude=None, anchor=None):
    s = open(path).read()
    if prelude and prelude.strip().splitlines()[1] not in s:
        assert anchor in s, f"anchor missing: {path}"
        s = s.replace(anchor, anchor + prelude, 1)
    for old, new in subs:
        assert old in s, f"NOT FOUND {path}: {old}"
        s = s.replace(old, new)
    open(path,'w').write(s)
    print("patched", path)

CMP3 = '''
/* wasm: indirect calls must match signatures exactly; 3-arg wrapper for the
 * 2-arg g_ascii_strcasecmp used as GCompareDataFunc. */
static gint
mc_wasm_strcasecmp_data (gconstpointer a, gconstpointer b, gpointer user_data)
{
    (void) user_data;
    return g_ascii_strcasecmp ((const gchar *) a, (const gchar *) b);
}
'''
for f in ('lib/event/event.c', 'lib/event/manage.c'):
    patch(f, [
        ('g_tree_new_full ((GCompareDataFunc) g_ascii_strcasecmp,',
         'g_tree_new_full (mc_wasm_strcasecmp_data,'),
    ], CMP3, '/*** file scope variables ************************************************************************/')

patch('lib/glibcompat.c', [
    ('        g_queue_foreach (queue, (GFunc) free_func, NULL);',
     '        g_queue_foreach (queue, mc_wasm_destroy_gfunc, (gpointer) free_func);'),
], '''
/* wasm: 2-arg GFunc wrapper carrying a 1-arg destroy through user_data */
static void
mc_wasm_destroy_gfunc (gpointer data, gpointer user_data)
{
    ((GDestroyNotify) user_data) (data);
}
''', '/*** file scope functions ************************************************************************/')

patch('lib/widget/group.c', [
    ('        g_list_foreach (g->widgets, (GFunc) widget_destroy, NULL);',
     '        g_list_foreach (g->widgets, group_wasm_widget_destroy_gfunc, NULL);'),
], '''
/* wasm: 2-arg GFunc wrapper for 1-arg widget_destroy */
static void
group_wasm_widget_destroy_gfunc (gpointer data, gpointer user_data)
{
    (void) user_data;
    widget_destroy (WIDGET (data));
}
''', '/*** file scope functions ************************************************************************/')
print("mc wasm cast patches complete")
