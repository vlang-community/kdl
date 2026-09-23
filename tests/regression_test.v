// Adapted from tests/spec_regression_test.v of github.com/vlang-community/kdl
// at commit 721a303, by Jengro777.
module main

import kdl
import math

const f64_inf = math.inf(1)

// is_bare_identifier reports whether the writer emits `s` without quotes: a
// quoted string always starts with `"`, which a bare identifier never contains.
fn is_bare_identifier(s string) bool {
	return kdl.Node{
		name: s
	}.str() == s + '\n'
}

fn regression_rejects(src string) {
	kdl.parse(src) or { return }
	assert false, 'expected parse error for ${src}'
}

// regression_first parses a document made of one node with one argument and returns it.
fn regression_first(src string) !kdl.Value {
	doc := kdl.parse(src)!
	if doc.nodes.len != 1 || doc.nodes[0].arguments.len != 1 {
		return error('expected one node with one argument: ${src}')
	}
	return doc.nodes[0].arguments[0]
}

fn test_raw_string_disallowed_controls_rejected() {
	regression_rejects([u8(`v`), ` `, `#`, `"`, 0x00, `"`, `#`].bytestr())
	regression_rejects([u8(`v`), ` `, `#`, `"`, 0x01, `"`, `#`].bytestr())
	regression_rejects([u8(`v`), ` `, `#`, `"`, 0x7f, `"`, `#`].bytestr())
}

fn test_quoted_string_disallowed_controls_rejected() {
	regression_rejects([u8(`v`), ` `, `"`, 0x7f, `"`].bytestr())
	regression_rejects([u8(`v`), ` `, `"`, 0x1f, `"`].bytestr())
	regression_rejects([u8(`n`), `o`, `d`, `e`, 0x00, `"`, `v`, `a`, `l`, `"`].bytestr())
}

fn test_u0080_literal_is_valid_in_strings() {
	assert regression_first('v #"\u0080"#')!.as_string()? == '\u0080'
	assert regression_first('v "\u0080"')!.as_string()? == '\u0080'
	assert regression_first('v #"hello"#')!.as_string()? == 'hello'
}

fn test_quoted_string_del_escape() {
	assert regression_first('v "\\u{7f}"')!.as_string()? == '\x7f'
}

fn test_signed_leading_zero_and_zero() {
	assert regression_first('v -07')!.as_int()? == -7
	assert regression_first('v +07')!.as_int()? == 7
	assert regression_first('v -0')!.as_int()? == 0
	assert regression_first('v +0')!.as_int()? == 0
	assert regression_first('v -0_1')!.as_int()? == -1
}

fn test_underscores_in_integers() {
	assert regression_first('v 12____')!.as_int()? == 12
	assert regression_first('v 1___2')!.as_int()? == 12
	assert regression_first('v 1_')!.as_int()? == 1
	assert regression_first('v 100_')!.as_int()? == 100
	assert regression_first('v 0xFF_')!.as_int()? == 255
	assert regression_first('v 0xF__F')!.as_int()? == 255
	assert regression_first('v 0o77_')!.as_int()? == 63
	assert regression_first('v 0b10_')!.as_int()? == 2
	regression_rejects('v 0x_FF')
	regression_rejects('v 0o_77')
}

fn test_escline() {
	doc := kdl.parse('node \\')!
	assert doc.nodes.len == 1
	assert doc.nodes[0].name == 'node'
	doc2 := kdl.parse('node \\\n  arg1')!
	assert doc2.nodes[0].arguments.len == 1
}

fn test_multiline_newline_normalization() {
	assert regression_first('md """\r\n  hello\r\n  """')!.as_string()? == 'hello'
	assert regression_first('md """\n  hello\n  """')!.as_string()? == 'hello'
	assert regression_first('md #"""\r\n  hello\r\n  """#')!.as_string()? == 'hello'
	assert regression_first('md """\r\n  hello\r\n  world\r\n  """')!.as_string()? == 'hello\nworld'
	assert regression_first('md """\r\n\r\n  hello\r\n  """')!.as_string()? == '\nhello'
	assert regression_first('md """\r\n\r\n\r\n  hello\r\n  """')!.as_string()? == '\n\nhello'
}

