module kdl

import math

enum Mode {
	dev
	prod
}

struct Route {
	path    string @[kdl: 'arg']
	timeout f64 = 30.0
	methods []string
}

struct Tls {
	enabled bool @[kdl: 'arg']
	cert    ?string
}

struct Server {
	host   string
	port   u16
	tls    ?Tls
	routes []Route @[kdl: 'route']
	labels map[string]string
}

struct Config {
	name            string
	mode            Mode
	max_connections int = 100
	tags            []string
	server          Server
	ratio           ?f64
	secret          string @[skip]
}

fn sample_config() Config {
	return Config{
		name:   'demo'
		mode:   .prod
		tags:   ['a', 'b c']
		server: Server{
			host:   '::'
			port:   8080
			tls:    Tls{
				enabled: true
			}
			routes: [Route{
				path:    '/api'
				timeout: 2.5
				methods: ['GET', 'POST']
			}, Route{
				path: '/static'
			}]
			labels: {
				'team': 'core'
				'env':  'prod'
			}
		}
		ratio:  0.5
		secret: 'hidden'
	}
}

const sample_text = 'name demo
mode prod
max-connections 100
tags a "b c"
server host=:: port=8080 {
    tls #true
    route "/api" timeout=2.5 {
        methods GET POST
    }
    route "/static" timeout=30.0 {
        methods
    }
    labels env=prod team=core
}
ratio 0.5
'

fn test_encode() {
	assert encode(sample_config(), rename: .kebab_case)! == sample_text
}

fn test_decode() {
	cfg := decode[Config](sample_text, rename: .kebab_case)!
	assert cfg == Config{
		...sample_config()
		secret: ''
	}
}

fn test_round_trip() {
	cfg := Config{
		...sample_config()
		secret: ''
	}
	assert decode[Config](encode(cfg)!)! == cfg
}

fn test_absent_fields_keep_defaults() {
	cfg := decode[Config]('name x\nunknown-node 1 2 { child }')!
	assert cfg.name == 'x'
	assert cfg.max_connections == 100
	assert cfg.mode == .dev
	assert cfg.ratio == none
	assert cfg.server.tls == none
	assert cfg.server.routes.len == 0
}

fn test_unknown_properties_are_ignored() {
	cfg := decode[Config]('server port=1 color=blue')!
	assert cfg.server.port == 1
}

fn test_decode_node() {
	doc := parse('app { server host=localhost port=80 { route "/" } }')!
	app := doc.get('app')?
	server := decode_node[Server](app.child('server')?)!
	assert server.host == 'localhost'
	assert server.port == 80
	assert server.routes == [Route{
		path: '/'
	}]
}

// from the marshaler tests of github.com/vlang-community/kdl
struct Staff {
	first string @[kdl: 'arg']
	last  string @[kdl: 'arg']
	age   int
}

struct Items {
	items []string @[kdl: 'args']
}

struct Profile {
	name   string
	bio    string @[kdl: 'bio,omitempty']
	active bool
}

struct Team {
	staff   []Staff
	items   Items
	profile Profile
}

fn test_arguments_and_omitempty() {
	team := Team{
		staff:   [Staff{'Bob', 'Smith', 76}, Staff{'Ann', 'Lee', 41}]
		items:   Items{
			items: ['a', 'b', 'c']
		}
		profile: Profile{
			name:   'Jane'
			active: true
		}
	}
	text := encode(team)!
	assert text == 'staff Bob Smith age=76\nstaff Ann Lee age=41\nitems a b c\nprofile active=#true name=Jane\n'
	assert decode[Team](text)! == team
	assert decode_node[Staff](parse('StaffDec Bob Smith age=76')!.nodes[0])! == Staff{'Bob', 'Smith', 76}
}

struct Numbers {
	a i8
	b u8
	c u64
	d i64
	e f32
	f f64
	g int
	h ?u16
}

fn test_integer_ranges() {
	n := decode[Numbers]('a -128\nb 255\nc 18446744073709551615\nd -9223372036854775808\ne 1.5\nf 3\ng 0x10\nh #null')!
	assert n.a == -128
	assert n.b == 255
	assert n.c == max_u64
	assert n.d == min_i64
	assert n.e == 1.5
	assert n.f == 3.0
	assert n.g == 16
	assert n.h == none
	assert encode(n)! == 'a -128\nb 255\nc 18446744073709551615\nd -9223372036854775808\ne 1.5\nf 3.0\ng 16\n'
	assert decode[Numbers](encode(n)!)! == n
}

