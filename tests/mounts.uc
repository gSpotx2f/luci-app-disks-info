'use strict';

// Run from the repository root: ucode tests/mounts.uc
import { readfile as readSource } from 'fs';

let fixture;
let commands;

function assertEqual(actual, expected, message) {
	if(sprintf('%J', actual) != sprintf('%J', expected)) {
		die(sprintf('%s: expected %J, got %J\n', message, expected, actual));
	}
}

global.mockFs = {
	basename: path => pop(split(path, '/')),
	dirname: function(path) {
		let parts = split(path, '/');
		pop(parts);
		return join('/', parts);
	},
	readlink: path => fixture.paths[path],
	lsdir: path => path == '/dev' ? fixture.disks : fixture.dirs[path],
	readfile: path => path == '/proc/self/mountinfo' ? fixture.mountinfo : fixture.files[path],
	stat: path => fixture.stats[path],
	popen: function(cmd, mode) {
		push(commands, cmd);
		if(fixture.beforeDf && index(cmd, '/bin/df ') == 0) {
			fixture.beforeDf(cmd);
		}
		let output = fixture.outputs[cmd];
		if(index(cmd, '/usr/sbin/fdisk ') == 0) {
			output = 'Disk: test disk\n\nDevice Start End Sectors Size Type\n';
		}
		return { read: () => output, close: () => 0 };
	},
};

// Replace only the fs import; exercise the actual RPC implementation unchanged.
let source = readSource(ARGV[0] ?? 'root/usr/share/rpcd/ucode/luci.disks-info');
source = replace(source, /import \{[^}]+\} from 'fs';/,
	'let basename = global.mockFs.basename, dirname = global.mockFs.dirname, lsdir = global.mockFs.lsdir, popen = global.mockFs.popen, readfile = global.mockFs.readfile, readlink = global.mockFs.readlink, stat = global.mockFs.stat;');
let backend = loadstring(source)()['luci.disks-info'];

function reset(disks) {
	fixture = { disks, dirs: {}, files: {}, paths: {}, stats: {}, mountinfo: '', outputs: {} };
	commands = [];
}

function block(name, id, holders, partitions) {
	let path = '/sys/class/block/' + name;
	fixture.files[path + '/dev'] = id + '\n';
	fixture.dirs[path + '/holders'] = holders ?? [];
	fixture.dirs[path] = partitions ?? [];
	for(let partition in partitions ?? []) {
		fixture.files[path + '/' + partition + '/partition'] = '1\n';
	}
}

function mount(id, path, source, command) {
	fixture.mountinfo += sprintf('10 1 %s / %s rw shared:1 - ext4 %s rw\n', id, path, source);
	let decodedPath = replace(path, /\\(040|011|012|134)/g,
		(_, octal) => sprintf('%c', int(octal, 8)));
	let numbers = split(id, ':');
	fixture.stats[decodedPath] = { dev: { major: int(numbers[0]), minor: int(numbers[1]) } };
	let decodedSource = replace(source, /\\(040|011|012|134)/g,
		(_, octal) => sprintf('%c', int(octal, 8)));
	fixture.stats[decodedSource] = { type: 'block' };
	command = command ?? sprintf("/bin/df -PTh '%s' 2> /dev/null", path);
	fixture.outputs[command] = sprintf('Filesystem Type Size Used Available Use%% Mounted on\n%s ext4 1T 400G 600G 40%% %s\n', source, path);
}

function filesystems(disk) {
	return backend.getDevices.call().df['/dev/' + disk];
}

function mountPaths(rows) {
	return map(rows, row => row.mounted);
}

reset(['sda', 'sdb']);
block('sda', '8:0', [], ['sda3']);
block('sda3', '8:3', ['md2']);
block('sdb', '8:16', [], ['sdb3']);
block('sdb3', '8:19', ['md2']);
block('md2', '9:2', ['dm-0']);
block('dm-0', '253:0');
mount('253:0', '/mnt/media', '/dev/dm-0');
let result = backend.getDevices.call();
for(let disk in ['sda', 'sdb']) {
	assertEqual(result.df['/dev/' + disk], [{
		filesystem: '/dev/dm-0', type: 'ext4', size: '1T', used: '400G',
		available: '600G', use_perc: '40%', mounted: '/mnt/media',
	}], 'RAID and device-mapper chain on ' + disk);
}
assertEqual(length(filter(commands, cmd => index(cmd, '/bin/df ') == 0)), 1, 'shared mount queried once');

reset(['sda', 'sdb']);
block('sda', '8:0', [], ['sda1', 'sda2']);
block('sda1', '8:1', ['md127']);
block('sda2', '8:2', ['md127']);
block('sdb', '8:16', [], ['sdb1']);
block('sdb1', '8:17', ['md127']);
block('md127', '9:127');
mount('9:127', '/srv/raid', '/dev/md/storage');
mount('8:17', '/srv/other-disk', '/dev/sdb1');
assertEqual(mountPaths(filesystems('sda')), ['/srv/raid'], 'named array, deduplication and no sibling mounts');

reset(['nvme0n1']);
block('nvme0n1', '259:0', [], ['nvme0n1p1', 'nvme0n1p2']);
block('nvme0n1p1', '259:1');
block('nvme0n1p2', '259:2');
mount('259:1', '/srv/data', '/dev/disk/by-uuid/example');
mount('259:1', '/srv/bind', '/dev/nvme0n1p1');
mount('259:2', '/srv/second', '/dev/nvme0n1p2');
assertEqual(mountPaths(filesystems('nvme0n1')), ['/srv/data', '/srv/bind', '/srv/second'], 'direct partitions, aliases and bind mounts');

reset(['sda']);
block('sda', '8:0');
mount('8:0', '/srv/whole-disk', '/dev/sda');
assertEqual(mountPaths(filesystems('sda')), ['/srv/whole-disk'], 'filesystem without a partition table');

