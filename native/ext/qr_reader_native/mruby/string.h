/* shim/mruby/string.h - see shim/mruby.h */
#ifndef SP_RE_SHIM_MRUBY_STRING_H
#define SP_RE_SHIM_MRUBY_STRING_H
#include "../mruby.h"

struct sp_re_str {
  char *ptr;
  mrb_int len;
  mrb_int capa;
  struct sp_re_str *next;   /* the compile's list of strings to release */
};
#define RSTRING_PTR(s) ((s)->ptr)
#define RSTRING_LEN(s) ((s)->len)

mrb_value mrb_str_new(mrb_state *mrb, const char *p, size_t len);
mrb_value mrb_str_new_cstr(mrb_state *mrb, const char *p);
mrb_value mrb_str_cat(mrb_state *mrb, mrb_value str, const char *p, size_t len);
mrb_value mrb_str_resize(mrb_state *mrb, mrb_value str, mrb_int len);
/* mruby's format: %l takes a pointer and a size_t length, %v a String, %c a
   char; the engine uses no other directive */
mrb_value mrb_format(mrb_state *mrb, const char *fmt, ...);
#endif
