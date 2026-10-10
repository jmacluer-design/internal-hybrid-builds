fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'outbreak'
author 'Outbreak (private build)'
description 'Zombie survival + colony manager on a pure-Lua sim. Written blind against docs: see README.md'
version '0.2.0-pass2'

ui_page 'ui/index.html'

-- defines `require` over LoadResourceFile on BOTH sides (the sim ships sim/bootstrap.lua for exactly this)
shared_script 'shared/boot.lua'

server_script 'server/main.lua'
client_script 'client/main.lua'

-- LoadResourceFile on the client only sees files listed here (modules are loaded with require -> LoadResourceFile)
files {
	'sim/*.lua',
	'data/*.lua',
	'shared/*.lua',
	'client/*.lua',
	'ui/index.html',
	'ui/css/*.css',
	'ui/js/*.js',
	'ui/fonts/*.woff2',
}
