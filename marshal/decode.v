module kdl

import math

fn (mut ctx MarshalContext) decode_struct[T](mut out T, args []Value, props map[string]Value, children []Node, doc_level bool, path string) ! {
	spec := ctx.types[typeof[T]().idx * 2 + int(doc_level)] or {
		return marshal_error(.unsupported, path, 'no schema prepared for ${typeof[T]().name}')
	}
	mut next_arg := 0
	mut i := 0
	$for field in T.fields {
		f := spec.fields[i]
		i++
		if !f.skip {
			fpath := join_path(path, f.name)
			$if field.is_option {
				// two steps, with no generic-typed binding in this loop: the old V
				// compiler gives such a binding the type of the first field
				state, v, idx := option_entry(f, props, children, doc_level, fpath)!
				if state == .null {
					out.$(field.name) = none
				} else if state == .value {
					out.$(field.name) = ctx.decode_option(out.$(field.name), v, idx, children,
						fpath)!
				}
			} $else {
				match f.role {
					.arg {
						if next_arg < args.len {
							out.$(field.name) = from_value(out.$(field.name), args[next_arg],
								fpath)!
						}
						next_arg++
					}
					.args {
						$if field.typ is $array_fixed {
						} $else $if field.is_array {
							rest := if next_arg < args.len { args[next_arg..] } else { []Value{} }
							out.$(field.name) = list_from_values(out.$(field.name), rest, fpath)!
						}
						next_arg = args.len
					}
					.props {
						$if field.is_map {
							out.$(field.name) = collect_props(out.$(field.name), props,
								spec.prop_names, fpath)!
						}
					}
					else {
						ctx.decode_field(mut out.$(field.name), f, props, children, doc_level,
							fpath)!
					}
				}
			}
		}
	}
	if next_arg < args.len {
		return marshal_error(.unexpected, path, 'unexpected argument ${next_arg + 1}: ${args[next_arg]}')
	}
}

fn (mut ctx MarshalContext) decode_field[F](mut out F, f FieldSpec, props map[string]Value, children []Node, doc_level bool, path string) ! {
	$if F is $array_fixed {
		// rejected by prepare; kept out of the array branch, which does not compile for it
	} $else $if F is $array {
		ctx.decode_list(mut out, f.name, children, path)!
	} $else $if F is $map {
		idx := find_child(children, f.name, path)!
		if idx >= 0 {
			expect_only(&children[idx], false, true, false, path)!
			out = collect_props(out, children[idx].properties, map[string]bool{}, path)!
		}
	} $else $if F is string || F is bool || F is $int || F is $float || F is $enum {
		found, v := scalar_entry(f, props, children, doc_level, path)!
		if found {
			out = from_value(out, v, path)!
		}
	} $else $if F is $struct {
		idx := find_child(children, f.name, path)!
		if idx >= 0 {
			child := &children[idx]
			ctx.decode_struct(mut out, child.arguments, child.properties, child.children,
				false, path)!
		}
	}
}

// OptionState is what option_entry found for an option field.
enum OptionState {
	absent
	null
	value
}

// option_entry finds the entry of an option field: for a scalar its value, for
// a struct the index of its child node (`#null` alone in that node means null).
fn option_entry(f FieldSpec, props map[string]Value, children []Node, doc_level bool, path string) !(OptionState, Value, int) {
	if f.kind == .opt_scalar {
		found, v := scalar_entry(f, props, children, doc_level, path)!
		if !found {
			return OptionState.absent, Value{}, -1
		}
		if v.is_null() {
			return OptionState.null, v, -1
		}
		return OptionState.value, v, -1
	}
	idx := find_child(children, f.name, path)!
	if idx < 0 {
		return OptionState.absent, Value{}, -1
	}
	child := &children[idx]
	if child.arguments.len == 1 && child.arguments[0].is_null() && child.properties.len == 0
		&& child.children.len == 0 {
		return OptionState.null, Value{}, idx
	}
	return OptionState.value, Value{}, idx
}

