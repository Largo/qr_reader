/* shim/mruby/internal.h - see shim/mruby.h. The UTF-8 scan and the case
   declarations below are mruby's include/mruby/internal.h as it spells them. */
#ifndef SP_RE_SHIM_MRUBY_INTERNAL_H
#define SP_RE_SHIM_MRUBY_INTERNAL_H
#include "../mruby.h"

#define MRB_ENC_MULTIBYTE_P 1

/* a buffer that lives until the compile ends (re_spinel.c) */
void *mrb_temp_alloc(mrb_state *mrb, size_t size);

mrb_int mrb_utf8_to_buf(char *buf, mrb_int cp);

#define MRB_UTF8_MALFORMED (-1)
#define MRB_UTF8_TRUNCATED (-2)
#define MRB_UTF8_REDUNDANT (-3)
#define MRB_UTF8_EXCLUDED  (-4)
#define MRB_UTF8_LONG      (-5)

static inline mrb_int
mrb_utf8_scan(const char *p, const char *e, uint32_t *uv, const uint8_t bounds[][2])
{
  /* the byte length a lead byte claims, by its top five bits; the last entry
     folds 0xF8-0xFF together and they are told apart below. The table lives
     in the function, as the lookup tables of boxing_word.h do, so that a
     translation unit that never reads through the scan emits neither, at
     any optimization level. */
  static const uint8_t lead[32] = {
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 2, 3, 3, 4, 0
  };
  const unsigned char *q = (const unsigned char*)p;
  unsigned char c = q[0];
  mrb_int n = lead[c >> 3];

  if (n <= 1) {
    if (n == 1) {
      if (uv) *uv = c;
      return 1;
    }
    /* a continuation byte leads nothing; 0xF8-0xFD claim five or six,
       the lengths RFC 3629 withdrew, which a reader that wants them reads
       for itself */
    return (c < 0xF8 || c >= 0xFE) ? MRB_UTF8_MALFORMED : MRB_UTF8_LONG;
  }
  if (n > e - p) return MRB_UTF8_TRUNCATED;

  /* Each byte after the lead has to continue it. A second byte inside its
     bounds has, since the table admits nothing else, so only one outside
     them walks the sequence to tell a malformed one from a bounded one. The
     later checks nest in the order the bytes come, so a length costs the
     compares up to its own and none past it. Read as a signed char, a
     continuation byte is one below -0x40, a single compare where the mask
     takes three. A caller that wants the form alone passes no `uv`, and the
     value is dead code the compiler drops. */
  const uint8_t *b = bounds[c - 0xC0];
  if (q[1] < b[0] || q[1] > b[1]) {
    for (mrb_int i = 1; i < n; i++) {
      if ((signed char)q[i] >= -0x40) return MRB_UTF8_MALFORMED;
    }
    return q[1] < b[0] ? MRB_UTF8_REDUNDANT : MRB_UTF8_EXCLUDED;
  }
  uint32_t v = ((c & (0x7F >> n)) << 6) | (q[1] & 0x3F);
  if (n > 2) {
    if ((signed char)q[2] >= -0x40) return MRB_UTF8_MALFORMED;
    v = (v << 6) | (q[2] & 0x3F);
    if (n > 3) {
      if ((signed char)q[3] >= -0x40) return MRB_UTF8_MALFORMED;
      v = (v << 6) | (q[3] & 0x3F);
    }
  }
  if (uv) *uv = v;
  return n;
}

mrb_int mrb_utf8len(const char *str, const char *end);
const char *mrb_utf8_char_head(const char *beg, const char *p, const char *end);
uint32_t mrb_utf8_decode(const char *p, const char *e, mrb_int *lenp);

static inline mrb_int
mrb_enc_charlen(const char *p, const char *e)
{
  return mrb_utf8len(p, e);
}

static inline const char *
mrb_enc_char_head(const char *beg, const char *p, const char *end)
{
  return mrb_utf8_char_head(beg, p, end);
}

static inline uint32_t
mrb_enc_decode(const char *p, const char *e, mrb_int *lenp)
{
  return mrb_utf8_decode(p, e, lenp);
}

enum mrb_case_kind {
  MRB_CASE_KIND_LOWER,
  MRB_CASE_KIND_UPPER,
  MRB_CASE_KIND_TITLE,
  MRB_CASE_KIND_SWAP,
  MRB_CASE_KIND_FOLD
};

/* The buffer mrb_uni_case_map() writes into. A mapping may spell several
   characters, so this is wider than one of them; unicase.c asserts that the
   table it carries fits. */
#define MRB_UNI_CASE_MAX_BYTES 8

/* The `kind` mapping of `cp`, written into `buf` as UTF-8, answering how many
   bytes it took, or 0 for a character that maps to itself. */
mrb_int mrb_uni_case_map(enum mrb_case_kind kind, uint32_t cp, char *buf);

#ifdef HAVE_MRUBY_REGEXP_GEM
/* The four below are the foldings /i reads off the same table, in the two
   directions a pattern needs them. A build without mruby-regexp has nothing
   that reads them, so a caller reaching for one there is a compile error
   rather than a link one. */

/* Simple case folding: the folded codepoint, or cp itself when it folds to
   nothing else. A codepoint whose folding spells several characters (U+FB00
   to "ff") folds to itself here, which is what makes this the simple folding
   rather than the full one mrb_uni_case_map() answers with. */
uint32_t mrb_uni_case_fold(uint32_t cp);

/* At most this many codepoints share one folded form. */
#define MRB_UNI_MAX_UNFOLD 4

/* Write every other codepoint sharing cp's folded form into out, at most max
   of them, and answer how many were written. */
int mrb_uni_case_unfold(uint32_t cp, uint32_t *out, int max);

/* The same two directions over a span rather than one codepoint, reporting
   what they find by calling add() with each span of it: fold_range the folds
   of the sources in [lo, hi], unfold_range the sources of the folds in
   [lo, hi]. Spans may repeat or overlap what the caller already holds; the
   caller merges. */
void mrb_uni_case_fold_range(uint32_t lo, uint32_t hi,
                             void (*add)(void *, uint32_t, uint32_t), void *user);
void mrb_uni_case_unfold_range(uint32_t lo, uint32_t hi,
                               void (*add)(void *, uint32_t, uint32_t), void *user);
#endif  /* HAVE_MRUBY_REGEXP_GEM */

#endif /* SP_RE_SHIM_MRUBY_INTERNAL_H */
