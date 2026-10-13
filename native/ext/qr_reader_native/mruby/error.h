/* shim/mruby/error.h - see shim/mruby.h */
#ifndef SP_RE_SHIM_MRUBY_ERROR_H
#define SP_RE_SHIM_MRUBY_ERROR_H
#include "../mruby.h"

struct RClass;
struct RClass *mrb_exc_get_id(mrb_state *mrb, mrb_sym name);
mrb_value mrb_exc_new_str(mrb_state *mrb, struct RClass *c, mrb_value str);
/* the one exception the engine raises is a RegexpError, and it hands the
   message to spinel's handler (sp_re_set_error_handler), which does not
   return */
__attribute__((noreturn)) void mrb_exc_raise(mrb_state *mrb, mrb_value exc);
#endif
