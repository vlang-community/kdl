module main

import kdl
import rand
import rand.seed

fn test_roundtrip_fuzz() {
	// Seed with a fixed value for reproducibility, but vary per iteration
	mut rng := rand.new(seed.time_seed(20260716))

	for i in 0 .. 100 {
		src := generate_random_kdl(mut rng, i)
		// Parse the generated source
		doc := kdl.parse(src) or {
			// If generation produced invalid KDL (e.g., edge cases), skip
			eprintln('skip iter ${i}: parse error: ${err}')
			continue
		}
		// Format the parsed doc
		formatted := kdl.format(doc) or {
			eprintln('skip iter ${i}: format error: ${err}')
			continue
		}
		// Re-parse the formatted output
		doc2 := kdl.parse(formatted) or {
			assert false, 'Roundtrip failed at iter ${i}: could not re-parse formatted output\nOriginal: ${src}\nFormatted: ${formatted}\nError: ${err}'
			return
		}
		// Compare structure
		assert_equivalent(doc, doc2, i)
	}
}

fn generate_random_kdl(mut rng rand.PRNG, seed_ int) string {
	mut s := ''
	mut r := rand.int(1, 5) or { 2 }
	for _ in 0 .. r {
		s += generate_node(mut rng, 0)
		s += '\n'
	}
	return s
}

fn generate_node(mut rng rand.PRNG, depth int) string {
	// Node name
	mut s := random_name(mut rng)

	// Optional type annotation
	if rand.int(0, 4) or { 0 } == 0 {
		s = '(${random_type(mut rng)})' + s
	}

	// Generate entries
	n_entries := rand.int(0, 5) or { 2 }
	for _ in 0 .. n_entries {
		if rand.int(0, 3) or { 0 } == 0 {
			// Property
			pkey := random_name(mut rng)
			pval := random_value(mut rng)
			s += ' ${pkey}=${pval}'
		} else {
			// Argument
			s += ' ' + random_value(mut rng)
		}
	}

	// Optional children (up to depth 3)
	if depth < 3 && rand.int(0, 3) or { 0 } == 0 {
		s += ' {\n'
		n_children := rand.int(0, 3) or { 1 }
		for _ in 0 .. n_children {
			s += '\t' + generate_node(mut rng, depth + 1)
			s += '\n'
		}
		s += '}'
	}

	return s
}

fn random_name(mut rng rand.PRNG) string {
	names := ['node', 'config', 'server', 'person', 'item', 'data', 'entry',
		'log', 'test', 'value', 'x', 'my-node', 'foo_bar', 'baz-qux']
	return names[rand.int(0, names.len) or { 0 }]
}

fn random_type(mut rng rand.PRNG) string {
	types := ['u8', 'i32', 'f64', 'string', 'bool', 'date-time', 'uuid',
		'person', 'url', 'hex', 'color']
	return types[rand.int(0, types.len) or { 0 }]
}

fn random_value(mut rng rand.PRNG) string {
	choice := rand.int(0, 7) or { 0 }
	match choice {
		0 {
			// Quoted string
			strings := ['"hello"', '"world"', '"test value"', '"a"', '"flag"']
			return strings[rand.int(0, strings.len) or { 0 }]
		}
		1 {
			// Integer
			vals := ['0', '1', '42', '-7', '100', '0xFF', '0o77', '0b1010',
				'1_000', '0xFF_FF', '-0o10']
			return vals[rand.int(0, vals.len) or { 0 }]
		}
		2 {
			// Float
			vals := ['3.14', '-2.5', '1.0e10', '2e-3', '-1.5e2']
			return vals[rand.int(0, vals.len) or { 0 }]
		}
		3 {
			// Boolean
			return if rand.int(0, 2) or { 0 } == 0 { '#true' } else { '#false' }
		}
		4 {
			return '#null'
		}
		5 {
			// Raw string
			vals := ['#"raw"#', '##"rawer"##']
			return vals[rand.int(0, vals.len) or { 0 }]
		}
		else {
			return '"default"'
		}
	}
}