reset(['sda']);
block('sda', '8:0', [], ['sda1']);
block('sda1', '8:1', ['md0']);
block('md0', '9:0');
fixture.paths['/dev/md/storage'] = '/dev/md0';
mount('0:42', '/srv/subvolume', '/dev/md/storage');
fixture.mountinfo = replace(fixture.mountinfo, 'ext4', 'btrfs');
assertEqual(mountPaths(filesystems('sda')), ['/srv/subvolume'], 'anonymous filesystem device with a named source alias');

reset(['sda']);
block('sda', '8:0', ['dm-0']);
block('dm-0', '253:0');
fixture.paths['/dev/disk/by-uuid/example'] = '../../mapper/storage';
fixture.paths['/dev/disk/by-uuid/../../mapper/storage'] = '../dm-0';
mount('0:42', '/srv/relative-alias', '/dev/disk/by-uuid/example');
assertEqual(mountPaths(filesystems('sda')), ['/srv/relative-alias'], 'chained relative device aliases');

reset(['sda']);
block('sda', '8:0', ['md0']);
block('md0', '9:0', [], ['md0p1']);
block('md0p1', '259:1');
mount('259:1', '/srv/array-partition', '/dev/md0p1');
assertEqual(mountPaths(filesystems('sda')), ['/srv/array-partition'], 'whole-disk RAID member and partitioned array');

reset(['sda']);
block('sda', '8:0', ['md0']);
block('md0', '9:0', ['dm-0', 'dm-1']);
block('dm-0', '253:0', ['md0']); // Simulate a cycle during topology changes.
block('dm-1', '253:1');
mount('253:0', '/srv/one', '/dev/mapper/first');
mount('253:1', '/srv/two', '/dev/mapper/second');
assertEqual(mountPaths(filesystems('sda')), ['/srv/one', '/srv/two'], 'multiple logical volumes and cycle protection');

reset(['sda']);
block('sda', '8:0', [], ['sda1', 'sda2']);
block('sda1', '8:1');
// sda2 disappeared between lsdir() and readfile().
mount('8:1', '/srv/gone', '/dev/sda1');
fixture.outputs = {};
assertEqual(filesystems('sda'), [], 'unavailable mount and disappearing device');
assertEqual(length(filter(commands, cmd => index(cmd, '/bin/df ') == 0)), 1, 'unmounted devices never passed to df');

reset(['sda']);
block('sda', '8:0');
mount('8:0', '/srv/space\\040and\'quote', '/dev/sda',
	"/bin/df -PTh '/srv/space and'\\''quote' 2> /dev/null");
assertEqual(mountPaths(filesystems('sda')), ["/srv/space and'quote"], 'escaped spaces and shell quoting');

reset(['sda']);
block('sda', '8:0', ['dm-0']);
block('dm-0', '253:0');
mount('253:0', '/srv/long-name', '/dev/mapper/a\\040long\\040volume');
fixture.outputs["/bin/df -PTh '/srv/long-name' 2> /dev/null"] =
	'Filesystem Type Size Used Available Use% Mounted on\n/dev/mapper/a long volume ext4 1T 400G 600G 40% /srv/long-name\n';
assertEqual(filesystems('sda')[0].size, '1T', 'filesystem names containing spaces');

fixture.outputs["/bin/df -PTh '/srv/long-name' 2> /dev/null"] =
	'Filesystem Type Size Used Available Use% Mounted on\n/dev/mapper/a ext4 9T 8T 1T 89% volume ext4 1T 400G 600G 40% /srv/long-name\n';
assertEqual(filesystems('sda')[0].size, '1T', 'usage-like text in a filesystem name');

reset(['sda']);
block('sda', '8:0');
mount('8:0', '/srv/tab\\011newline\\012backslash\\134040', '/dev/sda',
	"/bin/df -PTh '/srv/tab\tnewline\nbackslash\\040' 2> /dev/null");
assertEqual(mountPaths(filesystems('sda')), ['/srv/tab\tnewline\nbackslash\\040'], 'mount escapes decoded once');

reset(['sda']);
block('sda', '8:0');
fixture.mountinfo = null;
assertEqual(filesystems('sda'), [], 'missing mountinfo');

reset(['sda']);
block('sda', '8:0');
mount('8:0', '/srv/covered', '/dev/sda');
fixture.stats['/srv/covered'] = { dev: { major: 0, minor: 99 } };
assertEqual(filesystems('sda'), [], 'mount covered by another filesystem');
assertEqual(length(filter(commands, cmd => index(cmd, '/bin/df ') == 0)), 0, 'covered mounts are not queried');

reset(['sda']);
block('sda', '8:0');
mount('8:0', '/srv/removed', '/dev/sda');
fixture.beforeDf = () => { fixture.stats['/srv/removed'] = null; };
assertEqual(filesystems('sda'), [], 'mount removed while df runs');

reset(['sda', 'sdb']);
block('sda', '8:0');
block('sdb', '8:16');
mount('8:0', '/srv/shared-path', '/dev/sda');
mount('8:16', '/srv/shared-path', '/dev/sdb');
result = backend.getDevices.call();
assertEqual(result.df['/dev/sda'], [], 'hidden mount is omitted');
assertEqual(result.df['/dev/sdb'][0].filesystem, '/dev/sdb', 'visible mount does not reuse hidden mount metadata');

reset(['sda']);
block('sda', '8:0');
mount('8:16', '/srv/reused-source', '/dev/sda');
assertEqual(filesystems('sda'), [], 'a reused source path must not override a real filesystem device number');

reset([]);
assertEqual(backend.getDevices.call(), {}, 'no physical disks');

print('All mount discovery tests passed.\n');
