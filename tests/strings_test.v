// Adapted from tests/string_test.v and tests/unicode_test.v of github.com/vlang-community/kdl
// at commit 721a303, by Jengro777.
module main

import kdl

// is_bare_identifier reports whether the writer emits `s` without quotes: a
// quoted string always starts with `"`, which a bare identifier never contains.
fn is_bare_identifier(s string) bool {
	return kdl.Node{
		name: s
	}.str() == s + '\n'
}

fn strings_rejects(src string) {
	kdl.parse(src) or { return }
	assert false, 'expected parse error for ${src}'
}

// strings_first parses a document made of one node with one string argument and returns it.
fn strings_first(src string) !string {
	doc := kdl.parse(src)!
	if doc.nodes.len != 1 || doc.nodes[0].arguments.len != 1 {
		return error('expected one node with one argument: ${src}')
	}
	return doc.nodes[0].arguments[0].as_string() or { return error('not a string: ${src}') }
}

fn test_string_escapes() {
	assert strings_first('v "a\\\nb"')! == 'ab'
	assert strings_first('v "a\\"b"')! == 'a"b'
	assert strings_first('v "a\\\\b"')! == 'a\\b'
	assert strings_first('v "a\\bb"')! == 'a\bb'
	assert strings_first('v "a\\fb"')! == 'a\x0cb'
	assert strings_first('v "a\\sb"')! == 'a b'
	assert strings_first('v "a\\rb"')! == 'a\rb'
	assert strings_first('v ""')! == ''
}

fn test_invalid_escapes_rejected() {
	strings_rejects('v "\\x"')
	strings_rejects('v "\\y"')
	// a backslash at the end of the input
	strings_rejects('v "a\\')
}

fn test_raw_strings() {
	assert strings_first('v #"hello"#')! == 'hello'
	assert strings_first('v #"\\n\\t\\r"#')! == '\\n\\t\\r'
	assert strings_first('v #"hello \\"world\\""#')! == 'hello \\"world\\"'
	assert strings_first('v ##"has "#" inside"##')! == 'has "#" inside'
	assert strings_first('v ###"has "## inside"###')! == 'has "## inside'
	assert strings_first('v ##"value"##')! == 'value'
	strings_rejects('v ##"value"#')
}

fn test_multiline_strings() {
	assert strings_first('md """\n  hello\n  """')! == 'hello'
	assert strings_first('md """\n    hello\n    """')! == 'hello'
	assert strings_first('md """\n  line1\n  line2\n  """')! == 'line1\nline2'
	assert strings_first('md """\n"""')! == ''
	assert strings_first('md """\n  line1\n\n  line2\n  """')! == 'line1\n\nline2'
	strings_rejects('md """hello"""')
}

fn test_multiline_raw_strings() {
	assert strings_first('md #"""\n  hello\n  """#')! == 'hello'
	assert strings_first('md #"""\n    \\n\\t\\r\n    """#')! == '\\n\\t\\r'
	assert strings_first('md #"""\n  \\n\\t\\\\\n  """#')! == '\\n\\t\\\\'
	assert strings_first('md #"""\n"""#')! == ''
}

fn test_multiline_raw_followed_by_node() {
	doc := kdl.parse('md #"""\n  hello\n  """#\nnext-node')!
	assert doc.nodes.len == 2
	assert doc.nodes[0].name == 'md'
	assert doc.nodes[0].arguments.len == 1
	assert doc.nodes[0].arg(0).as_string()? == 'hello'
	assert doc.nodes[1].name == 'next-node'
}

fn test_multiline_shorter_last_indent() {
	src := 'md """\n      foo\n  This is base\n          bar\n  """'
	assert strings_first(src)! == '    foo\nThis is base\n        bar'
}

fn test_multiline_whitespace_escape_then_dedent() {
	assert strings_first('md """\n  foo \\\n  bar\n  """')! == 'foo bar'
}

fn test_writer_quotes_and_escapes() {
	for s, want in {
		'This is a test':   'This is a test'
		'This "is" a test': 'This \\"is\\" a test'
		'This is\ta test':  'This is\\ta test'
		'This is a test\\': 'This is a test\\\\'
		'he\nllo':          'he\\nllo'
		'\x7f':             '\\u{7f}'
		'\x01':             '\\u{1}'
	} {
		out := kdl.Value{
			data: s
		}.str()
		assert out == '"${want}"'
		assert strings_first('v ${out}')! == s
	}
	// valid identifiers are written bare
	assert kdl.Value{
		data: 'hello'
	}.str() == 'hello'
}

fn test_parse_quoted_strings() {
	for src, want in {
		'"This is a test"': 'This is a test'
		'""':               ''
		'"x"':              'x'
		'"x\\t"':           'x\t'
		'"\\tx"':           '\tx'
		'"\\t"':            '\t'
		'"\\\n"':           ''
	} {
		assert strings_first('v ${src}')! == want
	}
	strings_rejects('v "This is a test\\"')
	strings_rejects('v "')
	strings_rejects('v hello"')
}

fn test_bare_identifier_detection() {
	for s in ['hello', 'hello-world', 'foo123'] {
		assert is_bare_identifier(s), s
	}
	for s in ['true', 'false', 'null', '', 'hello world'] {
		assert !is_bare_identifier(s), s
	}
}

fn test_unicode_escapes() {
	assert strings_first('v "\\u{0}"')! == '\x00'
	assert strings_first('v "\\u{a}"')! == '\n'
	assert strings_first('v "\\u{10FFFF}"')!.len == 4
}

fn test_quote_inside_bare_value_rejected() {
	strings_rejects('v "a"b"')
}

fn test_bidi_control_literal_in_quoted_string_rejected() {
	strings_rejects('v "\u200e"')
}

fn test_special_node_names() {
	assert kdl.parse('_')!.nodes[0].name == '_'
	doc := kdl.parse('\U0001F525 "val"')!
	assert doc.nodes[0].name == '\U0001F525'
	assert doc.nodes[0].arguments.len == 1
}

fn test_empty_quoted_property_key() {
	doc := kdl.parse('node ""=val')!
	assert '' in doc.nodes[0].properties
	assert doc.nodes[0].prop('').as_string()? == 'val'
}

fn test_multiline_close_line_trailers() {
	// node-space and node terminators may follow the closing quotes
	for src in ['md """\n  hello\n  """ // trailing comment',
		'md #"""\n  hello\n  """# // trailing comment', 'md #"""\n  hello\n  """#   '] {
		assert strings_first(src)! == 'hello'
	}
	for src in ['md #"""\n  hello\n  """# // this is a comment, not content\nextra-node',
		'md #"""\n  hello\n  """# // comment\nworld'] {
		doc := kdl.parse(src)!
		assert doc.nodes.len == 2
		assert doc.nodes[0].name == 'md'
		assert doc.nodes[0].arg(0).as_string()? == 'hello'
	}
}

fn test_unicode_spaces_after_node_name() {
	// NBSP, ideographic, thin, em and figure spaces
	for sp in ['\u00a0', '\u3000', '\u2009', '\u2003', '\u2007'] {
		doc := kdl.parse('node${sp}"val"')!
		assert doc.nodes[0].name == 'node'
		assert doc.nodes[0].arg(0).as_string()? == 'val'
	}
}

fn test_unicode_bom() {
	assert kdl.parse('\ufeffnode "val"')!.nodes[0].name == 'node'
}
