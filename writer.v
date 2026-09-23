module kdl

import strings

// Serialisation back to KDL text. Output is canonical: one node per line,
// four-space indentation, properties sorted by name, strings written bare when
// they are valid identifiers and quoted otherwise.

// str renders the document as KDL 2.0 text.
pub fn (d Document) str() string {
	return write_document(&d)
}

// write_document renders the nodes of `d`. It takes a reference: see write_node.
fn write_document(d &Document) string {
	mut sb := strings.new_builder(256)
	for i in 0 .. d.nodes.len {
		write_node(mut sb, &d.nodes[i], 0)
	}
	return sb.str()
}

// write_children renders the children of `root` as top-level nodes.
fn write_children(root &Node) string {
	mut sb := strings.new_builder(256)
	for i in 0 .. root.children.len {
		write_node(mut sb, &root.children[i], 0)
	}
	return sb.str()
}

// str renders a single node (and its children) as KDL 2.0 text.
pub fn (n Node) str() string {
	mut sb := strings.new_builder(64)
	write_node(mut sb, &n, 0)
	return sb.str()
}

// str renders a value as it would appear in a KDL document.
pub fn (v Value) str() string {
	mut sb := strings.new_builder(16)
	write_value(mut sb, &v)
	return sb.str()
}

// Documents, nodes and values are passed by reference below: the old V
// compiler (`-old-compiler`, with `-prod` and the Boehm GC) pins a by-value
// struct argument as a GC root by walking its whole content before every call
// made from the function, which made writing a document quadratic. The public
// receivers stay by value and only make one call, passing their address.
fn write_node(mut sb strings.Builder, n &Node, depth int) {
	for _ in 0 .. depth {
		sb.write_string('    ')
	}
	if ty := n.ty {
		sb.write_u8(`(`)
		write_string(mut sb, ty)
		sb.write_u8(`)`)
	}
	write_string(mut sb, n.name)
	for i in 0 .. n.arguments.len {
		sb.write_u8(` `)
		write_value(mut sb, &n.arguments[i])
	}
	mut keys := n.properties.keys()
	keys.sort()
	for k in keys {
		sb.write_u8(` `)
		write_string(mut sb, k)
		sb.write_u8(`=`)
		v := n.properties[k] or { continue }
		write_value(mut sb, &v)
	}
	if n.children.len > 0 {
		sb.write_string(' {\n')
		for i in 0 .. n.children.len {
			write_node(mut sb, &n.children[i], depth + 1)
		}
		for _ in 0 .. depth {
			sb.write_string('    ')
		}
		sb.write_u8(`}`)
	}
	sb.write_u8(`\n`)
}

fn write_value(mut sb strings.Builder, v &Value) {
	if ty := v.ty {
		sb.write_u8(`(`)
		write_string(mut sb, ty)
		sb.write_u8(`)`)
	}
	match v.data {
		string { write_string(mut sb, v.data) }
		i64 { sb.write_string(v.data.str()) }
		BigInt { sb.write_string(v.data.str()) }
		f64 { sb.write_string(format_float(v.data)) }
		bool {
			// bound first: the new V compiler writes an `if` expression argument into
			// a snapshot of `sb` when `v` is a reference, and loses it
			text := if v.data { '#true' } else { '#false' }
			sb.write_string(text)
		}
		Null { sb.write_string('#null') }
	}
}

// format_float writes a float so that it parses back as a float: it always has
// a fraction or an exponent, and exponents carry an explicit sign.
fn format_float(f f64) string {
	if f == f64_inf {
		return '#inf'
	}
	if f == -f64_inf {
		return '#-inf'
	}
	if f != f {
		return '#nan'
	}
	mut s := f.str()
	if e := s.index('e') {
		mant := s[..e]
		mut exp := s[e + 1..]
		if exp[0] != `-` && exp[0] != `+` {
			exp = '+' + exp
		}
		return '${mant}E${exp}'
	}
	if !s.contains('.') {
		s += '.0'
	}
	return s
}

// is_bare_identifier reports whether s can be written without quotes.
@[direct_array_access]
fn is_bare_identifier(s string) bool {
	if s == '' || looks_like_number(s) || s in keyword_idents {
		return false
	}
	mut i := 0
	for i < s.len {
		b := s[i]
		if b < 0x80 {
			if !is_ident_byte(b) {
				return false
			}
			i++
			continue
		}
		r, len := decode_rune(s, i)
		if is_space_rune(r) || is_newline_rune(r) || is_disallowed_rune(r) {
			return false
		}
		i += len
	}
	return true
}

// write_string writes s bare when possible, quoted and escaped otherwise.
fn write_string(mut sb strings.Builder, s string) {
	if is_bare_identifier(s) {
		sb.write_string(s)
		return
	}
	sb.write_u8(`"`)
	mut i := 0
	for i < s.len {
		b := s[i]
		if b < 0x80 {
			match b {
				`"` { sb.write_string('\\"') }
				`\\` { sb.write_string('\\\\') }
				`\n` { sb.write_string('\\n') }
				`\r` { sb.write_string('\\r') }
				`\t` { sb.write_string('\\t') }
				0x08 { sb.write_string('\\b') }
				0x0C { sb.write_string('\\f') }
				else {
					if b < 0x20 || b == 0x7F {
						sb.write_string('\\u{${u32(b):x}}')
					} else {
						sb.write_u8(b)
					}
				}
			}
			i++
			continue
		}
		r, len := decode_rune(s, i)
		if is_disallowed_rune(r) || is_newline_rune(r) || (r >= 0xD800 && r <= 0xDFFF) {
			sb.write_string('\\u{${u32(r):x}}')
		} else {
			sb.write_string(s[i..i + len])
		}
		i += len
	}
	sb.write_u8(`"`)
}
