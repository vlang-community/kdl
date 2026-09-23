// Adapted from tests/tokenizer_test.v of github.com/vlang-community/kdl
// at commit 721a303, by Jengro777.
module kdl

fn syntax_rejects(src string) {
	parse(src) or { return }
	assert false, 'expected parse error for ${src}'
}

// syntax_first parses a document made of one node with one argument and returns it.
fn syntax_first(src string) !Value {
	doc := parse(src)!
	if doc.nodes.len != 1 || doc.nodes[0].arguments.len != 1 {
		return error('expected one node with one argument: ${src}')
	}
	return doc.nodes[0].arguments[0]
}

fn test_parse_single_node() {
	doc := parse('my-node')!
	assert doc.nodes.len == 1
	assert doc.nodes[0].name == 'my-node'
	assert doc.nodes[0].arguments.len == 0
	assert doc.nodes[0].properties.len == 0
}

fn test_parse_node_arguments() {
	doc := parse('name "Alice"')!
	assert doc.nodes[0].name == 'name'
	assert doc.nodes[0].arguments.len == 1
	doc2 := parse('nums 1 2 3 4')!
	assert doc2.nodes[0].arguments.map(it.as_int()?) == [i64(1), 2, 3, 4]
	doc3 := parse('v 1 2 3 a b c')!
	assert doc3.nodes[0].arguments.len == 6
}

fn test_parse_node_properties() {
	doc := parse('config port=8080')!
	assert doc.nodes[0].name == 'config'
	assert doc.nodes[0].prop('port').as_int()? == 8080
	doc2 := parse('config host="localhost" port=8080 debug=#true')!
	assert doc2.nodes[0].properties.len == 3
	doc3 := parse('node 1 key=val 2')!
	assert doc3.nodes[0].arguments.len == 2
	assert doc3.nodes[0].properties.len == 1
}

fn test_value_strings() {
	assert syntax_first('v "hello world"')!.as_string()? == 'hello world'
	assert syntax_first('v hello')!.as_string()? == 'hello'
}

fn test_value_integers() {
	for src, want in {
		'v 42':       i64(42)
		'v -17':      -17
		'v +17':      17
		'v 0xFF':     255
		'v 07':       7
		'v +07':      7
		'v -0xFF':    -255
		'v -0o10':    -8
		'v -0b1010':  -10
		'v +0xFF':    255
		'v +0o77':    63
		'v 0xFF__FF': 65535
		'v 0xFF_':    255
		'v 0o77_':    63
		'v 0b10_':    2
		'v -0xFF_FF': -65535
		'v -0o7_7':   -63
		'v -0b1_0':   -2
		'v +0xFF_FF': 65535
		'v +1_000':   1000
	} {
		assert syntax_first(src)!.as_int()? == want, src
	}
}

fn test_value_floats() {
	assert syntax_first('v 3.14')!.as_f64()? == 3.14
	for src, want in {
		'v 1e10':    1e10
		'v 1.5e-3':  0.0015
		'v 0e+5':    0.0
		'v 1.5e+10': 1.5e10
		'v 1e+3':    1000.0
		'v 1e0':     1.0
		'v 1E0':     1.0
		'v 1e-0':    1.0
		'v 1e+0':    1.0
		'v 0e10':    0.0
		'v +1e5':    100000.0
	} {
		v := syntax_first(src)!
		assert v.data is f64, src
		assert v.as_f64()? == want, src
	}
}

fn test_value_keywords() {
	assert syntax_first('v #true')!.as_bool()? == true
	assert syntax_first('v #false')!.as_bool()? == false
	assert syntax_first('v #null')!.is_null()
	doc := parse('v #inf #-inf #nan')!
	a := doc.nodes[0].arguments
	assert a[0].as_f64()? == f64_inf
	assert a[1].as_f64()? == -f64_inf
	nan := a[2].as_f64()?
	assert nan != nan
}

fn test_bare_keywords_rejected() {
	for src in ['node true', 'node false', 'node null', 'node inf', 'node -inf', 'node nan', 'v true'] {
		syntax_rejects(src)
	}
	for src in ['v #Inf', 'v #+inf', 'v #+nan'] {
		syntax_rejects(src)
	}
}

fn test_children() {
	assert parse('node {}')!.nodes[0].children.len == 0
	doc := parse('parent { child "val" }')!
	assert doc.nodes[0].children.len == 1
	assert doc.nodes[0].children[0].name == 'child'
	assert parse('parent {\n  child1 "a"\n  child2 "b"\n}')!.nodes[0].children.len == 2
	doc2 := parse('a {\n  b {\n    c "deep"\n  }\n}')!
	assert doc2.nodes[0].children[0].children[0].name == 'c'
	doc3 := parse('a { b }\nc { d }')!
	assert doc3.nodes.len == 2
	assert doc3.nodes[0].children.len == 1
	assert doc3.nodes[1].children.len == 1
}

