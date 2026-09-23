# kdl

`kdl` is a parser and writer for [KDL 2.0](https://kdl.dev), a small node-oriented language for configuration files. It follows the KDL 2.0.0 specification and passes the whole official kdl-org test suite: every valid document parses to the expected result and every invalid one is rejected with a `kdl.ParseError` giving line and column.

A KDL document is a list of nodes. A node has a name, ordered arguments, named properties and optional children:

```kdl
// comments start with //
server "main" port=8080 debug=#false {
    tls #true
    route "/api" timeout=2.5
    route "/static"
}
```

## Installation

```sh
v install --git https://github.com/vlang/kdl
```

The module is then imported as `kdl`. It has no dependency outside the V standard library.

## Usage

```v
import kdl

const config_text = '
server "main" port=8080 debug=#false {
    tls #true
    route "/api" timeout=2.5
    route "/static"
}
'

fn main() {
	doc := kdl.parse(config_text)!

	server := doc.get('server') or { panic('no server node') }
	name := server.arg(0).as_string() or { 'unnamed' } // 'main'
	port := server.prop('port').as_int() or { 80 } // 8080
	tls_node := server.child('tls') or { kdl.Node{} }
	tls := tls_node.arg(0).as_bool() or { false } // true
	println('${name} listens on ${port} (tls: ${tls})')

	for route in server.children_named('route') {
		path := route.arg(0).as_string() or { continue }
		timeout := route.prop('timeout').as_f64() or { 30.0 }
		println('route ${path} timeout ${timeout}')
	}
}
```

`kdl.parse_file(path)!` reads a file. Syntax errors are `kdl.ParseError` values whose `msg()` reads `line:col: message`; I/O errors are ordinary errors.

## Data model

```v ignore
pub struct Document {
pub mut:
	nodes []Node
}

pub struct Node {
pub mut:
	ty         ?string          // type annotation, none when absent
	name       string
	arguments  []Value
	properties map[string]Value // last assignment wins
	children   []Node
}

pub struct Value {
pub mut:
	ty   ?string
	data Data = Null{}
}

pub type Data = string | i64 | f64 | bool | Null | BigInt
```

The mapping from KDL syntax to `Data` is:

| KDL | `Data` |
|---|---|
| `"text"`, `#"raw"#`, `bare-word`, `"""` multi-line `"""` | `string` |
| `42`, `-7`, `0xFF`, `0o17`, `0b101`, `1_000` | `i64` |
| integers outside the `i64` range | `BigInt` (sign flag plus decimal digits) |
| `2.5`, `1e10`, `#inf`, `#-inf`, `#nan` | `f64` |
| `#true`, `#false` | `bool` |
| `#null` | `Null` |

Type annotations such as `(u8)200` or `(date)"2024-01-01"` are kept in the `ty` field of the value or node, uninterpreted.

`Document.get(name)` and `Node.child(name)` return the first node with that name, or `none`. `Node.arg(i)` and `Node.prop(name)` return a value, or a `#null` value when there is no such argument or property. The accessors `as_string`, `as_int`, `as_f64`, `as_bool` return `none` when the value has another type, so a configuration reader supplies a default with `or { ... }` and never panics on a missing or mistyped entry. To handle every case explicitly, match on `value.data`.

A missing entry and an explicit `#null` look the same through `arg` and `prop`, and `or { default }` also swallows a value of the wrong type. When a setting is mandatory, check its presence and convert with an error instead:

```v
import kdl

fn port_of(server kdl.Node) !i64 {
	if 'port' !in server.properties {
		return error('server: missing `port`')
	}
	return server.prop('port').as_int() or { return error('server: `port` must be an integer') }
}

fn main() {
	doc := kdl.parse('server port="8080"')!
	port := port_of(doc.get('server') or { panic('no server node') }) or {
		println(err.msg()) // server: `port` must be an integer
		return
	}
	println(port)
}
```

Matching on `value.data` covers every case:

```v
import kdl

fn describe(v kdl.Value) string {
	return match v.data {
		string { 'string ${v.data}' }
		i64 { 'integer ${v.data}' }
		f64 { 'float ${v.data}' }
		bool { 'boolean ${v.data}' }
		kdl.Null { 'null' }
		kdl.BigInt { 'big integer ${v.data}' }
	}
}

fn main() {
	doc := kdl.parse('node 1 2.5 "three" #true #null 99999999999999999999')!
	for arg in doc.nodes[0].arguments {
		println(describe(arg))
	}
}
```

## Writing documents

`Document.str()` (also `println(doc)`) writes canonical KDL 2.0: one node per line, four-space indentation, properties sorted by name, strings bare when they are valid identifiers and quoted otherwise. Documents can be built by hand:

```v
import kdl

fn main() {
	mut doc := kdl.Document{}
	mut node := kdl.Node{
		name: 'user'
	}
	node.arguments << kdl.Value{
		data: 'alice'
	}
	node.properties['admin'] = kdl.Value{
		data: true
	}
	node.children << kdl.Node{
		name:      'email'
		arguments: [kdl.Value{
			data: 'alice@example.com'
		}]
	}
	doc.nodes << node
	println(doc)
	// user alice admin=#true {
	//     email alice@example.com
	// }
}
```

Anything produced by the parser round-trips: `kdl.parse(doc.str())` gives a document equal to `doc` (compare with `Document.equals`, which also treats two `#nan` values as equal).

## Structs

`kdl.encode` and `kdl.decode` map a V struct to a document and back. The struct is the document: each field is a top-level node named after the field.

```v
import kdl

enum Mode {
	dev
	prod
}

struct Route {
	path    string @[kdl: 'arg']
	timeout f64 = 30.0
}

struct Server {
	host   string = 'localhost'
	port   u16    = 80
	tls    ?bool
	routes []Route @[kdl: 'route']
}

struct Config {
	name            string
	mode            Mode
	max_connections int = 100
	server          Server
}

const config_text = '
name demo
mode prod
server host="0.0.0.0" port=8080 {
    route "/api" timeout=2.5
    route "/static"
}
'

fn main() {
	cfg := kdl.decode[Config](config_text, rename: .kebab_case)!
	println(cfg.server.routes[1].timeout) // 30.0, the default value
	print(kdl.encode(cfg, rename: .kebab_case)!)
	// name demo
	// mode prod
	// max-connections 100
	// server host="0.0.0.0" port=8080 {
	//     route "/api" timeout=2.5
	//     route "/static" timeout=30.0
	// }
}
```

A field is written according to its type and to where it is:

| Field type | At the top level | Inside a node |
|---|---|---|
| `string`, `bool`, integers, floats, enums | node `name value` | property `name=value` |
| struct | node `name` with the struct fields | child node `name` |
| `[]T` of structs | one node `name` per element | one child node `name` per element |
| `[]T` of scalars | node `name a b c` | child node `name a b c` |
| `map[string]T` of scalars | node `name k1=v1 k2=v2` | child node `name k1=v1 k2=v2` |
| `?T` of a scalar or a struct | as `T` when set, left out when `none`; `#null` decodes to `none` | same |

Enums are written with the name of their variant (flag enums are not supported), integers outside the `i64` range with a `BigInt`. Pointers, fixed-size arrays, sum types, interfaces, arrays of arrays and maps with other keys or values are not supported. The `kdl` tag changes the name and the place of a field inside a node, with words separated by commas:

| Tag | Effect |
|---|---|
| `@[kdl: 'name']` | uses `name` instead of the field name (no renaming applies) |
| `@[kdl: 'arg']` | the field is the next argument of its node (scalars only) |
| `@[kdl: 'args']` | the field gets the remaining arguments (`[]T` of scalars) |
| `@[kdl: 'props']` | the field gets the properties that no other field reads (`map[string]T` of scalars) |
| `@[kdl: 'child']` | a scalar is written as a child node `name value` instead of a property |
| `@[kdl: 'omitempty']` or `@[omitempty]` | `''`, `0`, `false` and empty arrays and maps are not written; enum values are always written, and an option is written whenever it holds a value, even a zero one, and left out when `none` |
| `@[kdl: '-']` or `@[skip]` | the field is ignored |

For instance `@[kdl: 'route']` on a `[]Route` field or `@[kdl: 'bio,omitempty']`. `rename: .kebab_case` (or `.camel_case`, `.pascal_case`, `.screaming_snake_case`) converts the field names without a tag, in both directions.

`kdl.decode_node[T](node)` fills a struct from one node, for example to read one section of a larger document:

```v
import kdl

struct Server {
	host string
	port int
}

fn main() {
	doc := kdl.parse('app { server host=localhost port=8080 }')!
	app := doc.get('app') or { return }
	server := kdl.decode_node[Server](app.child('server') or { return })!
	println(server.port) // 8080
}
```

Decoding is strict about what it reads and lenient about what it does not:

- a field without a node or a property keeps its default value, and a list that is present replaces its default value;
- nodes and properties without a matching field are ignored, so a file can have settings that the program does not know yet; a mistyped property name is therefore ignored as well;
- a value of the wrong type, a number that does not fit (`300` for a `u8`), an unknown enum variant, a node that appears twice for a single field, an argument that no field reads, and extra arguments, properties or children on a node that holds a single value are errors.

Errors are `kdl.MarshalError` values: `kind` tells what went wrong and `msg()` reads `path: message`, as in `server.route[1].timeout: expected f64, got string`. A struct that cannot be mapped (unknown tag word, unsupported type such as `[][]int`, two fields with the same name) is reported before any data is read. Syntax errors are still `kdl.ParseError` values.

`decode(encode(x)) == x` holds for the fields that are written, when their default values are zero values and their floats are not NaN (which is never equal to itself). A `none`, an empty list of structs (which has no node to write) or an empty `omitempty` field is left out, so it decodes to the field's default value, and a skipped field keeps its default.

## Performance

Parsing and encoding allocate about 2 KB per node (each node holds a map of properties and each value a boxed payload); writing and decoding allocate far less. On V master with the default Boehm garbage collector, this is what dominates for large documents: every collection marks the whole tree built so far, so the time grows faster than the size once the document has more than about 100 000 nodes. Measured with `-prod` on a document of 640 000 flat nodes (35 MB): `kdl.parse` takes 12.7 s, and 0.7 s once the collector is told to start with a heap large enough to hold the document:

```sh
GC_INITIAL_HEAP_SIZE=8G ./my_program big.kdl
```

`GC_INITIAL_HEAP_SIZE` is read by the Boehm collector at startup: it is the size the heap starts at, not a limit, and on macOS and Linux most of it is reserved address space until the program uses it. A program that only reads one document and exits can also be built with `v -prod -gc none`, which removes the collector altogether. For comparison, a document of 2 000 nodes (0.5 MB) parses in about 10 ms on the same machine.

## Limits

- Floats are stored as `f64`, so a literal outside its range becomes `#inf` or `0.0`, and the original notation (`1.0E+10` versus `1e10`) is not preserved. Decoding into an `f32` rejects a value that would overflow or underflow to zero, but cannot see a loss that already happened in the `f64` conversion.
- Comments are parsed and discarded, as the specification defines them as syntax without a value: a document holds nodes and values only, so `Document.str()` cannot write them back and always emits its own canonical layout. Not keeping comments, whitespace and the original spelling of numbers and strings is also what keeps the parser small and fast.

## Examples

Each example runs with `v run examples/<name>/main.v` from a checkout of the module (see [Development](#development)).

- [`config`](examples/config) reads a configuration file into a V struct field by field, with defaults for optional settings and errors for mandatory ones.
- [`structs`](examples/structs) does the same with `kdl.encode` and `kdl.decode`, field tags and renaming.
- [`walk`](examples/walk) walks the tree of a document (type annotations, arguments, properties, children) parsed from a text with comments, slashdash and escaped newlines, which leave no trace in the tree.
- [`values`](examples/values) shows how every kind of value is read: integers in all bases, big integers, floats and their keywords, strings in all forms, booleans and null.
- [`build`](examples/build) builds a document in code, writes it to a file, reads it back and changes it.

## Development

```sh
v test .
v fmt -verify .
v vet .
```

The sources are grouped by role in `parser/`, `writer/` and `marshal/`, listed as `subdirs` in `v.mod` so that they all belong to module `kdl`, next to the data model in `kdl.v`; the tests use the public API only, from `tests/`. `subdirs` needs a V compiler from April 2026 or later (vlang/v@dc503d6).

The tests run from a checkout in a directory named `kdl`, which V resolves as the module itself. From a directory with another name, make the module importable first, for example with a directory that contains a `kdl` link to the checkout: `VMODULES=/path/to/that/directory v test .`.

[`tests/kdl_conformance_test.v`](tests/kdl_conformance_test.v) runs the official [kdl-org test suite](https://github.com/kdl-org/kdl/tree/89c1087d5e7f530de328f18b6a0fad54ca8ea227/tests/test_cases) at commit `89c1087`, vendored in [`tests/test_cases`](tests/test_cases): the 95 invalid documents must be rejected, and the 243 valid ones must serialise to the expected canonical form and round-trip. Numbers are compared by value, since floats are stored as `f64` and their notation or out-of-range magnitude is not kept, and the empty document, which the suite writes as a single newline, is written as nothing.

## Authors

The module is co-authored by David Legrand ([@davlgd](https://github.com/davlgd)) and Jengro777 ([@Jengro777](https://github.com/Jengro777)). The parser, the writer and the data model come from David's implementation ([vlang/v#28819](https://github.com/vlang/v/pull/28819)); the struct marshaling, its field tags and several examples and tests come from Jengro777's ([vlang-community/kdl](https://github.com/vlang-community/kdl)).

## License

MIT, see [LICENSE](LICENSE). The test cases in `tests/test_cases` come from kdl-org/kdl and are licensed under CC BY-SA 4.0, see [their license](tests/test_cases/LICENSE.md); they are not part of the compiled module.