fn expect_error[T](src string, kind MarshalErrorKind, msg string) {
	decode[T](src) or {
		assert err is MarshalError
		e := err as MarshalError
		assert e.kind == kind, err.msg()
		assert err.msg() == msg, err.msg()
		return
	}
	assert false, 'no error for `${src}`'
}

struct Floats {
	a f32
	b f64
}

fn test_big_integers_do_not_become_infinity() {
	big := '1' + '0'.repeat(400)
	expect_error[Floats]('a ${big}', .out_of_range, 'a: ${big} does not fit in f32')
	expect_error[Floats]('b ${big}', .out_of_range, 'b: ${big} does not fit in f64')
	inf := decode[Floats]('a #inf\nb #-inf')!
	assert math.is_inf(inf.a, 1) && math.is_inf(inf.b, -1)
	assert decode[Floats]('b 99999999999999999999')!.b == 1e20
}

struct EmptyName {
	note string @[kdl: ',omitempty']
}

fn test_empty_name_in_tag() {
	assert encode(Wrap[EmptyName]{})! == 'inner\n'
	assert encode(Wrap[EmptyName]{EmptyName{'x'}})! == 'inner note=x\n'
}

fn test_decode_errors() {
	expect_error[Numbers]('a 128', .out_of_range, 'a: 128 does not fit in i8')
	expect_error[Numbers]('b -1', .out_of_range, 'b: -1 does not fit in u8')
	expect_error[Numbers]('c 18446744073709551616', .out_of_range, 'c: 18446744073709551616 does not fit in u64')
	expect_error[Numbers]('d 9223372036854775808', .out_of_range, 'd: 9223372036854775808 does not fit in i64')
	expect_error[Numbers]('e 1e39', .out_of_range, 'e: 1E+39 does not fit in f32')
	expect_error[Numbers]('g 1.5', .type_mismatch, 'g: expected int, got float')
	expect_error[Numbers]('g "1"', .type_mismatch, 'g: expected int, got string')
	expect_error[Numbers]('g #null', .type_mismatch, 'g: expected int, got null')
	expect_error[Numbers]('g 1 2', .unexpected, 'g: expected one argument, got 2')
	expect_error[Numbers]('g 1 x=2', .unexpected, 'g: unexpected property `x`')
	expect_error[Numbers]('g 1 { x }', .unexpected, 'g: unexpected child node `x`')
	expect_error[Numbers]('g 1\ng 2', .duplicate, 'g: node `g` appears more than once')
	expect_error[Config]('mode staging', .invalid_value, 'mode: `staging` is not a kdl.Mode variant')
	expect_error[Config]('server port=x', .type_mismatch, 'server.port: expected u16, got string')
	expect_error[Config]('server { route "/" timeout=#true }', .type_mismatch, 'server.route[0].timeout: expected f64, got boolean')
	expect_error[Config]('server { route "/" "/extra" }', .unexpected, 'server.route[0]: unexpected argument 2: "/extra"')
	expect_error[Config]('tags a 1', .type_mismatch, 'tags[1]: expected string, got integer')
	expect_error[Config]('server { labels a=1 }', .type_mismatch, 'server.labels.a: expected string, got integer')
	expect_error[Config]('server { labels x }', .unexpected, 'server.labels: unexpected argument x')
}

fn test_parse_errors_are_not_marshal_errors() {
	decode[Config]('name "a') or {
		assert err is ParseError
		return
	}
	assert false
}

fn test_schema_is_checked_before_the_text() {
	// an invalid struct is reported even when the text is malformed
	decode[BadNested]('name "a') or {
		assert err is MarshalError
		assert err.msg() == 'a: unsupported field type [][]int'
		return
	}
	assert false
}

struct OptionalDefaults {
	retries ?int = 3      @[omitempty]
	label   ?string @[omitempty]
	verbose ?bool   @[omitempty]
}

fn test_options_keep_explicit_zero_values() {
	x := OptionalDefaults{
		retries: 0
		label:   ''
		verbose: false
	}
	text := encode(x)!
	assert text == 'retries 0\nlabel ""\nverbose #false\n'
	assert decode[OptionalDefaults](text)! == x
	assert encode(OptionalDefaults{})! == 'retries 3\n' // the default of the option is a value
	assert decode[OptionalDefaults]('')!.retries? == 3
	assert decode[OptionalDefaults]('retries #null')!.retries == none
}

