module kdl

import math

// Marshaling maps a V struct to a KDL document and back. The struct is the
// document: each field is a top-level node. Inside a node, scalar fields are
// properties and struct, array and map fields are child nodes. The field tags
// and their names come from the marshaler of github.com/vlang-community/kdl.

// Rename selects how V field names are written as KDL names. It applies to
// field names only: names given in a `@[kdl: 'name']` tag, map keys and enum
// variants are used as they are.
pub enum Rename {
	keep                 // max_connections
	kebab_case           // max-connections
	camel_case           // maxConnections
	pascal_case          // MaxConnections
	screaming_snake_case // MAX_CONNECTIONS
}

// MarshalOptions configures encode, decode and decode_node.
@[params]
pub struct MarshalOptions {
pub:
	rename Rename
}

// MarshalErrorKind tells what went wrong in encode, decode or decode_node.
pub enum MarshalErrorKind {
	unsupported   // the struct cannot be mapped: bad tag, unsupported type, name clash
	type_mismatch // a value has another type than the field
	out_of_range  // a number does not fit in the field type
	invalid_value // a string is not a variant of the enum
	duplicate     // a node that maps to a single field appears more than once
	unexpected    // a node or entry that the field does not accept
}

// MarshalError is returned by encode, decode and decode_node. `path` locates the
// field, as in `servers[1].port`, and is empty for the root.
pub struct MarshalError {
	Error
pub:
	kind    MarshalErrorKind
	path    string
	message string
}

// msg formats the error as `path: message`.
pub fn (e MarshalError) msg() string {
	if e.path == '' {
		return e.message
	}
	return '${e.path}: ${e.message}'
}

// encode writes `val`, a struct, as a KDL document: each field becomes a
// top-level node. See the README for the mapping and the field tags.
pub fn encode[T](val T, opts MarshalOptions) !string {
	$if T is $struct {
		mut ctx := MarshalContext{
			opts: opts
		}
		ctx.prepare(val, true, '')!
		mut root := Node{}
		ctx.encode_struct(&val, true, mut root, '')!
		return write_children(&root)
	} $else {
		return marshal_error(.unsupported, '', 'encode needs a struct, got ${typeof[T]().name}')
	}
}

// decode parses `src` and fills a `T` from it: each field reads the top-level
// node of the same name. Fields without a node keep their default value, and
// nodes without a field are ignored.
pub fn decode[T](src string, opts MarshalOptions) !T {
	$if T is $struct {
		mut out := T{}
		mut ctx := MarshalContext{
			opts: opts
		}
		ctx.prepare(out, true, '')! // the struct is checked before the text is read
		doc := parse(src)!
		ctx.decode_struct(mut out, []Value{}, map[string]Value{}, doc.nodes, true, '')!
		return out
	} $else {
		return marshal_error(.unsupported, '', 'decode needs a struct, got ${typeof[T]().name}')
	}
}

// decode_node fills a `T` from the arguments, properties and children of
// `node`, whose own name is not checked. It reads one node of a larger
// document, such as `kdl.decode_node[Server](doc.get('server')?)!`.
pub fn decode_node[T](node Node, opts MarshalOptions) !T {
	$if T is $struct {
		mut out := T{}
		mut ctx := MarshalContext{
			opts: opts
		}
		ctx.prepare(out, false, '')!
		ctx.decode_struct(mut out, node.arguments, node.properties, node.children, false,
			'')!
		return out
	} $else {
		return marshal_error(.unsupported, '', 'decode_node needs a struct, got ${typeof[T]().name}')
	}
}

// FieldRole is how a field is stored in its node, from its `kdl` tag.
enum FieldRole {
	auto     // from the field type
	arg      // next positional argument
	args     // all remaining positional arguments
	props    // properties not claimed by another field
	as_child // scalar written as a child node `name value`
}

// FieldKind is the shape of a field type.
enum FieldKind {
	scalar      // string, bool, integer, float, enum
	list_scalar // []scalar
	list_struct // []struct
	map_scalar  // map[string]scalar
	struct_     // struct
	opt_scalar  // ?scalar
	opt_struct  // ?struct
}

struct FieldSpec {
	name      string // KDL name
	role      FieldRole
	kind      FieldKind
	omitempty bool
	skip      bool
}

struct TypeSpec {
mut:
	fields     []FieldSpec
	prop_names map[string]bool // properties read by named fields
}

struct MarshalContext {
	opts MarshalOptions
mut:
	types map[int]TypeSpec
}

fn marshal_error(kind MarshalErrorKind, path string, message string) IError {
	return MarshalError{
		kind:    kind
		path:    path
		message: message
	}
}