fn test_multiline_unicode_newlines() {
	assert regression_first('md """\x0b  hello\x0b  """')!.as_string()? == 'hello'
	assert regression_first('md """\u0085  hello\u0085  """')!.as_string()? == 'hello'
	assert regression_first('md """\u2028  hello\u2028  """')!.as_string()? == 'hello'
	assert regression_first('md """\u2029  hello\u2029  """')!.as_string()? == 'hello'
}

fn test_bom() {
	assert kdl.parse('\ufeffnode')!.nodes[0].name == 'node'
	doc := kdl.parse('\ufeff/- kdl-version 2\nnode')!
	assert doc.nodes.len == 1
	assert doc.nodes[0].name == 'node'
	regression_rejects('n\ufeffode')
}

fn test_unicode_spaces_separate_entries() {
	// NBSP, ogham, en quad, em quad, en space, three/four/six-per-em, punctuation,
	// hair, narrow NBSP and medium math spaces
	for sp in ['\u00a0', '\u1680', '\u2000', '\u2001', '\u2002', '\u2004', '\u2005', '\u2006',
		'\u2008', '\u200a', '\u202f', '\u205f'] {
		doc := kdl.parse('node${sp}"val"')!
		assert doc.nodes[0].name == 'node'
		assert doc.nodes[0].arguments.len == 1
	}
}

fn test_unicode_newlines_split_nodes() {
	for nl in ['\u2028', '\u2029', '\u0085', '\r', '\r\n', '\x0b', '\x0c'] {
		doc := kdl.parse('node1${nl}node2')!
		assert doc.nodes.len == 2
		assert doc.nodes[0].name == 'node1'
		assert doc.nodes[1].name == 'node2'
	}
	doc := kdl.parse('node1\rnode2\u2028node3')!
	assert doc.nodes.map(it.name) == ['node1', 'node2', 'node3']
}

fn test_keyword_floats() {
	doc := kdl.parse('v #inf #-inf #nan')!
	a := doc.nodes[0].arguments
	assert a[0].as_f64()? == f64_inf
	assert a[1].as_f64()? == -f64_inf
	nan := a[2].as_f64()?
	assert nan != nan
	assert doc.str().contains('#inf')
	assert kdl.parse(doc.str())!.equals(doc)
}

fn test_keyword_followed_by_nbsp() {
	doc := kdl.parse('v #inf\u00a0test')!
	assert doc.nodes[0].arguments.len == 2
}

fn test_negative_radix_integers_round_trip() {
	doc := kdl.parse('v -0xFF')!
	assert doc.nodes[0].arg(0).as_int()? == -255
	doc2 := kdl.parse(doc.str())!
	assert doc2.nodes[0].arg(0).as_int()? == -255
}

fn test_unicode_escapes() {
	assert regression_first('v "\\u{1F600}"')!.as_string()? == '\U0001F600'
	assert regression_first('v "\\u{10FFFF}"')!.as_string()?.len == 4
	assert regression_first('v "\\u{200E}"')!.as_string()? == '\u200e'
	regression_rejects('v "\\u{D800}"')
	regression_rejects('v "\\u{0000D800}"')
	regression_rejects('v "\\u{110000}"')
	regression_rejects('v "\\u{}"')
	regression_rejects('v "\\u{0000001}"')
	regression_rejects('v "\\u{GHIJ}"')
	regression_rejects([u8(`v`), ` `, `"`, 0xED, 0xA0, 0x80, `"`].bytestr())
}

