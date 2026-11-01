'use strict';

// Run from the repository root: node tests/view.js
const assert = require('assert');
const fs = require('fs');
const path = require('path');

// Minimal DOM and LuCI helpers for testing the rendered filesystem table.
function E(tag, attrs, children) {
	const node = {
		tag,
		children: [],
		append(...items) { this.children.push(...items); },
	};
	if(Array.isArray(tag)) {
		node.append(...tag);
	} else if(children != null) {
		node.append(...(Array.isArray(children) ? children : [children]));
	} else if(attrs && attrs.tag) {
		node.append(attrs);
	}
	return node;
}

const source = fs.readFileSync(path.join(__dirname,
	'../htdocs/luci-static/resources/view/disks-info.js'), 'utf8');
const view = new Function('document', 'E', 'view', '_', 'rpc', source)(
	{ head: { append() {} } }, E, { extend: obj => obj }, text => text,
	{ declare: () => () => {} });

function text(node) {
	return typeof node === 'string' ? node : (node.children || []).map(text).join(' ');
}

const filesystem = {
	filesystem: '/dev/md0', type: 'ext4', size: '1T', used: '400G',
	available: '600G', use_perc: '40%', mounted: '/srv/raid',
};

let output = text(view.createDiskTable({ diskInfo: [], partitions: [] }, [filesystem]));
assert(output.includes('/srv/raid'), 'Show mounted filesystems without a partition table');
assert(output.includes('No partitions available'));
assert(!output.includes('No mounted filesystems'));

output = text(view.createDiskTable({ diskInfo: [], partitions: [] }, []));
assert(output.includes('No partitions available'));
assert(output.includes('No mounted filesystems'), 'Show the empty filesystem placeholder');

output = text(view.createDiskTable({ diskInfo: [], partitions: [{ device: '/dev/sda1' }] }, [filesystem]));
assert(output.includes('/dev/sda1'));
assert(output.includes('/srv/raid'), 'Show mounted filesystems alongside partitions');
assert(!output.includes('No partitions available'));
assert(!output.includes('No mounted filesystems'));

console.log('All filesystem table tests passed.');
