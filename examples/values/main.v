// Shows how every kind of KDL value is read: numbers in all bases, strings in
// all forms, booleans, null and the float keywords.
// Adapted from the number_formats, string_values and booleans_and_null
// examples of github.com/vlang-community/kdl by Jengro777.
// Run with: v run examples/values/main.v
module main

import kdl

const source = '
integers 42 -17 +99 0xFF 0o77 0b1010 1_000_000 18446744073709551616
floats 3.14 1e10 1.5e-3 -0.5 #inf #-inf #nan
strings bare "quoted\\ttab" #"raw \\n stays"# """
    multi-line strings
    lose their common indentation
    """
keywords #true #false #null
'

fn main() {
	doc := kdl.parse(source)!
	for node in doc.nodes {
		println('${node.name}:')
		for v in node.arguments {
			println('  ${kind(v)}: ${show(v)}')
		}
	}
	// the typed accessors return none for another type, so `or` gives a default
	ints := doc.get('integers') or { panic('no integers node') }
	println('as_int: ${ints.arg(3).as_int() or { -1 }}, as_f64: ${ints.arg(3).as_f64() or { -1.0 }}')
	println('an integer is not a string: ${ints.arg(0).as_string() or { 'none' }}')
}

fn kind(v kdl.Value) string {
	return match v.data {
		string { 'string' }
		i64 { 'i64' }
		f64 { 'f64' }
		bool { 'bool' }
		kdl.Null { 'null' }
		kdl.BigInt { 'BigInt' }
	}
}

fn show(v kdl.Value) string {
	return match v.data {
		string { '${v.data}'.replace('\n', '\\n').replace('\t', '\\t') }
		else { v.str() }
	}
}
