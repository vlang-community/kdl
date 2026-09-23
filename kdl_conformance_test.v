module kdl

import os

// Runs the official KDL test suite, kdl-org/kdl `tests/test_cases` at commit
// 89c1087d5e7f530de328f18b6a0fad54ca8ea227, vendored in `tests/test_cases`
// under CC BY-SA 4.0 (see `tests/test_cases/LICENSE.md`).
// Every file of `input` must parse and re-serialise to the file of the same name
// in `expected_kdl`, unless its name ends with `_fail`: then it must be rejected.
// The canonical form drops comments, sorts properties, writes strings bare when
// possible and numbers in decimal; see the suite README for the full rules.

const suite_dir = os.join_path(os.dir(@FILE), 'tests', 'test_cases')

struct ConformanceCase {
	name      string
	input     string
	expected  string
	must_fail bool
}

fn load_suite() ![]ConformanceCase {
	mut files := os.ls(os.join_path(suite_dir, 'input'))!
	files.sort()
	mut cases := []ConformanceCase{cap: files.len}
	for file in files {
		if !file.ends_with('.kdl') {
			continue
		}
		name := file.all_before_last('.kdl')
		input := os.read_file(os.join_path(suite_dir, 'input', file))!
		if name.ends_with('_fail') {
			cases << ConformanceCase{
				name:      name
				input:     input
				must_fail: true
			}
		} else {
			cases << ConformanceCase{
				name:     name
				input:    input
				expected: os.read_file(os.join_path(suite_dir, 'expected_kdl', file))!
			}
		}
	}
	return cases
}

fn test_official_suite() {
	cases := load_suite()!
	assert cases.len == 338
	assert cases.filter(it.must_fail).len == 95
	mut failures := []string{}
	for c in cases {
		name := c.name
		doc := parse(c.input) or {
			if !c.must_fail {
				failures << '${name}: unexpected parse error: ${err.msg()}'
			}
			continue
		}
		if c.must_fail {
			failures << '${name}: should have been rejected'
			continue
		}
		// the suite writes an empty document as a single newline; the writer emits nothing
		expected := if c.expected == '\n' { '' } else { c.expected }
		actual := doc.str()
		if actual != expected && !same_modulo_floats(actual, expected) {
			failures << '${name}:\n    expected: ${expected.replace('\n', '\\n')}\n    actual:   ${actual.replace('\n', '\\n')}'
		}
	}
	for f in failures {
		eprintln(f)
	}
	assert failures.len == 0, '${failures.len} failures in the official suite'
}

// Every valid document of the suite must survive parse -> str -> parse.
fn test_roundtrip_official_suite() {
	mut checked := 0
	for c in load_suite()! {
		if c.must_fail {
			continue
		}
		name := c.name
		doc := parse(c.input) or { panic('${name}: ${err.msg()}') }
		text := doc.str()
		again := parse(text) or { panic('${name}: re-parse failed: ${err.msg()}\n${text}') }
		assert again.equals(doc), 'round trip changed ${name}'
		assert again.str() == text, 'second serialisation differs for ${name}'
		checked++
	}
	assert checked == 243
}

// same_modulo_floats compares two canonical documents token by token, allowing
// float tokens that differ only in notation (1.0E+10 vs 1E+10) or that overflow f64.
// Quoted strings are single tokens and must match exactly.
fn same_modulo_floats(a string, b string) bool {
	ta := canonical_tokens(a)
	tb := canonical_tokens(b)
	if ta.len != tb.len {
		return false
	}
	for i in 0 .. ta.len {
		if ta[i] == tb[i] {
			continue
		}
		pa, na := split_number_tail(ta[i])
		pb, nb := split_number_tail(tb[i])
		if pa != pb || !is_float_token(na) || !is_float_token(nb) {
			return false
		}
		fa := float_token(na)
		fb := float_token(nb)
		if fa != fb && !(fa == 0 && fb == 0) {
			return false
		}
	}
	return true
}

// canonical_tokens splits canonical KDL text on whitespace, keeping quoted
// strings (with their escapes) intact.
fn canonical_tokens(s string) []string {
	mut toks := []string{}
	mut i := 0
	for i < s.len {
		if s[i] == `\n` {
			// newlines terminate nodes: keep them so structure is compared too
			toks << '\n'
			i++
			continue
		}
		if s[i] == ` ` {
			i++
			continue
		}
		start := i
		mut in_quotes := false
		for i < s.len {
			c := s[i]
			if in_quotes {
				if c == `\\` {
					i += 2
					continue
				}
				if c == `"` {
					in_quotes = false
				}
			} else if c == `"` {
				in_quotes = true
			} else if c == ` ` || c == `\n` {
				break
			}
			i++
		}
		toks << s[start..i]
	}
	return toks
}

fn test_canonical_tokens_respect_quotes() {
	assert canonical_tokens('n "a  b" k="x y" 1.0\n') == ['n', '"a  b"', 'k="x y"', '1.0', '\n']
	// structure: node boundaries and children blocks must match
	assert !same_modulo_floats('n\nm\n', 'n m\n')
	assert !same_modulo_floats('n {\n    m\n}\n', 'n m\n')
	assert !same_modulo_floats('n {\n    m\n}\n', 'n\nm\n')
	assert !same_modulo_floats('n {\n    m\n    o\n}\n', 'n {\n    m {\n        o\n    }\n}\n')
	assert same_modulo_floats('n 1.0 {\n    m 2.0\n}\n', 'n 1.00 {\n    m 2.00\n}\n')
	assert !same_modulo_floats('n "a  b"\n', 'n "a b"\n')
	assert !same_modulo_floats('n "a 1.0000000000000001 b"\n', 'n "a 1.0 b"\n')
	assert !same_modulo_floats('n 1.5\n', 'n 1.6\n')
	assert same_modulo_floats('n 1.0E+10 k=(t)2.5E+10\n', 'n 1E+10 k=(t)2.5e10\n')
	// numbers inside strings are strings: no tolerance
	assert !same_modulo_floats('n "a=1.0000000000000001"\n', 'n "a=1.0"\n')
	assert !same_modulo_floats('n "(t)1.0000000000000001"\n', 'n "(t)1.0"\n')
	assert !same_modulo_floats('n k="1.0000000000000001"\n', 'n k="1.0"\n')
	assert !same_modulo_floats('n "1.0000000000000001"\n', 'n "1.0"\n')
	assert !same_modulo_floats('n 1.0000000000000001x\n', 'n 1.0x\n')
	assert !same_modulo_floats('n 10\n', 'n 10.0\n')
	assert same_modulo_floats('n "a=b"=1.0\n', 'n "a=b"=1.00\n')
}

fn split_number_tail(tok string) (string, string) {
	mut i := tok.len - 1
	for i >= 0 && tok[i] !in [u8(`=`), `)`] {
		i--
	}
	return tok[..i + 1], tok[i + 1..]
}

// Floats outside the f64 range are stored as infinity, so `#inf` may stand for
// a huge literal such as 1.23E+1000.
fn is_float_token(s string) bool {
	if s == '#inf' || s == '#-inf' {
		return true
	}
	if s.len == 0 || !looks_like_number(s) {
		return false
	}
	// the whole token must be a float according to the number grammar, so a
	// quote or any other trailing character disqualifies it
	d := parse_number(s) or { return false }
	return d is f64
}

fn float_token(s string) f64 {
	return match s {
		'#inf' { f64_inf }
		'#-inf' { -f64_inf }
		else { s.f64() }
	}
}