// decode_option converts what option_entry found into the payload of the option.
fn (mut ctx MarshalContext) decode_option[E](current ?E, v Value, idx int, children []Node, path string) !E {
	$if E is string || E is bool || E is $int || E is $float || E is $enum {
		return from_value(E{}, v, path)!
	} $else $if E is $struct {
		child := &children[idx]
		// a struct held by the option keeps its own defaults, like a plain struct field
		mut out := seed_of(current)
		ctx.decode_struct(mut out, child.arguments, child.properties, child.children,
			false, path)!
		return out
	} $else {
		return E{}
	}
}

// seed_of returns the struct held by an option, or a default-initialized one for `none`. A
// separate function: the old compiler does not parse an `or` block inside a
// comptime branch, and an if-let on the option mis-instantiates generics.
fn seed_of[E](current ?E) E {
	return current or { E{} }
}

// scalar_entry returns the value of a scalar field: a property, or the only
// argument of a child node at the top level or with the `child` tag.
fn scalar_entry(f FieldSpec, props map[string]Value, children []Node, doc_level bool, path string) !(bool, Value) {
	if !doc_level && f.role != .as_child {
		v := props[f.name] or { return false, Value{} }
		return true, v
	}
	idx := find_child(children, f.name, path)!
	if idx < 0 {
		return false, Value{}
	}
	child := &children[idx]
	expect_only(child, true, false, false, path)!
	if child.arguments.len != 1 {
		return marshal_error(.unexpected, path, 'expected one argument, got ${child.arguments.len}')
	}
	return true, child.arguments[0]
}

// find_child returns the index of the only child named `name`, or -1.
fn find_child(children []Node, name string, path string) !int {
	mut found := -1
	for i in 0 .. children.len {
		if children[i].name == name {
			if found >= 0 {
				return marshal_error(.duplicate, path, 'node `${name}` appears more than once')
			}
			found = i
		}
	}
	return found
}

// expect_only rejects the parts of `node` that the field does not read.
fn expect_only(node &Node, args bool, props bool, children bool, path string) ! {
	if !args && node.arguments.len > 0 {
		return marshal_error(.unexpected, path, 'unexpected argument ${node.arguments[0]}')
	}
	if !props && node.properties.len > 0 {
		mut keys := node.properties.keys()
		keys.sort()
		return marshal_error(.unexpected, path, 'unexpected property `${keys[0]}`')
	}
	if !children && node.children.len > 0 {
		return marshal_error(.unexpected, path, 'unexpected child node `${node.children[0].name}`')
	}
}

// decode_list replaces `out` when the document has the list, and keeps its
// default value otherwise.
fn (mut ctx MarshalContext) decode_list[E](mut out []E, name string, children []Node, path string) ! {
	$if E is string || E is bool || E is $int || E is $float || E is $enum {
		idx := find_child(children, name, path)!
		if idx >= 0 {
			child := &children[idx]
			expect_only(child, true, false, false, path)!
			out = list_from_values(out, child.arguments, path)!
		}
	} $else $if E is $struct {
		mut found := false
		for i in 0 .. children.len {
			child := &children[i]
			if child.name == name {
				if !found {
					out.clear()
					found = true
				}
				// decoded in place: pushing a filled local struct would copy it
				out << E{}
				ctx.decode_struct(mut out[out.len - 1], child.arguments, child.properties,
					child.children, false, '${path}[${out.len - 1}]')!
			}
		}
	}
}

fn list_from_values[E](_ []E, values []Value, path string) ![]E {
	$if E is string || E is bool || E is $int || E is $float || E is $enum {
		mut out := []E{cap: values.len}
		for i, v in values {
			out << from_value(E{}, v, '${path}[${i}]')!
		}
		return out
	} $else {
		return marshal_error(.unsupported, path, 'unsupported field type []${typeof[E]().name}')
	}
}

