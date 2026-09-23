// Encodes a V struct to KDL and decodes KDL back into structs, with field tags
// and renaming.
// Adapted from the marshal_unmarshal example of github.com/vlang-community/kdl
// by Jengro777.
// Run with: v run examples/structs/main.v
module main

import kdl

struct Package {
	name    string @[kdl: 'arg']
	version string
}

struct Build {
	command string            @[kdl: 'arg']
	targets []string          @[kdl: 'args']
	env     map[string]string @[kdl: 'props']
}

struct Config {
	app          Package
	dependencies []Package @[kdl: 'dep']
	build        Build
	active       bool
	max_jobs     int = 4
	notes        string @[omitempty]
}

fn main() {
	cfg := Config{
		app:          Package{
			name:    'my-app'
			version: '1.2.3'
		}
		dependencies: [Package{
			name:    'libA'
			version: '^3.2'
		}, Package{
			name:    'libB'
			version: '^1.0'
		}]
		build:        Build{
			command: 'v'
			targets: ['-prod', '.']
			env:     {
				'VFLAGS': '-cc clang'
			}
		}
		active:       true
	}
	println('--- encode ---')
	text := kdl.encode(cfg)!
	print(text)

	println('--- decode ---')
	back := kdl.decode[Config](text)!
	assert back == cfg
	println('decoded struct equal to the original')
	println('dependencies: ${back.dependencies.map(it.name)}')

	println('--- kebab-case names ---')
	print(kdl.encode(cfg, rename: .kebab_case)!)

	println('--- errors carry the path of the field ---')
	if _ := kdl.decode[Config]('max-jobs two', rename: .kebab_case) {
		panic('the document should have been rejected')
	} else {
		println(err.msg())
	}
}
