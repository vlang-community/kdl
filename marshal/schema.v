module kdl

// Schema of a struct type: how each field maps to KDL, prepared once per type
// before encoding or decoding.

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