fn test_semicolons() {
	assert parse('parent { a "1"; b "2"; c "3" }')!.nodes[0].children.len == 3
	assert parse('a; b; c')!.nodes.len == 3
	assert parse('parent { a; b; c }')!.nodes[0].children.len == 3
}

fn test_comments() {
	assert parse('/* outer /* inner */ still */ node "val"')!.nodes[0].name == 'node'
	doc := parse('/* /* /* inner */ still */ out */ node "val"')!
	assert doc.nodes.len == 1
	assert doc.nodes[0].name == 'node'
	assert parse('\ufeff// \u30b3\u30e1\u30f3\u30c8\nnode "val"')!.nodes[0].name == 'node'
}

fn test_slashdash() {
	assert parse('node /- 1 2 3')!.nodes[0].arguments.len == 2
	doc := parse('node a=1 /- b=2 c=3')!
	node := doc.nodes[0]
	assert 'a' in node.properties
	assert 'b' !in node.properties
	assert 'c' in node.properties
}

fn test_line_continuation() {
	assert parse('node \\\n  arg1 arg2')!.nodes[0].arguments.len == 2
	assert parse('node \\ // comment\n  arg1')!.nodes[0].arguments.len == 1
	doc := parse('node \\\n\\\n  arg')!
	assert doc.nodes.len == 1
	assert doc.nodes[0].arguments.len == 1
}

fn test_type_annotations() {
	doc := parse('(person)node "name"')!
	assert doc.nodes[0].ty? == 'person'
	assert doc.nodes[0].name == 'node'
	assert syntax_first('node (u8)123')!.ty? == 'u8'
	syntax_rejects('(   )node "val"')
}

fn test_empty_documents() {
	syntax_rejects('[')
	for src in ['', '   \n  \n  ', '// comment\n/* block */'] {
		assert parse(src)!.nodes.len == 0
	}
}

fn test_multiple_top_level_nodes() {
	assert parse('node1 "a"\nnode2 "b"\nnode3 "c"')!.nodes.len == 3
	assert parse('my-node\n--flag\n.hidden')!.nodes.map(it.name) == ['my-node', '--flag', '.hidden']
}

fn test_spec_examples() {
	src := 'package {\n  name my-pkg\n  version "1.2.3"\n  dependencies {\n    lodash "^3.2.1" optional=#true alias=underscore\n  }\n}'
	doc := parse(src)!
	assert doc.nodes[0].name == 'package'
	assert doc.nodes[0].children.len == 3
	lodash := doc.nodes[0].children[2].children[0]
	assert lodash.arg(0).as_string()? == '^3.2.1'
	assert lodash.prop('optional').as_bool()? == true
	assert lodash.prop('alias').as_string()? == 'underscore'
	ci := 'pipeline {\n  build {\n    image "rust:latest"\n    script "cargo build --release"\n  }\n  test {\n    image "rust:latest"\n    script "cargo test"\n  }\n}'
	assert parse(ci)!.nodes[0].children.len == 2
}

fn test_identifiers() {
	for name in ['+enabled', '.hidden', '-', '.', '..', '+..', '+.foo', '-.foo', '~tilde', '!bang',
		'%percent', '^caret', '&amp', '*star', '<angle', '>angle', 'True', 'Null', '_12', 'a,b'] {
		doc := parse(name)!
		assert doc.nodes.len == 1
		assert doc.nodes[0].name == name
	}
	for src in ['node +inf', 'node +nan', 'node key:value'] {
		doc := parse(src)!
		assert doc.nodes.len == 1
		assert doc.nodes[0].name == 'node'
		assert doc.nodes[0].arg(0).as_string()? == src.all_after(' ')
	}
}

fn test_signed_numbers_are_not_identifiers() {
	assert syntax_first('node +42')!.as_int()? == 42
	assert syntax_first('node -42')!.as_int()? == -42
	syntax_rejects('+.5')
	syntax_rejects('-.5')
}

fn test_invalid_identifiers() {
	syntax_rejects('a#b')
	syntax_rejects('a\\b')
}

fn test_invalid_numbers() {
	for src in ['v 0x_FF', 'v 0o_77', 'v 0b_10', 'v 0x_', 'v 0o_', 'v 0b_', 'v 0x_1a', 'v 0o_17',
		'v .5', 'v 1.', 'v 1e+', 'v 1._0', 'timeout 10ms', 'dist 3.5km'] {
		syntax_rejects(src)
	}
}

fn test_negative_radix_round_trip() {
	for src, want in {
		'v -0xFF': i64(-255)
		'v -0o10': -8
	} {
		doc := parse(src)!
		back := parse(doc.str())!
		assert back.nodes[0].arg(0).as_int()? == want
	}
}

fn test_quoted_node_names() {
	doc := parse('"my node" 8080')!
	assert doc.nodes[0].name == 'my node'
	assert doc.nodes[0].arguments.len == 1
	doc2 := parse('"server config" port=8080 host="localhost"')!
	assert doc2.nodes[0].name == 'server config'
	assert doc2.nodes[0].properties.keys().len == 2
}
