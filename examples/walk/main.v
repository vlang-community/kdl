// Parses a document and walks its tree: type annotations, arguments,
// properties and children, then writes it back in canonical form.
// Adapted from the parse_and_walk, type_annotations, slashdash_commenting and
// line_continuation examples of github.com/vlang-community/kdl by Jengro777.
// Run with: v run examples/walk/main.v
module main

import kdl

const source = '
// a package manifest
package {
    name my-app
    version "1.2.3"
    (date)released "2025-01-15"
    authors "Alice" \\
        "Bob" // an escaped newline continues the node
    dependencies {
        lib-a "^3.2" optional=#true
        /- lib-b "^1.0" // slashdash comments out a whole node
        lib-c (u16)8080 /- ignored=#true
    }
    scripts {
        build "v ."
        test "v test ."
    }
}
'

fn main() {
	doc := kdl.parse(source)!
	for node in doc.nodes {
		walk(node, 0)
	}
	println('--- canonical form ---')
	print(doc)
}

fn walk(node kdl.Node, depth int) {
	indent := '  '.repeat(depth)
	println('${indent}${annotated(node.ty, node.name)}')
	for arg in node.arguments {
		println('${indent}  arg ${describe(arg)}')
	}
	mut keys := node.properties.keys()
	keys.sort()
	for key in keys {
		println('${indent}  prop ${key} = ${describe(node.properties[key])}')
	}
	for child in node.children {
		walk(child, depth + 1)
	}
}

fn annotated(ty ?string, text string) string {
	if t := ty {
		return '(${t})${text}'
	}
	return text
}

fn describe(v kdl.Value) string {
	text := match v.data {
		string { 'string "${v.data}"' }
		i64 { 'integer ${v.data}' }
		f64 { 'float ${v.data}' }
		bool { 'boolean ${v.data}' }
		kdl.Null { 'null' }
		kdl.BigInt { 'big integer ${v.data}' }
	}
	return annotated(v.ty, text)
}