fn test_slashdash() {
	doc := kdl.parse('/- commented\nreal "val"')!
	assert doc.nodes.len == 1
	assert doc.nodes[0].name == 'real'
	assert kdl.parse('node /- 1 2')!.nodes[0].arguments.len == 1
	doc2 := kdl.parse('/- (person)node\nreal "val"')!
	assert doc2.nodes.map(it.name) == ['real']
	assert kdl.parse('/- a\n/- b\n/- c')!.nodes.len == 0
}

fn test_slashdash_children_blocks() {
	assert kdl.parse('node /- { child1 } { child2 }')!.nodes[0].children.map(it.name) == ['child2']
	assert kdl.parse('node { child1 } /- { child2 }')!.nodes[0].children.map(it.name) == ['child1']
	assert kdl.parse('node /- { c1 } /- { c2 } { c3 }')!.nodes[0].children.map(it.name) == ['c3']
	assert kdl.parse('node /- { child1 }')!.nodes[0].children.len == 0
}

fn test_slashdash_entries() {
	doc := kdl.parse('node /- 1 /- key=val /- 2 3')!
	assert doc.nodes[0].arguments.len == 1
	assert doc.nodes[0].properties.len == 0
	doc2 := kdl.parse('node /- arg /- 1 2')!
	assert doc2.nodes[0].arguments.len == 1
	assert doc2.nodes[0].arg(0).as_int()? == 2
	doc3 := kdl.parse('node /-\n  1 2')!
	assert doc3.nodes[0].arguments.len == 1
	assert doc3.nodes[0].arg(0).as_int()? == 2
}

fn test_slashdash_invalid_targets() {
	regression_rejects('node key=/- val')
	regression_rejects('/- /- node "val"')
	regression_rejects('node a=1 /- (u8)b=2 c=3')
	regression_rejects('node /- { ignored } arg')
	regression_rejects('node { real } /- arg')
	regression_rejects('/-')
	regression_rejects('node /-')
	regression_rejects('node /- ;')
	regression_rejects('/- { child }')
	regression_rejects('node /- { child')
	regression_rejects('/- node { child')
}

fn test_bare_identifiers_that_look_like_numbers_rejected() {
	regression_rejects('node 1.0v2')
	regression_rejects('node -1em')
	regression_rejects('v 1.0x')
	regression_rejects('5foo')
	regression_rejects('v 0XFF')
	regression_rejects('v 0O77')
	regression_rejects('v 0B10')
}

fn test_invalid_numbers() {
	regression_rejects('v 0xGG')
	regression_rejects('v 0o78')
	regression_rejects('v 0b12')
	regression_rejects('v 1e+')
	regression_rejects('v 1.e10')
	regression_rejects('v 1.2.3')
	regression_rejects('v 1._0')
	regression_rejects('v 0._1')
	regression_rejects('v 1e+_1')
	regression_rejects('v 1e-_1')
}

fn test_property_type_annotation() {
	doc := kdl.parse('node key=(u8)123')!
	p := doc.nodes[0].prop('key')
	assert p.ty? == 'u8'
	assert p.as_int()? == 123
	out := doc.str()
	assert out.contains('key=(u8)123')
	doc2 := kdl.parse(out)!
	assert doc2.nodes[0].prop('key').ty? == 'u8'
	assert doc2.nodes[0].prop('key').as_int()? == 123
	regression_rejects('node (u8)key=123')
}

fn test_node_type_annotation() {
	assert kdl.parse('( u8 )node "val"')!.nodes[0].ty? == 'u8'
	regression_rejects('()node "val"')
	regression_rejects([u8(`(`), `\n`, `)`, `n`, `o`, `d`, `e`, ` `, `"`, `v`, `a`, `l`, `"`].bytestr())
	doc := kdl.parse('("foo bar")node "val"')!
	out := doc.str()
	assert out.starts_with('("foo bar")node')
	assert kdl.parse(out)!.nodes[0].ty? == 'foo bar'
}