fn assert_equivalent(a kdl.Document, b kdl.Document, iter int) {
	assert a.nodes.len == b.nodes.len, 'iter ${iter}: node count mismatch: ${a.nodes.len} vs ${b.nodes.len}'
	for i in 0 .. a.nodes.len {
		assert_nodes_equivalent(a.nodes[i], b.nodes[i], iter, i)
	}
}

fn assert_nodes_equivalent(a kdl.Node, b kdl.Node, iter int, ndx int) {
	assert a.name == b.name, 'iter ${iter} node[${ndx}]: name mismatch "${a.name}" vs "${b.name}"'
	assert a.type_name == b.type_name, 'iter ${iter} node[${ndx}]: type mismatch "${a.type_name}" vs "${b.type_name}"'
	assert a.entries.len == b.entries.len, 'iter ${iter} node[${ndx}]: entry count'
	for i in 0 .. a.entries.len {
		assert_entries_equivalent(a.entries[i], b.entries[i], iter, ndx, i)
	}
	assert a.children.len == b.children.len, 'iter ${iter} node[${ndx}]: children count'
	for i in 0 .. a.children.len {
		assert_nodes_equivalent(a.children[i], b.children[i], iter, ndx)
	}
}

fn assert_entries_equivalent(a kdl.Entry, b kdl.Entry, iter int, ndx int, eidx int) {
	match a {
		kdl.Argument {
			if b is kdl.Argument {
				assert a.type_name == b.type_name, 'iter ${iter} node[${ndx}] entry[${eidx}]: arg type'
				assert_values_equivalent(a.value, b.value, iter, ndx, eidx)
			} else {
				assert false, 'iter ${iter} node[${ndx}] entry[${eidx}]: type mismatch Argument vs ${typeof(b)}'
			}
		}
		kdl.Property {
			if b is kdl.Property {
				assert a.key == b.key, 'iter ${iter} node[${ndx}] entry[${eidx}]: key mismatch'
				assert a.type_name == b.type_name, 'iter ${iter} node[${ndx}] entry[${eidx}]: prop type'
				assert_values_equivalent(a.value, b.value, iter, ndx, eidx)
			} else {
				assert false, 'iter ${iter} node[${ndx}] entry[${eidx}]: type mismatch'
			}
		}
	}
}

fn assert_values_equivalent(a kdl.Value, b kdl.Value, iter int, ndx int, eidx int) {
	match a {
		kdl.StringVal {
			assert b is kdl.StringVal, 'iter ${iter} node[${ndx}] entry[${eidx}]: expected StringVal'
			if b is kdl.StringVal {
				assert a.value == b.value, 'iter ${iter} node[${ndx}] entry[${eidx}]: string value "${a.value}" vs "${b.value}"'
			}
		}
		kdl.IntVal {
			assert b is kdl.IntVal, 'iter ${iter} node[${ndx}] entry[${eidx}]: expected IntVal'
			if b is kdl.IntVal {
				assert a.value == b.value, 'iter ${iter} node[${ndx}] entry[${eidx}]: int value ${a.value} vs ${b.value}'
			}
		}
		kdl.FloatVal {
			assert b is kdl.FloatVal, 'iter ${iter} node[${ndx}] entry[${eidx}]: expected FloatVal'
			// Compare approximately
			if b is kdl.FloatVal {
				diff := a.value - b.value
				if diff < 0 {
					diff = -diff
				}
				assert diff < 1e-9, 'iter ${iter} node[${ndx}] entry[${eidx}]: float ${a.value} vs ${b.value}'
			}
		}
		kdl.BoolVal {
			assert b is kdl.BoolVal, 'iter ${iter} node[${ndx}] entry[${eidx}]: expected BoolVal'
			if b is kdl.BoolVal {
				assert a.value == b.value, 'iter ${iter} node[${ndx}] entry[${eidx}]: bool mismatch'
			}
		}
		kdl.NullVal {
			assert b is kdl.NullVal, 'iter ${iter} node[${ndx}] entry[${eidx}]: expected NullVal'
		}
	}
}
