## Description

`kdl` implements a parser and serializer for [KDL 2.0](https://kdl.dev/spec/)
([spec version 2.0.0, January 2026](https://kdl.dev/spec/)), a
node-oriented document language. KDL occupies a similar niche to JSON, YAML,
TOML, and XML, but uses a syntax that looks like CLI command invocations:

```kdl
package {
  name my-pkg
  version "2.0.0"
  dependencies {
    lodash "^3.2.1" optional=#true
  }
}
```

## Spec Compliance

This library targets **KDL 2.0.0** ([spec](https://kdl.dev/spec/)) with an estimated **~95%+ compliance** across all feature categories.

| Feature | Supported | Notes |
|---------|-----------|-------|
| Core Structure (nodes, doc) | ✅ | Nodes with name, entries, children |
| Quoted Strings | ✅ | Full escape support (\n, \r, \t, \\, \", \b, \f, \u{...}, \xNN, \s) |
| Raw Strings | ✅ | #"..."#, ##"..."##, ###"..."###, etc. |
| Multi-line Strings | ✅ | """...""" with indent stripping and CRLF normalization |
| Multi-line Raw Strings | ✅ | #"""..."""# |
| Integer Literals | ✅ | Decimal, hex (0x), octal (0o), binary (0b) |
| Float / Scientific Notation | ✅ | e/E notation |
| Number Underscores | ✅ | 1_000, 0xFF_FF, 1.0_1e1_0, trailing underscores |
| Boolean (#true / #false) | ✅ | Case-sensitive; bare true/false rejected |
| Null (#null) | ✅ | Case-sensitive; bare null rejected |
| Float Keywords (#inf, #-inf, #nan) | ✅ | Parsed to math.inf/nan |
| Type Annotations | ✅ | (type)node, (type)value, (type)prop=val; reserved types accepted |
| Properties (key=value) | ✅ | Strict mode; colon = identifier char (KDL 2.0) |
| Children Blocks ({...}) | ✅ | Arbitrary nesting |
| Line Comments (//) | ✅ | |
| Block Comments (/* */) | ✅ | Nestable |
| Slashdash Comments (/—) | ✅ | Nodes, entries, children |
| Escaped Newlines (Line Continuation) | ✅ | Backslash at line end with optional \s |
| Unicode Whitespace | ✅ | Hair space, narrow NBSP, math space, ideographic, etc. |
| Unicode Newlines | ✅ | CR, LF, CRLF, LS (U+2028), PS (U+2029) |
| UTF-8 BOM | ✅ | |
| Version Marker | ✅ | /- kdl-version 1 and 2 |
| Bare Identifier Rules | ✅ | Spec-compliant character validation |
| C0 Control Character Rejection | ✅ | DEL and control chars rejected |
| Semicolons as Node Separators | ✅ | |
| Generator / Formatter | ✅ | Roundtrip preservation |
| Marshaler / Unmarshaler | ✅ | Struct tags: arg, args, child, omitempty, rename |
| Coercion Helpers | ✅ | as_string, as_int, as_f64, as_bool, is_null, etc. |
| Relaxed Non-Compliant Modes | ✅ | nginx_syntax, yaml_toml_assignments, multiplier_suffixes |
| Document Building | ✅ | Manual construction of Document/Node structure |
| Error Handling | ✅ | KdlParseError with line/col/offset/msg |

## API

### Parsing

```v
import kdl

// Basic parsing
doc := kdl.parse('name "Alice" age 30 active #true')!
println(doc.nodes[0].name) // "name"

// With options
opts := kdl.ParseOpts{
	parse_comments: true
}
doc2 := kdl.parse_opts('// greeting\nhello "world"', opts)!

// From file
doc3 := kdl.parse_file('config.kdl')!
```

### Serialization

```v
import kdl

doc := kdl.parse('my-node 1 2 key="val"')!
out := kdl.format(doc)!
println(out)
```

### Marshal / Unmarshal

```v
import kdl

struct Person {
	name string
	age  int
}

// Encode struct to KDL
person := Person{
	name: 'Alice'
	age:  30
}
println(kdl.encode(person))

// Decode KDL into struct
p := kdl.decode[Person]('Person name=Alice age=30')!
println(p.name)
```

### Coercion & Property Helpers

```v
import kdl

doc := kdl.parse('sensor temp=22.5 name="Kitchen" online=#true')!
node := doc.nodes[0]

// Property access
temp := kdl.property_get(&node, 'temp') or { panic('missing') }
println(kdl.as_f64(temp)) // 22.5
println(kdl.as_string(temp)) // "22.5"

name := kdl.property_get(&node, 'name') or { panic('name missing') }
println(kdl.as_string(name)) // "Kitchen"

online := kdl.property_get(&node, 'online') or { panic('online missing') }
println(kdl.as_bool(online)) // true
```

### Document Model

- `Document` — list of top-level `Node` values
- `Node` — a KDL node with `type_name`, `name`, `entries` (arguments/properties in order),
  `children`, `comment`
- `Entry` — sumtype of `Argument` (positional value with optional type annotation) or `Property`
  (key=value with optional type annotation)
- `Value` — sumtype of `StringVal`, `IntVal`, `FloatVal`, `BoolVal`, `NullVal`

### Options & Relaxed Mode

```v
import kdl

// Relaxed NGINX syntax (allows /, \, (,) in identifiers)
mut relaxed := kdl.RelaxedNonCompliant{
	flags: kdl.nginx_syntax
}
opts := kdl.ParseOpts{
	relaxed: relaxed
}
doc := kdl.parse_opts('allow from 192.168.1.1/24', opts)!

// Parse with comment capture
mut opts2 := kdl.ParseOpts{
	parse_comments: true
}
doc2 := kdl.parse_opts('// section header\nnode "val"', opts2)!
```

## Features

- KDL 2.0 parsing with full tokenizer
  - Identifier strings, quoted strings, raw strings (`#"..."#`, `##"..."##`),
    multiline strings (`"""..."""`)
  - Decimal, hexadecimal (`0x`), octal (`0o`), binary (`0b`) numbers with underscore separators
  - Scientific notation, signed numbers
  - Booleans (`#true`, `#false`), null (`#null`), keyword numbers (`#inf`, `#-inf`, `#nan`)
  - Suffixed decimals (`10ms`, `5KiB`)
  - Type annotations (`(u8)`, `(person)`)
- Children blocks, properties, arguments — any order
- `//`, `/* */` (nestable), `/-` slashdash comments
- Line continuations (`\`)
- BOM handling
- Unicode whitespace and newline support (U+00A0, U+1680, U+2000-U+200A, U+202F,
  U+205F, U+3000, U+0085, U+2028, U+2029, etc.)
- Spec-compliant bare keyword rejection (`true`, `false`, `null`, `inf`, `-inf`, `nan`
  must be `#`-prefixed)
- Configurable relaxed mode (NGINX syntax, YAML/TOML assignments, multiplier suffixes)
- Document ↔ KDL text serialization via `format()`
- File I/O via `parse_file()`
- Marshal/unmarshal with struct tags (`[kdl: 'arg']`, `[kdl: 'children']`,
  `[kdl: 'omitempty']`, etc.)
- Rename strategies for encoding (`snake_case`, `kebab-case`, `camelCase`, `PascalCase`,
  `screaming-snake`)
- Value coercion helpers (`as_string`, `as_int`, `as_i64`, `as_f64`, `as_bool`, `as_u64`,
  `as_numeric`, `is_null`)
- String helpers (`quote_string`, `unquote_string`, `raw_string`, `can_be_bare_identifier`)
- Property helpers (`property_exists`, `property_get`, `property_has`)
