// Adapted from tests/format_test.v and tests/document_test.v of github.com/vlang-community/kdl
// at commit 721a303, by Jengro777.
module main

import kdl

fn format_round_trips(doc kdl.Document) !kdl.Document {
	back := kdl.parse(doc.str())!
	assert back.equals(doc), doc.str()
	return back
}

fn test_format_roundtrip_basic() {
	doc := kdl.parse('my-node 1 2 key="val"')!
	assert doc.str() == 'my-node 1 2 key=val\n'
	format_round_trips(doc)!
}

fn test_format_roundtrip_complex() {
	src := 'package {\n  name my-pkg\n  version "1.2.3"\n  dependencies {\n    lodash "^3.2.1" optional=#true alias=underscore\n  }\n}'
	doc := kdl.parse(src)!
	back := format_round_trips(doc)!
	assert back.nodes.len == 1
	assert back.nodes[0].name == 'package'
	assert back.nodes[0].children.len == 3
}

fn test_format_empty_document() {
	assert kdl.parse('')!.str() == ''
}

fn test_format_children() {
	doc := kdl.parse('parent {\n  child "val"\n}')!
	assert doc.str() == 'parent {\n    child val\n}\n'
	format_round_trips(doc)!
}

fn test_document_manual_construction() {
	mut config := kdl.Node{
		name: 'config'
	}
	config.properties['host'] = kdl.Value{
		data: 'localhost'
	}
	config.properties['port'] = kdl.Value{
		data: i64(8080)
	}
	config.children << kdl.Node{
		name:       'logging'
		properties: {
			'level': kdl.Value{
				data: 'info'
			}
		}
	}
	doc := kdl.Document{
		nodes: [config]
	}
	out := doc.str()
	assert out == 'config host=localhost port=8080 {\n    logging level=info\n}\n'
	format_round_trips(doc)!
}

fn test_parse_error_message() {
	e := kdl.ParseError{
		line:    1
		col:     10
		offset:  0
		message: 'error'
	}
	assert e.message == 'error'
	assert e.msg() == '1:10: error'
}

fn test_write_quoted_escapes_controls() {
	for s in ['\x01', '\x7f'] {
		mut node := kdl.Node{
			name: 'x'
		}
		node.properties['v'] = kdl.Value{
			data: s
		}
		doc := kdl.Document{
			nodes: [node]
		}
		out := doc.str()
		assert !out.contains(s)
		// DEL is escaped exactly once
		assert out.count('\\u{') == 1
		format_round_trips(doc)!
	}
}

fn test_write_quoted_c1_control_roundtrip() {
	mut node := kdl.Node{
		name: 'x'
	}
	node.properties['v'] = kdl.Value{
		data: '\u0080'
	}
	doc := kdl.Document{
		nodes: [node]
	}
	back := format_round_trips(doc)!
	assert back.nodes[0].prop('v').as_string()? == '\u0080'
}

fn test_value_kinds() {
	doc := kdl.parse('v "str" 42 3.14 #true #false #null')!
	a := doc.nodes[0].arguments
	assert a.len == 6
	assert a[0].data is string
	assert a[1].data is i64
	assert a[2].data is f64
	assert a[3].data is bool
	assert a[4].data is bool
	assert a[5].is_null()
	assert a.map(it.str()) == ['str', '42', '3.14', '#true', '#false', '#null']
}

fn test_node_property_helpers() {
	n := kdl.parse('config port=8080 host="localhost"')!.nodes[0]
	assert 'port' in n.properties
	assert 'missing' !in n.properties
	assert n.properties.len > 0
	assert n.prop('port').as_int()? == 8080
	assert n.prop('host').as_string()? == 'localhost'
}