// collect_props fills a map[string]scalar from the properties not in `skip`.
fn collect_props[K, V](_ map[K]V, props map[string]Value, skip map[string]bool, path string) !map[K]V {
	mut out := map[K]V{}
	// the fixed-array guard keeps `V{}` out of a branch the old V compiler cannot emit
	$if K is string && V !is $array_fixed {
		for k, v in props {
			if k !in skip {
				out[k] = from_value(V{}, v, '${path}.${k}')!
			}
		}
	}
	return out
}

fn data_type_name(v Value) string {
	return match v.data {
		string { 'string' }
		i64, BigInt { 'integer' }
		f64 { 'float' }
		bool { 'boolean' }
		Null { 'null' }
	}
}

fn mismatch(type_name string, v Value, path string) IError {
	return marshal_error(.type_mismatch, path, 'expected ${type_name}, got ${data_type_name(v)}')
}

fn from_value[S](_ S, v Value, path string) !S {
	$if S is string {
		if v.data is string {
			return v.data
		}
		return mismatch(typeof[S]().name, v, path)
	} $else $if S is bool {
		if v.data is bool {
			return v.data
		}
		return mismatch(typeof[S]().name, v, path)
	} $else $if S is $enum {
		if v.data is string {
			$for variant in S.values {
				if v.data == variant.name {
					return variant.value
				}
			}
			return marshal_error(.invalid_value, path, '`${v.data}` is not a ${typeof[S]().name} variant')
		}
		return mismatch(typeof[S]().name, v, path)
	} $else $if S is $int {
		bits := int(sizeof(S)) * 8
		$if S is u8 || S is u16 || S is u32 || S is u64 || S is usize {
			max := if bits == 64 { max_u64 } else { (u64(1) << bits) - 1 }
			match v.data {
				i64 {
					if v.data >= 0 && u64(v.data) <= max {
						return S(v.data)
					}
				}
				BigInt {
					if !v.data.negative {
						if n := parse_u64_digits(v.data.digits) {
							if n <= max {
								return S(n)
							}
						}
					}
				}
				else {
					return mismatch(typeof[S]().name, v, path)
				}
			}
			return marshal_error(.out_of_range, path, '${v} does not fit in ${typeof[S]().name}')
		} $else {
			match v.data {
				i64 {
					if bits == 64 {
						return S(v.data)
					}
					lim := i64(u64(1) << (bits - 1))
					if v.data >= -lim && v.data < lim {
						return S(v.data)
					}
				}
				BigInt {}
				else {
					return mismatch(typeof[S]().name, v, path)
				}
			}
			return marshal_error(.out_of_range, path, '${v} does not fit in ${typeof[S]().name}')
		}
	} $else $if S is $float {
		f := match v.data {
			f64 { v.data }
			i64 { f64(v.data) }
			BigInt { v.data.f64() }
			else { return mismatch(typeof[S]().name, v, path) }
		}
		if v.data is BigInt && math.is_inf(f, 0) {
			return marshal_error(.out_of_range, path, '${v} does not fit in ${typeof[S]().name}')
		}
		$if S is f32 {
			// overflow, and underflow to zero (subnormals that survive are accepted)
			if !math.is_nan(f) && !math.is_inf(f, 0)
				&& (math.abs(f) > math.max_f32 || (f != 0 && f32(f) == 0)) {
				return marshal_error(.out_of_range, path, '${v} does not fit in f32')
			}
		}
		return S(f)
	} $else {
		return marshal_error(.unsupported, path, 'unsupported value type ${typeof[S]().name}')
	}
}

// parse_u64_digits parses decimal digits, or returns none on overflow.
fn parse_u64_digits(digits string) ?u64 {
	mut n := u64(0)
	for c in digits {
		d := u64(c - `0`)
		if n > (max_u64 - d) / 10 {
			return none
		}
		n = n * 10 + d
	}
	return n
}
