// Builds a document in code, writes it to a file, reads it back, changes it
// and checks the result.
// Adapted from the document_building and file_io examples of
// github.com/vlang-community/kdl by Jengro777.
// Run with: v run examples/build/main.v
module main

import kdl
import os

fn str_value(s string) kdl.Value {
	return kdl.Value{
		data: s
	}
}

fn main() {
	mut server := kdl.Node{
		name: 'server'
	}
	server.properties['host'] = str_value('0.0.0.0')
	server.properties['port'] = kdl.Value{
		data: i64(8080)
	}
	server.children << kdl.Node{
		name:       'tls'
		arguments:  [kdl.Value{
			data: true
		}]
		properties: {
			'cert': str_value('/etc/ssl/cert.pem')
		}
	}
	for path, handler in {
		'/':    'index'
		'/api': 'api'
	} {
		server.children << kdl.Node{
			name:       'route'
			arguments:  [str_value(path)]
			properties: {
				'handler': str_value(handler)
			}
		}
	}
	mut doc := kdl.Document{
		nodes: [server]
	}
	doc.nodes << kdl.Node{
		name:       'logging'
		properties: {
			'level':  str_value('info')
			'format': str_value('json')
		}
	}

	path := os.join_path(os.temp_dir(), 'kdl_build_example_${os.getpid()}.kdl')
	defer {
		os.rm(path) or {}
	}
	os.write_file(path, doc.str())!
	println('--- written to ${os.file_name(path)} ---')
	print(os.read_file(path)!)

	mut loaded := kdl.parse_file(path)!
	assert loaded.equals(doc)
	println('--- read back: equal to the original ---')

	// documents are plain structs: change them in place and write them again
	loaded.nodes[1].properties['level'] = str_value('debug')
	loaded.nodes[0].children = loaded.nodes[0].children.filter(it.name != 'tls')
	os.write_file(path, loaded.str())!
	updated := kdl.parse_file(path)!
	logging := updated.get('logging') or { panic('no logging node') }
	assert logging.prop('level').as_string() or { '' } == 'debug'
	assert updated.nodes[0].child('tls') == none
	println('--- updated: level is debug and tls is gone ---')
	print(updated)
}
