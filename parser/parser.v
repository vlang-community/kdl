module kdl

import os

// Recursive-descent parser for KDL 2.0, following the grammar of the
// specification (section 4) including the published errata.

struct Parser {
	src string
mut:
	pos int
}

// parse parses a KDL document from a string.
pub fn parse(src string) !Document {
	mut p := Parser{
		src: src
	}
	// fields rather than a method on `p` in the `or` block: the new V compiler
	// passes `&p` there although `p` is already a pointer, which gcc rejects
	return p.document() or { return to_parse_error(p.src, p.pos, err) }
}

// parse_file reads and parses a KDL file. Syntax errors are ParseError values;
// I/O errors are ordinary errors.
pub fn parse_file(path string) !Document {
	src := os.read_file(path) or { return error('cannot read ${path}: ${err.msg()}') }
	return parse(src)
}

// to_parse_error converts an error of the parser, at `pos` in `src`, into a ParseError.
fn to_parse_error(src string, pos int, err IError) IError {
	offset, message := if err is OffsetError {
		err.offset, err.message
	} else {
		pos, err.msg()
	}
	line, col := line_col(src, offset)
	return ParseError{
		line:    line
		col:     col
		offset:  offset
		message: message
	}
}

// line_col converts a byte offset into 1-based line and column (in code points).
@[direct_array_access]
fn line_col(s string, offset int) (int, int) {
	mut line := 1
	mut col := 1
	mut i := 0
	end := if offset > s.len { s.len } else { offset }
	// a leading byte order mark is not a visible column
	if end >= 3 && s[0] == 0xEF && s[1] == 0xBB && s[2] == 0xBF {
		i = 3
	}
	for i < end {
		r, n := decode_rune(s, i)
		if r == 0x0D && i + 1 < end && s[i + 1] == 0x0A {
			i += 2
			line++
			col = 1
			continue
		}
		if is_newline_rune(r) {
			line++
			col = 1
		} else {
			col++
		}
		i += n
	}
	return line, col
}

fn (p &Parser) fail(message string) IError {
	return error_at(p.pos, message)
}

@[inline]
fn (p &Parser) eof() bool {
	return p.pos >= p.src.len
}

@[direct_array_access; inline]
fn (p &Parser) peek() u8 {
	return if p.pos < p.src.len { p.src[p.pos] } else { 0 }
}

@[direct_array_access; inline]
fn (p &Parser) peek_at(off int) u8 {
	i := p.pos + off
	return if i < p.src.len { p.src[i] } else { 0 }
}

@[direct_array_access; inline]
fn (p &Parser) starts_with(s string) bool {
	if p.pos + s.len > p.src.len {
		return false
	}
	for i in 0 .. s.len {
		if p.src[p.pos + i] != s[i] {
			return false
		}
	}
	return true
}

// rune_here decodes the rune at the current position (0, 0 at eof).
@[inline]
fn (p &Parser) rune_here() (rune, int) {
	if p.pos >= p.src.len {
		return 0, 0
	}
	return decode_rune(p.src, p.pos)
}

// ---------------------------------------------------------------------------
// Document

fn (mut p Parser) document() !Document {
	if p.src.len >= 3 && p.src[0] == 0xEF && p.src[1] == 0xBB && p.src[2] == 0xBF {
		p.pos = 3
	}
	validate_input(p.src, p.pos)!
	p.version_marker()!
	mut doc := Document{}
	p.nodes(mut doc.nodes)!
	if !p.eof() {
		return p.fail('unexpected `}`')
	}
	return doc
}

// version := '/-' unicode-space* 'kdl-version' unicode-space+ ('1' | '2') unicode-space* newline
fn (mut p Parser) version_marker() ! {
	start := p.pos
	if !p.starts_with('/-') {
		return
	}
	p.pos += 2
	p.skip_unicode_spaces()
	if !p.starts_with('kdl-version') {
		p.pos = start
		return
	}
	p.pos += 'kdl-version'.len
	if p.skip_unicode_spaces() == 0 {
		p.pos = start
		return
	}
	version := p.peek()
	if version != `1` && version != `2` {
		p.pos = start
		return
	}
	p.pos++
	p.skip_unicode_spaces()
	if !p.newline() {
		p.pos = start
		return
	}
	if version == `1` {
		return error_at(start, 'document declares kdl-version 1, only KDL 2.0 is supported')
	}
}