fn join_path(path string, name string) string {
	return if path == '' { name } else { '${path}.${name}' }
}

// prepare reads and checks the tags of `T` and of every struct it contains,
// once per call, so that a bad schema fails before any data is read.
fn (mut ctx MarshalContext) prepare[T](probe T, doc_level bool, path string) ! {
	key := typeof[T]().idx * 2 + int(doc_level)
	if key in ctx.types {
		return
	}
	ctx.types[key] = TypeSpec{} // stops the recursion on recursive types
	mut spec := TypeSpec{}
	mut child_names := map[string]bool{}
	mut has_args := false
	mut has_props := false
	$for field in T.fields {
		mut f := parse_field_tag(field.name, field.attrs, ctx.opts, path)!
		if !f.skip {
			fpath := join_path(path, f.name)
			$if field.is_option {
				f = FieldSpec{
					...f
					kind: ctx.prepare_option(probe.$(field.name), fpath)!
				}
			} $else {
				f = FieldSpec{
					...f
					kind: ctx.prepare_value(probe.$(field.name), fpath)!
				}
			}
			check_role(f, doc_level, has_args, has_props, fpath)!
			has_args = has_args || f.role == .args
			has_props = has_props || f.role == .props
			if f.role == .auto && !doc_level && f.kind in [.scalar, .opt_scalar] {
				if f.name in spec.prop_names {
					return marshal_error(.unsupported, fpath, 'two fields use the property name `${f.name}`')
				}
				spec.prop_names[f.name] = true
			} else if f.role in [.auto, .as_child] {
				if f.name in child_names {
					return marshal_error(.unsupported, fpath, 'two fields use the node name `${f.name}`')
				}
				child_names[f.name] = true
			}
		}
		spec.fields << f
	}
	ctx.types[key] = spec
}

fn check_role(f FieldSpec, doc_level bool, has_args bool, has_props bool, path string) ! {
	if doc_level && f.role in [.arg, .args, .props] {
		return marshal_error(.unsupported, path, 'a document has no ${f.role} to map; use it in a nested struct')
	}
	ok := match f.role {
		.auto { true }
		.arg { f.kind == .scalar }
		.args { f.kind == .list_scalar }
		.props { f.kind == .map_scalar }
		.as_child { f.kind in [.scalar, .opt_scalar] }
	}
	if !ok {
		return marshal_error(.unsupported, path, 'the `${tag_word(f.role)}` tag does not accept ${kind_name(f.kind)}')
	}
	if f.role == .arg && has_args {
		return marshal_error(.unsupported, path, 'an `arg` field must come before the `args` field')
	}
	if f.role == .args && has_args {
		return marshal_error(.unsupported, path, 'only one field can collect the arguments')
	}
	if f.role == .props && has_props {
		return marshal_error(.unsupported, path, 'only one field can collect the properties')
	}
	if f.role == .arg && f.omitempty {
		return marshal_error(.unsupported, path, '`omitempty` would shift the arguments that follow an `arg` field')
	}
}

fn tag_word(r FieldRole) string {
	return match r {
		.auto { '' }
		.arg { 'arg' }
		.args { 'args' }
		.props { 'props' }
		.as_child { 'child' }
	}
}

fn kind_name(k FieldKind) string {
	return match k {
		.scalar { 'scalars' }
		.list_scalar { 'arrays' }
		.list_struct { 'arrays of structs' }
		.map_scalar { 'maps' }
		.struct_ { 'structs' }
		.opt_scalar, .opt_struct { 'options' }
	}
}

// parse_field_tag reads `@[kdl: 'name,role,omitempty']`, `@[kdl: '-']`,
// `@[skip]` and `@[omitempty]`. A first word that is a tag keyword is a role,
// so a field cannot be renamed to `arg`, `args`, `props`, `child` or `omitempty`.
fn parse_field_tag(field_name string, attrs []string, opts MarshalOptions, path string) !FieldSpec {
	// a skipped field is not checked at all, whatever its other tags
	for attr in attrs {
		if attr == 'skip' || attr.replace(' ', '') in ["kdl:'-'", 'kdl:"-"', 'kdl:-'] {
			return FieldSpec{
				name: field_name
				skip: true
			}
		}
	}
	mut name := ''
	mut role := FieldRole.auto
	mut omitempty := false
	for attr in attrs {
		if attr == 'omitempty' {
			omitempty = true
			continue
		}
		if !attr.starts_with('kdl:') {
			continue
		}
		mut tag := attr[4..].trim_space()
		if tag.len >= 2 && tag[0] in [`'`, `"`] && tag[tag.len - 1] == tag[0] {
			tag = tag[1..tag.len - 1]
		}
		for i, part in tag.split(',') {
			word := part.trim_space()
			new_role := match word {
				'arg' { FieldRole.arg }
				'args' { FieldRole.args }
				'props' { FieldRole.props }
				'child' { FieldRole.as_child }
				else { FieldRole.auto }
			}
			if new_role != .auto {
				if role != .auto {
					return marshal_error(.unsupported, join_path(path, field_name), 'a field can only have one of `arg`, `args`, `props` and `child`')
				}
				role = new_role
			} else if word == 'omitempty' {
				omitempty = true
			} else if i == 0 {
				name = word // may be empty, as in `,omitempty`
			} else {
				return marshal_error(.unsupported, join_path(path, field_name), 'unknown word `${word}` in the kdl tag')
			}
		}
	}
	return FieldSpec{
		name:      if name != '' { name } else { rename_field(field_name, opts.rename) }
		role:      role
		omitempty: omitempty
	}
}

