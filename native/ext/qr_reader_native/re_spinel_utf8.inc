/* re_spinel_utf8.inc - mruby's src/string.c UTF-8 readers the engine calls, as
   mruby spells them (included by re_spinel.c) */
mrb_int
mrb_utf8_to_buf(char *buf, mrb_int cp)
{
  if (cp < 0) {
    return 0;
  }
  else if (cp < 0x80) {
    buf[0] = (char)cp;
    return 1;
  }
  else if (cp < 0x800) {
    buf[0] = (char)(0xC0 | (cp >> 6));
    buf[1] = (char)(0x80 | (cp & 0x3F));
    return 2;
  }
  else if (cp < 0x10000) {
    buf[0] = (char)(0xE0 | (cp >> 12));
    buf[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
    buf[2] = (char)(0x80 | (cp & 0x3F));
    return 3;
  }
  else if (cp <= 0x10FFFF) {
    buf[0] = (char)(0xF0 | (cp >> 18));
    buf[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    buf[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
    buf[3] = (char)(0x80 | (cp & 0x3F));
    return 4;
  }
  return 0;  /* above U+10FFFF */
}

#define utf8_islead(c) ((unsigned char)((c)&0xc0) != 0x80)

/* What a lead byte's second byte may be for the sequence to spell a
   character under RFC 3629 (Unicode D93b), one pair per lead byte from
   0xC0: the floor of each length (0xE0 A0, 0xF0 90; 0xC0 and 0xC1 have
   nothing to spell), the UTF-16 surrogates (0xED up to 9F), U+10FFFF
   (0xF4 up to 8F), and nothing at all for 0xF5 and above. This is the one
   view the scan keeps none of; unpack("U") in mruby-pack holds its own. */
#define R(lo, hi) {0x##lo, 0x##hi}
static const uint8_t utf8_rfc3629_bounds[64][2] = {
  R(C0,BF), R(C0,BF), R(80,BF), R(80,BF), R(80,BF), R(80,BF), R(80,BF), R(80,BF),  /* C0..C7 */
  R(80,BF), R(80,BF), R(80,BF), R(80,BF), R(80,BF), R(80,BF), R(80,BF), R(80,BF),  /* C8..CF */
  R(80,BF), R(80,BF), R(80,BF), R(80,BF), R(80,BF), R(80,BF), R(80,BF), R(80,BF),  /* D0..D7 */
  R(80,BF), R(80,BF), R(80,BF), R(80,BF), R(80,BF), R(80,BF), R(80,BF), R(80,BF),  /* D8..DF */
  R(A0,BF), R(80,BF), R(80,BF), R(80,BF), R(80,BF), R(80,BF), R(80,BF), R(80,BF),  /* E0..E7 */
  R(80,BF), R(80,BF), R(80,BF), R(80,BF), R(80,BF), R(80,9F), R(80,BF), R(80,BF),  /* E8..EF */
  R(90,BF), R(80,BF), R(80,BF), R(80,BF), R(80,8F), R(80,7F), R(80,7F), R(80,7F),  /* F0..F7 */
  R(80,7F), R(80,7F), R(80,7F), R(80,7F), R(80,7F), R(80,7F), R(80,7F), R(80,7F),  /* F8..FF */
};
#undef R

mrb_int
mrb_utf8len(const char* p, const char* e)
{
  mrb_int n = mrb_utf8_scan(p, e, NULL, utf8_rfc3629_bounds);
  return n < 0 ? 1 : n;
}

/* The byte the character covering `p` starts at, or `p` itself when `p` is
   already a character boundary. A continuation byte belongs to the character
   that reaches it; one that no lead byte reaches belongs to none and stands as
   a character of its own. Whether a lead byte reaches is mrb_utf8len()'s
   answer, so the boundaries found here are the ones the character count is
   taken over. Reading back three bytes covers it, since nothing longer than
   four bytes spells a character. */
const char*
mrb_utf8_char_head(const char *beg, const char *p, const char *end)
{
  if (p >= end || utf8_islead(p[0])) return p;
  for (mrb_int back = 1; back <= 3 && back <= p - beg; back++) {
    const char *lead = p - back;
    if (!utf8_islead(lead[0])) continue;  /* another continuation byte */
    return mrb_utf8len(lead, end) > back ? lead : p;
  }
  return p;
}

/* Decode a UTF-8 character and return its codepoint.
   *lenp is set to the byte length consumed. What mrb_utf8len() rejects is
   rejected here by the same view, so those consume a single byte and come
   back as the lead byte itself. */
uint32_t
mrb_utf8_decode(const char *p, const char *e, mrb_int *lenp)
{
  uint32_t uv;
  mrb_int n = mrb_utf8_scan(p, e, &uv, utf8_rfc3629_bounds);

  if (n < 0) {
    *lenp = 1;
    return (uint8_t)p[0];
  }
  *lenp = n;
  return uv;
}
