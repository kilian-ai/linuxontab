#!/usr/bin/env python3
# glib 2.56.x: route arity-changing function-pointer casts through typed
# thunks — wasm call_indirect traps on signature mismatch (mc port, 2026-08).
# Run from the extracted glib source root.
import sys

THUNKS = '''
/* wasm: call_indirect traps on signature mismatch; thunks carry the real
 * callback through user_data so every indirect call is exactly typed. */
static void
g__wasm_destroy_thunk (gpointer data, gpointer user_data)
{
  ((GDestroyNotify) user_data) (data);
}
static gint
g__wasm_compare_thunk (gconstpointer a, gconstpointer b, gpointer user_data)
{
  return ((GCompareFunc) user_data) (a, b);
}
'''
CMPDATA = '''
/* wasm: 3-arg thunk for 2-arg comparators used as GCompareDataFunc */
static gint
g__wasm_compare_data_thunk (gconstpointer a, gconstpointer b, gpointer user_data)
{
  return ((GCompareFunc) user_data) (a, b);
}
'''

def patch(path, subs, prelude=None, anchor=None):
    s = open(path).read()
    if prelude and prelude.strip().splitlines()[1] not in s:
        assert anchor in s, f"anchor missing in {path}"
        s = s.replace(anchor, anchor + prelude, 1)
    for old, new in subs:
        assert old in s, f"NOT FOUND in {path}: {old}"
        s = s.replace(old, new)
    open(path, 'w').write(s)
    print("patched", path)

patch('glib/glist.c', [
    ('  g_list_foreach (list, (GFunc) free_func, NULL);',
     '  g_list_foreach (list, g__wasm_destroy_thunk, (gpointer) free_func);'),
    ('  return g_list_insert_sorted_real (list, data, (GFunc) func, NULL);',
     '  return g_list_insert_sorted_real (list, data, (GFunc) g__wasm_compare_thunk, (gpointer) func);'),
    ('  return g_list_sort_real (list, (GFunc) compare_func, NULL);',
     '  return g_list_sort_real (list, (GFunc) g__wasm_compare_thunk, (gpointer) compare_func);'),
], THUNKS, '#include "gtestutils.h"')

patch('glib/gslist.c', [
    ('  g_slist_foreach (list, (GFunc) free_func, NULL);',
     '  g_slist_foreach (list, g__wasm_destroy_thunk, (gpointer) free_func);'),
    ('  return g_slist_insert_sorted_real (list, data, (GFunc) func, NULL);',
     '  return g_slist_insert_sorted_real (list, data, (GFunc) g__wasm_compare_thunk, (gpointer) func);'),
    ('  return g_slist_sort_real (list, (GFunc) compare_func, NULL);',
     '  return g_slist_sort_real (list, (GFunc) g__wasm_compare_thunk, (gpointer) compare_func);'),
], THUNKS, '#include "gtestutils.h"')

patch('glib/garray.c', [
    ('        g_ptr_array_foreach (array, (GFunc) rarray->element_free_func, NULL);',
     '        g_ptr_array_foreach (array, g__wasm_destroy_thunk, (gpointer) rarray->element_free_func);'),
], THUNKS, '#include "gmessages.h"')
s = open('glib/garray.c').read()
assert s.count('(GCompareDataFunc)compare_func,') == 2
s = s.replace('''(GCompareDataFunc)compare_func,
                     NULL)''', '''g__wasm_compare_data_thunk,
                     (gpointer) compare_func)''')
if 'g__wasm_compare_data_thunk' in s and CMPDATA.strip().splitlines()[1] not in s:
    s = s.replace('#include "gmessages.h"', '#include "gmessages.h"' + CMPDATA, 1)
open('glib/garray.c','w').write(s)

patch('glib/gasyncqueue.c', [
    ('        g_queue_foreach (&queue->queue, (GFunc) queue->item_free_func, NULL);',
     '        g_queue_foreach (&queue->queue, g__wasm_destroy_thunk, (gpointer) queue->item_free_func);'),
], THUNKS, '#include "gthread.h"')

patch('glib/gtree.c', [
    ('  return g_tree_new_full ((GCompareDataFunc) key_compare_func, NULL,\n                          NULL, NULL);',
     '  return g_tree_new_full (g__wasm_compare_data_thunk, (gpointer) key_compare_func,\n                          NULL, NULL);'),
], CMPDATA, '#include "gtestutils.h"')
print("glib wasm cast patches complete")