// rename_field converts a snake_case V field name.
fn rename_field(name string, r Rename) string {
	match r {
		.keep {
			return name
		}
		.kebab_case {
			return name.replace('_', '-')
		}
		.screaming_snake_case {
			return name.to_upper()
		}
		.camel_case, .pascal_case {
			parts := name.split('_').filter(it != '')
			mut out := []string{cap: parts.len}
			for i, p in parts {
				out << if i == 0 && r == .camel_case { p } else { p.capitalize() }
			}
			return out.join('')
		}
	}
}

fn (mut ctx MarshalContext) prepare_value[F](probe F, path string) !FieldKind {
	$if F is $pointer || F is $voidptr || F is $array_fixed || F is $sumtype || F is $interface {
		return unsupported_type(typeof[F]().name, path)
	} $else $if F is $array {
		return ctx.prepare_list(probe, path)
	} $else $if F is $map {
		return ctx.prepare_map(probe, path)
	} $else $if F is string || F is bool || F is $int || F is $float || F is $enum {
		ctx.check_scalar[F](path)!
		return .scalar
	} $else $if F is $struct {
		ctx.prepare(probe, false, path)!
		return .struct_
	} $else {
		return unsupported_type(typeof[F]().name, path)
	}
}

fn (mut ctx MarshalContext) prepare_list[E](_ []E, path string) !FieldKind {
	$if E is $pointer || E is $voidptr || E is $array_fixed || E is $sumtype || E is $interface || E is $array || E is $map {
		return unsupported_type('[]${typeof[E]().name}', path)
	} $else $if E is string || E is bool || E is $int || E is $float || E is $enum {
		ctx.check_scalar[E](path)!
		return .list_scalar
	} $else $if E is $struct {
		ctx.prepare(E{}, false, path)!
		return .list_struct
	} $else {
		return unsupported_type('[]${typeof[E]().name}', path)
	}
}

fn (mut ctx MarshalContext) prepare_map[K, V](_ map[K]V, path string) !FieldKind {
	$if K is string {
		$if V is $pointer || V is $voidptr || V is $array_fixed || V is $sumtype || V is $interface {
		} $else $if V is string || V is bool || V is $int || V is $float || V is $enum {
			ctx.check_scalar[V](path)!
			return .map_scalar
		}
	}
	return marshal_error(.unsupported, path, 'unsupported field type map[${typeof[K]().name}]${typeof[V]().name}, only map[string]scalar is supported')
}

fn (mut ctx MarshalContext) prepare_option[E](_ ?E, path string) !FieldKind {
	$if E is $pointer || E is $voidptr || E is $array_fixed || E is $sumtype || E is $interface || E is $array || E is $map {
		return unsupported_type('?${typeof[E]().name}', path)
	} $else $if E is string || E is bool || E is $int || E is $float || E is $enum {
		ctx.check_scalar[E](path)!
		return .opt_scalar
	} $else $if E is $struct {
		ctx.prepare(E{}, false, path)!
		return .opt_struct
	} $else {
		return unsupported_type('?${typeof[E]().name}', path)
	}
}

// check_scalar rejects flag enums: a combination of flags has no variant name.
fn (mut ctx MarshalContext) check_scalar[S](path string) ! {
	$if S is $enum {
		$for attr in S.attributes {
			if attr.name == 'flag' {
				return marshal_error(.unsupported, path, 'unsupported field type ${typeof[S]().name}: flag enums have no single variant name')
			}
		}
	}
}

fn unsupported_type(name string, path string) IError {
	return marshal_error(.unsupported, path, 'unsupported field type ${name}')
}

// ---- encoding

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

// ---- decoding

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
