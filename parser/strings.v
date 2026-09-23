module kdl

import strings

// Quoted, multi-line and raw strings.

// quoted-string := '"' single-line-string-body '"' | '"""' newline ... '"""'
@[direct_array_access]
fn (mut p Parser) quoted_string() !string {
	if p.starts_with('"""') {
		return p.multiline_string()
	}
	open := p.pos
	p.pos++
	start := p.pos
	mut sb := strings.new_builder(0)
	mut has_escape := false
	mut seg := start
	for {
		if p.eof() {
			return error_at(open, 'unterminated string')
		}
		b := p.src[p.pos]
		if b == `"` {
			break
		}
		if b == `\\` {
			if !has_escape {
				has_escape = true
				sb = strings.new_builder(p.pos - start + 16)
			}
			sb.write_string(p.src[seg..p.pos])
			p.pos++
			if p.eof() {
				return error_at(open, 'unterminated string')
			}
			if p.is_ws_escape_char() {
				for !p.eof() && p.is_ws_escape_char() {
					p.skip_ws_escape_char()
				}
			} else {
				p.pos = append_escape(p.src, p.pos, mut sb)!
			}
			seg = p.pos
			continue
		}
		if p.at_newline() {
			return p.fail('newline in single-line string, use a multi-line string `"""`')
		}
		p.skip_char()
	}
	end := p.pos
	p.pos++ // closing quote
	if !has_escape {
		return p.src[start..end]
	}
	sb.write_string(p.src[seg..end])
	return sb.str()
}

@[inline]
fn (p &Parser) is_ws_escape_char() bool {
	b := p.peek()
	if b == ` ` || b == `\t` || b == `\n` || b == `\r` || b == 0x0B || b == 0x0C {
		return true
	}
	if b < 0x80 {
		return false
	}
	r, _ := p.rune_here()
	return is_space_rune(r) || is_newline_rune(r)
}

@[inline]
fn (mut p Parser) skip_ws_escape_char() {
	if p.peek() < 0x80 {
		p.pos++
		return
	}
	_, len := p.rune_here()
	p.pos += len
}

// multiline_string handles `"""` newline (body newline)? (unicode-space | ws-escape)* `"""`.
// Whitespace escapes are resolved first, then the string is dedented using the
// whitespace of the closing line, then the remaining escapes are resolved.
@[direct_array_access]
fn (mut p Parser) multiline_string() !string {
	open := p.pos
	p.pos += 3
	if !p.newline() {
		return p.fail('a multi-line string must start with a newline after `"""`')
	}
	mut lines := []string{}
	mut cur := strings.new_builder(64)
	for {
		if p.eof() {
			return error_at(open, 'unterminated multi-line string')
		}
		b := p.src[p.pos]
		if b == `"` && p.starts_with('"""') {
			p.pos += 3
			break
		}
		if b == `\\` {
			p.pos++
			if p.eof() {
				return error_at(open, 'unterminated multi-line string')
			}
			if p.is_ws_escape_char() {
				for !p.eof() && p.is_ws_escape_char() {
					p.skip_ws_escape_char()
				}
				continue
			}
			// keep the escape for the second pass, but make sure a `\"` does
			// not take part in the closing-delimiter detection and that a
			// whitespace escape cannot be spliced into the middle of `\u{..}`
			esc_start := p.pos - 1
			if p.src[p.pos] == `u` {
				p.pos = unicode_escape_end(p.src, p.pos)!
			} else if p.src[p.pos] in [u8(`"`), `\\`, `b`, `f`, `n`, `r`, `t`, `s`]! {
				p.pos++
			} else {
				return error_at(esc_start, 'invalid escape in multi-line string')
			}
			cur.write_string(p.src[esc_start..p.pos])
			continue
		}
		if p.newline() {
			lines << cur.str()
			cur = strings.new_builder(64)
			continue
		}
		start := p.pos
		p.skip_char()
		cur.write_string(p.src[start..p.pos])
	}
	last := cur.str()
	body := dedent_lines(lines, last) or { return error_at(open, err.msg()) }
	return unescape(body) or { return error_at(open, err.msg()) }
}

// dedent_lines applies the multi-line string rules: `last` (the closing line)
// must contain only whitespace and is the prefix removed from every non-blank line.
fn dedent_lines(lines []string, last string) !string {
	if !is_all_space(last) {
		return error('the closing `"""` of a multi-line string must be preceded only by whitespace on its line')
	}
	mut sb := strings.new_builder(64)
	for i, line in lines {
		if i > 0 {
			sb.write_u8(`\n`)
		}
		if is_all_space(line) {
			continue
		}
		if !line.starts_with(last) {
			return error('line ${i + 1} of the multi-line string does not start with the whitespace prefix of its closing line')
		}
		sb.write_string(line[last.len..])
	}
	return sb.str()
}

@[direct_array_access]
fn is_all_space(s string) bool {
	mut i := 0
	for i < s.len {
		b := s[i]
		if b == ` ` || b == `\t` {
			i++
			continue
		}
		if b < 0x80 {
			return false
		}
		r, len := decode_rune(s, i)
		if !is_space_rune(r) {
			return false
		}
		i += len
	}
	return true
}

// raw_string handles `#"..."#` and `#"""` multi-line raw strings. `hashes` is
// the number of leading `#`; p.pos is at the first `#`.
@[direct_array_access]
fn (mut p Parser) raw_string(hashes int) !string {
	open := p.pos
	p.pos += hashes
	mut closing := '"' + '#'.repeat(hashes)
	if p.starts_with('"""') {
		p.pos += 3
		if !p.newline() {
			return p.fail('a multi-line raw string must start with a newline after `"""`')
		}
		closing = '""' + closing
		mut lines := []string{}
		mut line_start := p.pos
		for {
			if p.eof() {
				return error_at(open, 'unterminated multi-line raw string')
			}
			if p.src[p.pos] == `"` && p.starts_with(closing) {
				last := p.src[line_start..p.pos]
				p.pos += closing.len
				return dedent_lines(lines, last) or { return error_at(open, err.msg()) }
			}
			if p.at_newline() {
				lines << p.src[line_start..p.pos]
				p.newline()
				line_start = p.pos
				continue
			}
			p.skip_char()
		}
	}
	p.pos++ // opening quote
	start := p.pos
	for {
		if p.eof() {
			return error_at(open, 'unterminated raw string')
		}
		if p.src[p.pos] == `"` && p.starts_with(closing) {
			s := p.src[start..p.pos]
			p.pos += closing.len
			return s
		}
		if p.at_newline() {
			return p.fail('newline in single-line raw string, use `#"""`')
		}
		p.skip_char()
	}
	return ''
}