// nodes := (line-space* node)* line-space*
// Inside children the last node may omit its terminator (final-node).
// Nodes are built in place inside `out` to avoid copying subtrees.
fn (mut p Parser) nodes(mut out []Node) ! {
	for {
		p.line_spaces()!
		if p.eof() || p.peek() == `}` {
			break
		}
		out << Node{}
		keep := p.base_node(mut out[out.len - 1])!
		if !keep {
			out.delete_last()
		}
		if p.node_terminator()! {
			continue
		}
		if p.peek() == `}` {
			continue
		}
		return p.fail('expected a newline, `;` or end of input after node')
	}
}

// node-terminator := single-line-comment | newline | ';' | eof
fn (mut p Parser) node_terminator() !bool {
	if p.eof() {
		return true
	}
	if p.peek() == `;` {
		p.pos++
		return true
	}
	if p.newline() {
		return true
	}
	return p.single_line_comment()!
}

// base-node := slashdash? type? node-space* string
//     (node-space* (node-space | slashdash) node-prop-or-arg)*
//     (node-space* slashdash node-children)*
//     (node-space* node-children)?
//     (node-space* slashdash node-children)*
//     node-space*
// Fills `node` and returns false when the node itself is slashdashed.
fn (mut p Parser) base_node(mut node Node) !bool {
	commented := p.slashdash()!
	if p.peek() == `{` {
		return p.fail('expected a node name before `{`')
	}
	ty, has_ty := p.type_annotation()!
	if has_ty {
		node.ty = ty
	}
	p.node_space0()!
	name_start := p.pos
	tok := p.token()!
	match tok {
		StringTok {
			node.name = tok.value
		}
		NoTok {
			if commented {
				return p.fail('expected a node after `/-`')
			}
			return p.fail('expected a node name')
		}
		else {
			return error_at(name_start, 'a node name must be a string, not a number or keyword')
		}
	}
	// entries
	for {
		save := p.pos
		had_space := p.node_space1()!
		if p.slashdash()! {
			if p.peek() == `{` {
				p.pos = save
				break
			}
			mut scratch := Node{}
			if !p.entry(mut scratch)! {
				return p.fail('expected an argument or property after `/-`')
			}
			continue
		}
		if !had_space || p.peek() == `{` {
			p.pos = save
			break
		}
		if !p.entry(mut node)! {
			p.pos = save
			break
		}
	}
	// children
	mut seen_children := false
	for {
		save := p.pos
		p.node_space0()!
		if p.slashdash()! {
			if p.peek() != `{` {
				return p.fail('expected a children block after `/-`')
			}
			mut scratch := []Node{}
			p.children(mut scratch)!
			continue
		}
		if p.peek() == `{` {
			if seen_children {
				return p.fail('a node may only have one children block')
			}
			p.children(mut node.children)!
			seen_children = true
			continue
		}
		p.pos = save
		break
	}
	p.node_space0()!
	return !commented
}

// node-children := '{' nodes final-node? '}'
fn (mut p Parser) children(mut out []Node) ! {
	open := p.pos
	p.pos++ // {
	p.nodes(mut out)!
	if p.peek() != `}` {
		return error_at(open, 'missing `}` for children block')
	}
	p.pos++
}

// node-prop-or-arg := prop | value
// prop := string node-space* '=' node-space* value
// value := type? node-space* (string | number | keyword)
// Adds the entry to `node` and returns false when there is no entry here.
fn (mut p Parser) entry(mut node Node) !bool {
	if p.peek() == `(` {
		node.arguments << p.value()!
		return true
	}
	tok := p.token()!
	match tok {
		NoTok {
			return false
		}
		StringTok {
			save := p.pos
			p.node_space0()!
			if p.peek() == `=` {
				p.pos++
				p.node_space0()!
				v := p.value() or {
					if err is OffsetError && err.offset == p.pos {
						return p.fail('expected a value after `${tok.value}=`')
					}
					return err
				}
				node.properties[tok.value] = v
				return true
			}
			p.pos = save
			node.arguments << Value{
				data: tok.value
			}
			return true
		}
		DataTok {
			node.arguments << Value{
				data: tok.data
			}
			return true
		}
	}
	return false
}

