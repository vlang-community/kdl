// Adapted from tests/roundtrip_fuzz_test.v of github.com/vlang-community/kdl
// at commit 721a303, by Jengro777.
module kdl

import rand

fn test_roundtrip_fuzz() {
	// fixed seed for reproducibility
	mut rng := rand.new_default()
	rng.seed([u32(20260716), u32(7)])
	for i in 0 .. 100 {
		src := fuzz_document(mut rng)
		doc := parse(src) or {
			assert false, 'iter ${i}: generated source does not parse: ${err.msg()}\n${src}'
			return
		}
		formatted := doc.str()
		back := parse(formatted) or {
			assert false, 'iter ${i}: could not re-parse formatted output: ${err.msg()}\nOriginal: ${src}\nFormatted: ${formatted}'
			return
		}
		assert back.equals(doc), 'iter ${i}: round trip changed the document\nOriginal: ${src}\nFormatted: ${formatted}'
		assert back.str() == formatted, 'iter ${i}: formatting is not stable'
	}
}

fn fuzz_document(mut rng rand.PRNG) string {
	mut s := ''
	for _ in 0 .. rng.int_in_range(1, 5) or { 2 } {
		s += fuzz_node(mut rng, 0) + '\n'
	}
	return s
}

fn fuzz_node(mut rng rand.PRNG, depth int) string {
	mut s := fuzz_pick(mut rng, fuzz_names[..])
	if rng.int_in_range(0, 4) or { 0 } == 0 {
		s = '(${fuzz_pick(mut rng, fuzz_types[..])})' + s
	}
	for _ in 0 .. rng.int_in_range(0, 5) or { 2 } {
		if rng.int_in_range(0, 3) or { 0 } == 0 {
			s += ' ${fuzz_pick(mut rng, fuzz_names[..])}=${fuzz_value(mut rng)}'
		} else {
			s += ' ' + fuzz_value(mut rng)
		}
	}
	if depth < 3 && rng.int_in_range(0, 3) or { 0 } == 0 {
		s += ' {\n'
		for _ in 0 .. rng.int_in_range(0, 3) or { 1 } {
			s += '\t' + fuzz_node(mut rng, depth + 1) + '\n'
		}
		s += '}'
	}
	return s
}

const fuzz_names = ['node', 'config', 'server', 'person', 'item', 'data', 'entry', 'log', 'test',
	'value', 'x', 'my-node', 'foo_bar', 'baz-qux']!
const fuzz_types = ['u8', 'i32', 'f64', 'string', 'bool', 'date-time', 'uuid', 'person', 'url',
	'hex', 'color']!

fn fuzz_pick(mut rng rand.PRNG, list []string) string {
	return list[rng.int_in_range(0, list.len) or { 0 }]
}

fn fuzz_value(mut rng rand.PRNG) string {
	return match rng.int_in_range(0, 7) or { 0 } {
		0 {
			fuzz_pick(mut rng, ['"hello"', '"world"', '"test value"', '"a"', '"flag"'])
		}
		1 {
			fuzz_pick(mut rng, ['0', '1', '42', '-7', '100', '0xFF', '0o77', '0b1010', '1_000',
				'0xFF_FF', '-0o10'])
		}
		2 {
			fuzz_pick(mut rng, ['3.14', '-2.5', '1.0e10', '2e-3', '-1.5e2'])
		}
		3 {
			fuzz_pick(mut rng, ['#true', '#false'])
		}
		4 {
			'#null'
		}
		5 {
			fuzz_pick(mut rng, ['#"raw"#', '##"rawer"##'])
		}
		else {
			'"default"'
		}
	}
}