struct EnumDefault {
	mode Mode = .prod @[omitempty]
}

fn test_omitempty_never_omits_an_enum() {
	x := EnumDefault{
		mode: .dev
	}
	assert encode(x)! == 'mode dev\n'
	assert decode[EnumDefault](encode(x)!)! == x
}

struct Sub {
	name    string
	timeout int = 30
}

struct OptionalSub {
	child ?Sub = Sub{
		timeout: 10
	}
}

fn test_optional_struct_keeps_its_defaults() {
	assert decode[OptionalSub]('child name=x')!.child? == Sub{'x', 10}
	assert decode[OptionalSub]('child name=x timeout=5')!.child? == Sub{'x', 5}
	assert decode[OptionalSub]('')!.child? == Sub{'', 10}
	assert decode[OptionalSub]('child #null')!.child == none
	assert decode[NullableStruct]('tls #true')!.tls? == Tls{
		enabled: true
	}
}

fn test_f32_underflow() {
	assert decode[Floats]('a 1e-45')!.a != 0
	assert decode[Floats]('a 1.1')!.a == f32(1.1)
	assert decode[Floats]('a 0.0')!.a == 0
	assert decode[Floats]('a -0.0')!.a == 0
	expect_error[Floats]('a 1e-50', .out_of_range, 'a: 1E-50 does not fit in f32')
	expect_error[Floats]('a -1e-50', .out_of_range, 'a: -1E-50 does not fit in f32')
}

struct Props {
	name  string
	extra map[string]int @[kdl: 'props']
}

struct WithProps {
	item Props
}

fn test_props_collects_the_remaining_properties() {
	w := decode[WithProps]('item name=x a=1 b=2')!
	assert w.item.name == 'x'
	assert w.item.extra == {
		'a': 1
		'b': 2
	}
	assert encode(w)! == 'item a=1 b=2 name=x\n'
	clash := WithProps{
		item: Props{
			name:  'x'
			extra: {
				'name': 1
			}
		}
	}
	encode(clash) or {
		assert err.msg() == 'item.extra: key `name` is also the name of a property field'
		return
	}
	assert false
}

struct Child {
	level string @[kdl: 'child']
	depth ?int   @[kdl: 'child']
}

struct WithChild {
	log Child
}

fn test_child_tag() {
	w := WithChild{
		log: Child{
			level: 'info'
			depth: 3
		}
	}
	assert encode(w)! == 'log {\n    level info\n    depth 3\n}\n'
	assert decode[WithChild](encode(w)!)! == w
	assert decode[WithChild]('log { depth #null }')!.log.depth == none
}

struct Tree {
	name     string @[kdl: 'arg']
	children []Tree @[kdl: 'node']
}

struct Forest {
	node []Tree
}

fn test_recursive_types() {
	src := 'node root {\n    node a {\n        node b\n    }\n    node c\n}\n'
	f := decode[Forest](src)!
	assert f.node[0].children[0].children[0].name == 'b'
	assert encode(f)! == src
}

struct Renamed {
	max_connections int
	api_key         string @[kdl: 'API']
}

fn test_rename() {
	r := Renamed{
		max_connections: 5
		api_key:         'k'
	}
	assert encode(r)! == 'max_connections 5\nAPI k\n'
	assert encode(r, rename: .kebab_case)! == 'max-connections 5\nAPI k\n'
	assert encode(r, rename: .camel_case)! == 'maxConnections 5\nAPI k\n'
	assert encode(r, rename: .pascal_case)! == 'MaxConnections 5\nAPI k\n'
	assert encode(r, rename: .screaming_snake_case)! == 'MAX_CONNECTIONS 5\nAPI k\n'
	assert decode[Renamed]('maxConnections 5', rename: .camel_case)!.max_connections == 5
	assert decode[Renamed]('max-connections 5')!.max_connections == 0
}

struct NullableStruct {
	tls ?Tls
}

fn test_option_struct() {
	assert decode[NullableStruct]('tls #null')!.tls == none
	assert decode[NullableStruct]('tls #true')!.tls? == Tls{
		enabled: true
	}
	assert encode(NullableStruct{})! == ''
}