fn test_multiline_whitespace_only_lines() {
	assert regression_first('md """\n  a\n \t \n  b\n  """')!.as_string()? == 'a\n\nb'
	assert regression_first('md #"""\n  a\n \t \n  b\n  """#')!.as_string()? == 'a\n\nb'
	assert regression_first('md """\n  """')!.as_string()? == ''
	assert regression_first('md """\n\t\\s\n\t"""')!.as_string()? == ' '
}

fn test_multiline_indent_must_match() {
	regression_rejects('md """\n\t space\n \t tab\n\t """')
	regression_rejects('md """\n\tmatched\n not_matched\n\t"""')
	regression_rejects('md """\n\thello\n """')
	assert regression_first('md """\n\thello\n\tworld\n\t"""')!.as_string()? == 'hello\nworld'
}

fn test_multiline_dedent_before_regular_escapes() {
	regression_rejects('v """\n\\s\\sfoo\n  """')
	regression_rejects('v """\n\\tfoo\n\t"""')
	assert regression_first('v """\n  \\sfoo\n  """')!.as_string()? == ' foo'
	regression_rejects('v """\n  a\\q\n  """')
	regression_rejects('v """\n  a\\u123\n  """')
}

fn test_multiline_unicode_whitespace_indent() {
	assert regression_first('v """\n\u00a0hello\n\u00a0"""')!.as_string()? == 'hello'
	assert regression_first('v #"""\n\u00a0hello\n\u00a0"""#')!.as_string()? == 'hello'
}

fn test_version_marker() {
	doc := kdl.parse('/- kdl-version 2\nnode "val"')!
	assert doc.nodes.map(it.name) == ['node']
}

fn test_semicolons() {
	assert kdl.parse('node { child1; child2; }')!.nodes[0].children.len == 2
	assert kdl.parse('a;b')!.nodes.len == 2
	// a lone `;` is neither a node nor line-space in the KDL 2.0 grammar
	regression_rejects('a;;b')
}

fn test_floats_with_underscores_and_exponents() {
	assert regression_first('v 1_000e10')!.as_f64()? == 1e13
	assert regression_first('v 0e+5')!.as_f64()? == 0.0
	assert regression_first('v 1_000.000_1')!.as_f64()? == 1000.0001
	assert regression_first('v 1.0e1_0')!.as_f64()? == 1.0e10
	assert regression_first('v 1.0e1__0')!.as_f64()? == 1.0e10
	assert regression_first('v 0.0')!.as_f64()? == 0.0
	assert regression_first('v 1.0_0')!.as_f64()? == 1.0
	assert regression_first('v 1.0__1')!.as_f64()? == 1.01
	assert regression_first('v 1.0___2')!.as_f64()? == 1.02
	assert regression_first('v 1.0_')!.as_f64()? == 1.0
	assert regression_first('v 1_e10')!.as_f64()? == 1e10
	v := regression_first('v 1.23456789e10')!
	assert kdl.parse('v ${v}')!.nodes[0].arg(0).as_f64()? == v.as_f64()?
}

fn test_zero_in_all_bases() {
	for src in ['v 0x0', 'v 0o0', 'v 0b0', 'v -0x0', 'v -0o0', 'v -0b0'] {
		assert regression_first(src)!.as_int()? == 0
	}
}

fn test_signed_and_dotted_identifiers() {
	assert kdl.parse('+..')!.nodes[0].name == '+..'
	assert kdl.parse('+.foo')!.nodes[0].name == '+.foo'
	doc := kdl.parse('+')!
	assert doc.nodes[0].name == '+'
	assert doc.nodes[0].arguments.len == 0
	assert kdl.parse('+abc')!.nodes[0].arguments.len == 0
}

fn test_whitespace_escape_in_quoted_string() {
	assert regression_first('v "a\\ b"')!.as_string()? == 'ab'
	assert regression_first('v "Hello\\   \nWorld"')!.as_string()? == 'HelloWorld'
}