fn (mut p Parser) value() !Value {
	ty, has_ty := p.type_annotation()!
	p.node_space0()!
	start := p.pos
	tok := p.token()!
	mut v := Value{}
	if has_ty {
		v.ty = ty
	}
	match tok {
		StringTok {
			v.data = tok.value
			return v
		}
		DataTok {
			v.data = tok.data
			return v
		}
		NoTok {
			return error_at(start, 'expected a value')
		}
	}
	return error_at(start, 'expected a value')
}

// type := '(' node-space* string node-space* ')'
fn (mut p Parser) type_annotation() !(string, bool) {
	if p.peek() != `(` {
		return '', false
	}
	open := p.pos
	p.pos++
	p.node_space0()!
	start := p.pos
	tok := p.token()!
	name := match tok {
		StringTok { tok.value }
		NoTok { return error_at(open, 'expected a type name after `(`') }
		else { return error_at(start, 'a type annotation must be a string') }
	}
	p.node_space0()!
	if p.peek() != `)` {
		return p.fail('expected `)` to close the type annotation')
	}
	p.pos++
	return name, true
}

// ---------------------------------------------------------------------------
// Whitespace, comments, slashdash

// skip_unicode_spaces consumes unicode-space* and returns how many were skipped.
fn (mut p Parser) skip_unicode_spaces() int {
	mut n := 0
	for !p.eof() {
		b := p.peek()
		if b == ` ` || b == `\t` {
			p.pos++
			n++
			continue
		}
		if b < 0x80 {
			break
		}
		r, len := p.rune_here()
		if !is_space_rune(r) {
			break
		}
		p.pos += len
		n++
	}
	return n
}

// newline consumes one newline (CRLF counts as one).
fn (mut p Parser) newline() bool {
	if p.eof() {
		return false
	}
	b := p.peek()
	if b == `\r` {
		p.pos++
		if p.peek() == `\n` {
			p.pos++
		}
		return true
	}
	if b == `\n` || b == 0x0B || b == 0x0C {
		p.pos++
		return true
	}
	if b < 0x80 {
		return false
	}
	r, len := p.rune_here()
	if is_newline_rune(r) {
		p.pos += len
		return true
	}
	return false
}

// skip_char advances past the current code point (one byte for ASCII).
@[direct_array_access; inline]
fn (mut p Parser) skip_char() {
	b := p.src[p.pos]
	if b < 0x80 {
		p.pos++
	} else if b < 0xE0 {
		p.pos += 2
	} else if b < 0xF0 {
		p.pos += 3
	} else {
		p.pos += 4
	}
}

@[inline]
fn (p &Parser) at_newline() bool {
	b := p.peek()
	if b == `\n` || b == `\r` || b == 0x0B || b == 0x0C {
		return true
	}
	if b < 0x80 {
		return false
	}
	r, _ := p.rune_here()
	return is_newline_rune(r)
}

// single-line-comment := '//' ^newline* (newline | eof)
fn (mut p Parser) single_line_comment() !bool {
	if !(p.peek() == `/` && p.peek_at(1) == `/`) {
		return false
	}
	p.pos += 2
	for !p.eof() && !p.at_newline() {
		p.skip_char()
	}
	p.newline()
	return true
}

// multi-line-comment := '/*' commented-block, nesting allowed
fn (mut p Parser) multi_line_comment() !bool {
	if !(p.peek() == `/` && p.peek_at(1) == `*`) {
		return false
	}
	open := p.pos
	p.pos += 2
	mut depth := 1
	for !p.eof() {
		if p.peek() == `*` && p.peek_at(1) == `/` {
			p.pos += 2
			depth--
			if depth == 0 {
				return true
			}
		} else if p.peek() == `/` && p.peek_at(1) == `*` {
			p.pos += 2
			depth++
		} else {
			p.skip_char()
		}
	}
	return error_at(open, 'unterminated multi-line comment')
}

// ws := unicode-space | multi-line-comment ; consumes ws* and reports if any.
fn (mut p Parser) wss() !bool {
	mut any := false
	for {
		if p.skip_unicode_spaces() > 0 {
			any = true
			continue
		}
		if p.multi_line_comment()! {
			any = true
			continue
		}
		return any
	}
	return any
}