struct ListDefaults {
	tags  []string = ['x']
	route []Route  = [Route{
		path: '/default'
	}]
}

fn test_lists_replace_defaults() {
	assert decode[ListDefaults]('')! == ListDefaults{}
	assert decode[ListDefaults]('tags')!.tags == []
	assert decode[ListDefaults]('tags a b')!.tags == ['a', 'b']
	assert decode[ListDefaults]('route "/a"')!.route == [Route{
		path: '/a'
	}]
}

// ---- schema errors: reported before any data is read

struct BadRoleAtTop {
	a string @[kdl: 'arg']
}

struct BadTwoRoles {
	a string @[kdl: 'arg,child']
}

struct BadWord {
	a string @[kdl: 'a,sometimes']
}

struct BadArgType {
	a []string @[kdl: 'arg']
}

struct BadArgAfterArgs {
	a []string @[kdl: 'args']
	b string   @[kdl: 'arg']
}

struct BadOmitArg {
	a string @[kdl: 'arg,omitempty']
}

struct BadOptionArg {
	a ?string @[kdl: 'arg']
}

struct BadNameClash {
	a string @[kdl: 'x']
	b int    @[kdl: 'x']
}

struct BadNested {
	a [][]int
}

struct BadMap {
	a map[int]string
}

struct BadOptionList {
	a ?[]int
}

struct BadFixed {
	a [2]int
}

struct Leaf {
	value int
}

struct BadPointer {
	leaf &Leaf = &Leaf{}
}

@[flag]
enum Perm {
	read
	write
}

struct BadFlag {
	perms Perm
}

struct BadListOfPointers {
	a []&Leaf
}

struct BadMapOfFixed {
	a map[string][2]int
}

struct SkipWins {
	a string @[kdl: 'v,bogus'; skip]
}

struct Wrap[T] {
	inner T
}

fn expect_schema_error[T](msg string) {
	decode[T]('') or {
		e := // separate binding: the old V compiler miscompiles the cast inside assert
		err as MarshalError
		assert e.kind == .unsupported
		assert err.msg() == msg, err.msg()
		return
	}
	assert false, 'no schema error for ${typeof[T]().name}'
}

fn test_schema_errors() {
	expect_schema_error[BadRoleAtTop]('a: a document has no arg to map; use it in a nested struct')
	expect_schema_error[Wrap[BadTwoRoles]]('inner.a: a field can only have one of `arg`, `args`, `props` and `child`')
	expect_schema_error[Wrap[BadWord]]('inner.a: unknown word `sometimes` in the kdl tag')
	expect_schema_error[Wrap[BadArgType]]('inner.a: the `arg` tag does not accept arrays')
	expect_schema_error[Wrap[BadArgAfterArgs]]('inner.b: an `arg` field must come before the `args` field')
	expect_schema_error[Wrap[BadOmitArg]]('inner.a: `omitempty` would shift the arguments that follow an `arg` field')
	expect_schema_error[Wrap[BadOptionArg]]('inner.a: the `arg` tag does not accept options')
	expect_schema_error[BadNameClash]('x: two fields use the node name `x`')
	expect_schema_error[BadNested]('a: unsupported field type [][]int')
	expect_schema_error[BadMap]('a: unsupported field type map[int]string, only map[string]scalar is supported')
	expect_schema_error[BadOptionList]('a: unsupported field type ?[]int')
	expect_schema_error[BadFixed]('a: unsupported field type [2]int')
	expect_schema_error[BadPointer]('leaf: unsupported field type &kdl.Leaf')
	expect_schema_error[BadFlag]('perms: unsupported field type kdl.Perm: flag enums have no single variant name')
	expect_schema_error[BadListOfPointers]('a: unsupported field type []&kdl.Leaf')
	expect_schema_error[BadMapOfFixed]('a: unsupported field type map[string][2]int, only map[string]scalar is supported')
	assert decode[Wrap[SkipWins]]('inner a=x v=y')! == Wrap[SkipWins]{}
	encode(BadNested{}) or {
		assert err.msg() == 'a: unsupported field type [][]int'
		return
	}
	assert false
}

fn test_root_must_be_a_struct() {
	encode(42) or {
		assert err.msg() == 'encode needs a struct, got int'
		return
	}
	assert false
}