fn test_string_node_names_and_keys() {
	doc := kdl.parse('#"my node"# "val"')!
	assert doc.nodes[0].name == 'my node'
	assert doc.nodes[0].arguments.len == 1
	doc2 := kdl.parse('(person)#"full name"# "Bob"')!
	assert doc2.nodes[0].ty? == 'person'
	assert doc2.nodes[0].name == 'full name'
	assert kdl.parse('"my\\"node" "val"')!.nodes[0].name == 'my"node'
	assert kdl.parse('"my\tname" "val"')!.nodes[0].name == 'my\tname'
	assert kdl.parse('node #"my key"#=42')!.nodes[0].prop('my key').as_int()? == 42
	assert kdl.parse('node "my key"="val"')!.nodes[0].prop('my key').as_string()? == 'val'
}

fn test_unicode_identifiers() {
	assert kdl.parse('名前 "value"')!.nodes[0].name == '名前'
	assert kdl.parse('café "val"')!.nodes[0].name == 'café'
}

fn test_bidi_controls_in_identifiers_rejected() {
	regression_rejects('n\u200eode')
	regression_rejects('n\u202aode')
	regression_rejects('n\u2066ode')
}

fn test_line_continuation_contexts() {
	doc := kdl.parse('parent {\n  child \\\n  "val"\n}')!
	assert doc.nodes[0].children.len == 1
	assert doc.nodes[0].children[0].name == 'child'
	assert doc.nodes[0].children[0].arguments.len == 1
	assert 'key' in kdl.parse('node \\\n  key="val"')!.nodes[0].properties
	for src in ['node \\ /* outer /* inner */ still */\n  arg1', 'node \\ /* block */\n  arg1'] {
		d := kdl.parse(src)!
		assert d.nodes.len == 1
		assert d.nodes[0].name == 'node'
		assert d.nodes[0].arguments.len == 1
	}
}

fn test_duplicate_property_keys_last_wins() {
	doc := kdl.parse('node a=1 a=#true a="str"')!
	assert doc.nodes[0].properties.len == 1
	assert doc.nodes[0].prop('a').as_string()? == 'str'
}

fn test_unterminated_block_comment_rejected() {
	regression_rejects('node /* unclosed')
}

fn test_deeply_nested_children() {
	for src, want in {
		'a{b{c{d{e{f}}}}}':                5
		'a{b{c{d{e{f{g{h{i{j{k}}}}}}}}}}': 10
	} {
		doc := kdl.parse(src)!
		mut node := doc.nodes[0]
		mut depth := 0
		for node.children.len > 0 {
			depth++
			node = node.children[0]
		}
		assert depth == want
	}
}

fn test_reserved_type_annotations_are_kept() {
	for src in ['node (date-time)"2024-01-01"', 'node (uuid)"550e8400-e29b-41d4-a716-446655440000"',
		'node (ipv4)"192.168.1.1"', 'node (url)"https://example.com"', 'node (email)"user@example.com"',
		'node (base64)"SGVsbG8="', 'node (regex)".*"', 'node (duration)"PT1H30M"',
		'node (currency)"USD"', 'node (hostname)"example.com"', 'node (decimal)"123.456"',
		'node (country-2)"US"', 'node (country-3)"USA"', 'node (url-template)"https://{host}/path"'] {
		doc := kdl.parse(src)!
		ty := doc.nodes[0].arg(0).ty?
		assert src.contains('(${ty})')
	}
	assert kdl.parse('(published)date "2024-01-01"')!.nodes[0].ty? == 'published'
}

fn test_keywords_are_case_sensitive() {
	regression_rejects('v #True')
	regression_rejects('v #TRUE')
	regression_rejects('v #Null')
	regression_rejects('v #NULL')
}

fn test_raw_strings_with_hashes() {
	assert regression_first('v ##" has """ inside "##')!.as_string()? == ' has """ inside '
	assert regression_first('v ##########"hello"##########')!.as_string()? == 'hello'
}

