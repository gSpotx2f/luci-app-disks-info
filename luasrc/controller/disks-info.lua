
module('luci.controller.disks-info', package.seeall)

function index()
	if nixio.fs.access('/bin/df') and nixio.fs.access('/usr/sbin/fdisk') and nixio.fs.access('/usr/sbin/smartctl') then
		entry({'admin', 'services', 'disks-info'}, view('disks-info'), _('Disks info'), 10).acl_depends = { 'luci-app-disks-info' }
	end
end