// escline := '\\' ws* (single-line-comment | newline | eof)
fn (mut p Parser) escline() !bool {
	if p.peek() != `\\` {
		return false
	}
	start := p.pos
	p.pos++
	p.wss()!
	if p.eof() || p.newline() || p.single_line_comment()! {
		return true
	}
	return error_at(start, 'a line continuation `\\` must be followed by a newline or comment')
}

// node-space := ws* escline ws* | ws+
fn (mut p Parser) node_space() !bool {
	any := p.wss()!
	if p.escline()! {
		p.wss()!
		return true
	}
	return any
}

// node_space0 consumes node-space*, with a fast path for ASCII blanks.
@[direct_array_access]
fn (mut p Parser) node_space0() ! {
	for {
		for p.pos < p.src.len && (p.src[p.pos] == ` ` || p.src[p.pos] == `\t`) {
			p.pos++
		}
		b := p.peek()
		if (b == `/` || b == `\\` || b >= 0x80) && p.node_space()! {
			continue
		}
		return
	}
}

// node_space1 consumes node-space* and reports whether anything was consumed.
fn (mut p Parser) node_space1() !bool {
	start := p.pos
	p.node_space0()!
	return p.pos > start
}

// line-space := node-space | newline | single-line-comment ; consumes line-space*
@[direct_array_access]
fn (mut p Parser) line_spaces() ! {
	for {
		for p.pos < p.src.len {
			b := p.src[p.pos]
			if b == ` ` || b == `\t` || b == `\n` || b == `\r` {
				p.pos++
			} else {
				break
			}
		}
		if p.node_space()! || p.newline() || p.single_line_comment()! {
			continue
		}
		return
	}
}

// slashdash := '/-' line-space*
fn (mut p Parser) slashdash() !bool {
	if !(p.peek() == `/` && p.peek_at(1) == `-`) {
		return false
	}
	p.pos += 2
	p.line_spaces()!
	return true
}

// ---------------------------------------------------------------------------
// Tokens: strings, numbers, keywords

struct StringTok {
	value string
}

struct DataTok {
	data Data
}

struct NoTok {}

type Token = DataTok | NoTok | StringTok

// token scans a string (identifier, quoted, raw), a number or a keyword at the
// current position. Returns NoTok when the position does not start one.
@[direct_array_access]
fn (mut p Parser) token() !Token {
	if p.eof() {
		return NoTok{}
	}
	b := p.peek()
	if b == `"` {
		return StringTok{p.quoted_string()!}
	}
	if b == `#` {
		mut j := p.pos + 1
		for j < p.src.len && p.src[j] == `#` {
			j++
		}
		if j < p.src.len && p.src[j] == `"` {
			return StringTok{p.raw_string(j - p.pos)!}
		}
		return p.keyword()!
	}
	start := p.pos
	p.skip_ident_chars()
	if p.pos == start {
		return NoTok{}
	}
	s := p.src[start..p.pos]
	if looks_like_number(s) {
		d := parse_number(s) or { return error_at(start, err.msg()) }
		return DataTok{d}
	}
	if s in keyword_idents {
		return error_at(start, 'bare `${s}` is not allowed, use `#${s}`')
	}
	return StringTok{s}
}

// skip_ident_chars consumes identifier-char*.
@[direct_array_access]
fn (mut p Parser) skip_ident_chars() {
	for p.pos < p.src.len {
		b := p.src[p.pos]
		if b < 0x80 {
			if !is_ident_byte(b) {
				return
			}
			p.pos++
			continue
		}
		r, len := decode_rune(p.src, p.pos)
		if is_space_rune(r) || is_newline_rune(r) {
			return
		}
		p.pos += len
	}
}

// keyword := '#true' | '#false' | '#null' | '#inf' | '#-inf' | '#nan'
fn (mut p Parser) keyword() !Token {
	start := p.pos
	p.pos++ // #
	p.skip_ident_chars()
	word := p.src[start + 1..p.pos]
	neg_inf := -f64_inf
	data := match word {
		'true' { Data(true) }
		'false' { Data(false) }
		'null' { Data(Null{}) }
		'inf' { Data(f64_inf) }
		'-inf' { Data(neg_inf) }
		'nan' { Data(f64_nan) }
		else { return error_at(start, 'unknown keyword `#${word}`') }
	}
	return DataTok{data}
}

const f64_inf = f64(1e308) * 10.0
const f64_nan = f64_inf - f64_inf