fn test_arguments_and_properties_are_separated() {
	doc := kdl.parse('node 1 key=val 2')!
	n := doc.nodes[0]
	assert n.arguments.len == 2
	assert n.arg(0).as_int()? == 1
	assert n.arg(1).as_int()? == 2
	assert n.prop('key').as_string()? == 'val'
}

fn test_colon_is_identifier_character() {
	doc := kdl.parse('node key:value')!
	assert doc.nodes[0].arguments.len == 1
	assert doc.nodes[0].properties.len == 0
	assert doc.nodes[0].arg(0).as_string()? == 'key:value'
}

fn test_identifier_ascii_punctuation() {
	for src in ['@name', 'a@b', 'a|b', "a'b", 'a`b', ':name', 'a:b'] {
		doc := kdl.parse(src)!
		assert doc.nodes.len == 1
		assert doc.nodes[0].name == src
		assert is_bare_identifier(src)
	}
}

fn test_bare_identifier_boundaries() {
	for src in ['+', '+.', '+.foo', '-', '-.foo', '.', '..'] {
		assert is_bare_identifier(src), src
	}
	for src in ['+.5', '-.5', '.5', 'a\u00a0b', 'a\u2028b', 'a\u200eb', 'a\x7fb'] {
		assert !is_bare_identifier(src), src
	}
}

fn test_invalid_escapes_rejected() {
	regression_rejects('node "a\\/b"')
	regression_rejects('node "a\\/* comment */b"')
}

fn test_u0080_round_trip() {
	doc := kdl.parse('node "\u0080 x"')!
	doc2 := kdl.parse(doc.str())!
	assert doc2.nodes[0].arg(0).as_string()? == '\u0080 x'
}

fn test_writer_keeps_u0080_and_escapes_u0085() {
	q0080 := kdl.Value{
		data: '\u0080 x'
	}.str()
	assert q0080 == '"\u0080 x"'
	q0085 := kdl.Value{
		data: '\u0085'
	}.str()
	assert q0085 == '"\\u{85}"'
	assert kdl.parse('node ' + q0085)!.nodes[0].arg(0).as_string()? == '\u0085'
}

fn test_entries_require_node_space() {
	regression_rejects('node"arg"')
	regression_rejects('node(u8)1')
	regression_rejects('node 1"arg"')
}

fn test_block_comment_with_newline_is_node_space() {
	doc := kdl.parse('node /*\n*/ arg')!
	assert doc.nodes.len == 1
	assert doc.nodes[0].arguments.len == 1
	assert doc.nodes[0].arg(0).as_string()? == 'arg'
}

fn test_negative_nan_is_identifier() {
	doc := kdl.parse('node -nan')!
	assert doc.nodes[0].arg(0).as_string()? == '-nan'
	assert doc.str().contains('-nan')
}

fn test_integers_outside_i64() {
	// The spec sets no range for numbers; this module keeps integers outside i64 exactly, as kdl.BigInt.
	doc := kdl.parse('v 9223372036854775808 -9223372036854775809 0x8000000000000000 -0x8000000000000001')!
	a := doc.nodes[0].arguments
	assert (a[0].data as kdl.BigInt).str() == '9223372036854775808'
	assert (a[1].data as kdl.BigInt).str() == '-9223372036854775809'
	assert (a[2].data as kdl.BigInt).str() == '9223372036854775808'
	assert (a[3].data as kdl.BigInt).str() == '-9223372036854775809'
	doc2 := kdl.parse('v -9223372036854775808 -0x8000000000000000 -0b1000000000000000000000000000000000000000000000000000000000000000 -0o1000000000000000000000')!
	for v in doc2.nodes[0].arguments {
		assert v.as_int()? == min_i64
	}
	assert kdl.parse(doc2.str())!.equals(doc2)
	assert kdl.parse(doc.str())!.equals(doc)
}

fn test_document_must_be_valid_utf8() {
	regression_rejects([u8(`v`), ` `, `"`, 0xff, `"`].bytestr())
}
