module kdl

// Structs are passed by reference: the old V compiler (`-old-compiler`, with
// `-prod` and the Boehm GC) pins a by-value struct argument as a GC root by
// walking its whole content before every call, which made encoding quadratic.
fn (mut ctx MarshalContext) encode_struct[T](val &T, doc_level bool, mut node Node, path string) ! {
	spec := ctx.types[typeof[T]().idx * 2 + int(doc_level)] or {
		return marshal_error(.unsupported, path, 'no schema prepared for ${typeof[T]().name}')
	}
	mut i := 0
	$for field in T.fields {
		f := spec.fields[i]
		i++
		if !f.skip {
			$if field.is_option {
				ctx.encode_option(val.$(field.name), f, doc_level, mut node, path, spec.prop_names)!
			} $else {
				if !f.omitempty || !is_empty(val.$(field.name)) {
					ctx.encode_field(val.$(field.name), f, doc_level, mut node, path, spec.prop_names)!
				}
			}
		}
	}
}

// encode_option writes the value of an option, and nothing for `none`. An
// explicit value is always written, even a zero one under `omitempty`: it was
// set on purpose, and leaving it out would decode to the default of the field.
fn (mut ctx MarshalContext) encode_option[E](v ?E, f FieldSpec, doc_level bool, mut node Node, path string, reserved map[string]bool) ! {
	// `if x := v { ... }` would pass `x` as `?E` to the generic call below
	x := v or { return }
	ctx.encode_field(x, f, doc_level, mut node, path, reserved)!
}

// encode_field adds one field to `node`. `reserved` holds the property names of
// the named fields, which a `props` map must not reuse.
fn (mut ctx MarshalContext) encode_field[F](v F, f FieldSpec, doc_level bool, mut node Node, path string, reserved map[string]bool) ! {
	fpath := join_path(path, f.name)
	$if F is $array_fixed {
		// rejected by prepare; kept out of the array branch, which does not compile for it
	} $else $if F is $array {
		if f.role == .args {
			for e in v {
				node.arguments << to_value(e, fpath)!
			}
		} else {
			ctx.encode_list(v, f.name, mut node, fpath)!
		}
	} $else $if F is $map {
		mut props := map[string]Value{}
		for k, e in v {
			props['${k}'] = to_value(e, '${fpath}.${k}')!
		}
		if f.role == .props {
			for k, e in props {
				if k in reserved {
					return marshal_error(.unsupported, fpath, 'key `${k}` is also the name of a property field')
				}
				node.properties[k] = e
			}
		} else {
			node.children << Node{
				name:       f.name
				properties: props
			}
		}
	} $else $if F is string || F is bool || F is $int || F is $float || F is $enum {
		value := to_value(v, fpath)!
		if f.role == .arg {
			node.arguments << value
		} else if doc_level || f.role == .as_child {
			node.children << Node{
				name:      f.name
				arguments: [value]
			}
		} else {
			node.properties[f.name] = value
		}
	} $else $if F is $struct {
		// children are built in place: pushing a filled local Node would copy its subtree
		node.children << Node{
			name: f.name
		}
		ctx.encode_struct(&v, false, mut node.children[node.children.len - 1], fpath)!
	}
}

// encode_list addresses the elements in place (`&list[i]`): with the old V
// compiler, a `&[]E` parameter loses the elements, and a by-value array is
// pinned as a GC root at every call unless one of its elements is addressed.
fn (mut ctx MarshalContext) encode_list[E](list []E, name string, mut node Node, path string) ! {
	$if E is string || E is bool || E is $int || E is $float || E is $enum {
		node.children << Node{
			name:      name
			arguments: []Value{cap: list.len}
		}
		last := node.children.len - 1
		for i in 0 .. list.len {
			e := &list[i]
			node.children[last].arguments << to_value(*e, path)!
		}
	} $else $if E is $struct {
		for i in 0 .. list.len {
			node.children << Node{
				name: name
			}
			e := &list[i] // bound locally: only this form lifts the pin (see above)
			ctx.encode_struct(e, false, mut node.children[node.children.len - 1], '${path}[${i}]')!
		}
	}
}

fn is_empty[F](v F) bool {
	$if F is string {
		return v == ''
	} $else $if F is bool {
		return !v
	} $else $if F is $int || F is $float {
		return v == 0
	} $else $if F is $array_fixed {
		return false
	} $else $if F is $array || F is $map {
		return v.len == 0
	} $else {
		return false
	}
}

fn to_value[S](v S, path string) !Value {
	$if S is string {
		return Value{
			data: v
		}
	} $else $if S is bool {
		return Value{
			data: v
		}
	} $else $if S is $enum {
		$for variant in S.values {
			if v == variant.value {
				return Value{
					data: variant.name
				}
			}
		}
		return marshal_error(.invalid_value, path, '${typeof[S]().name} value ${int(v)} is not a single variant')
	} $else $if S is u64 || S is usize {
		if u64(v) > u64(max_i64) {
			return Value{
				data: BigInt{
					digits: u64(v).str()
				}
			}
		}
		return Value{
			data: i64(v)
		}
	} $else $if S is $int {
		return Value{
			data: i64(v)
		}
	} $else $if S is $float {
		return Value{
			data: f64(v)
		}
	} $else {
		return marshal_error(.unsupported, path, 'unsupported value type ${typeof[S]().name}')
	}
}
