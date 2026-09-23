module kdl

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
