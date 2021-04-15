/*
 * Copyright (C)2005-2016 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */
package haxelib.client;

import haxe.Http;
import haxe.crypto.Md5;
import haxe.io.BytesOutput;
import haxe.io.Path;
import haxe.zip.*;

import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

import haxelib.client.Vcs;
import haxelib.client.Util.*;
import haxelib.client.FsUtils.*;
import haxelib.client.Cli;
import haxelib.client.RepoManager.RepoException;
import haxelib.client.Args.ParsingFail;

using StringTools;
using Lambda;
using haxelib.Data;

private enum CommandCategory {
	Basic;
	Information;
	Development;
	Miscellaneous;
	Deprecated(msg:String);
}

class SiteProxy extends haxe.remoting.Proxy<haxelib.SiteApi> {
}

class Main {
	static final HAXELIB_LIBNAME = "haxelib";

	static final VERSION:SemVer = SemVer.ofString(getHaxelibVersion());
	static final VERSION_LONG:String = getHaxelibVersionLong();
	static final SERVER = {
		protocol : "https",
		host : "lib.haxe.org",
		port : 443,
		dir : "",
		url : "index.n",
		apiVersion : "3.0",
		noSsl : false
	};

	final isHaxelibRun : Bool;
	final args : Args;
	final settings : {
		debug : Bool,
		quiet : Bool,
		flat : Bool,
		global : Bool,
		system : Bool,
		skipDependencies : Bool,
	};
	final commands : List<{ name : String, doc : String, f : Void -> Void, net : Bool, cat : CommandCategory }>;

	final siteUrl : String;
	final site : SiteProxy;
	final alreadyUpdatedVcsDependencies:Map<String,String> = new Map<String,String>();

	function new(argsArray:Array<String>, isHaxelibRun:Bool) {
		this.isHaxelibRun = isHaxelibRun;

		try {
			args = new Args(argsArray);
		}catch(e:ParsingFail) {
			Cli.showError(e.message);
			Sys.exit(1);
		}
		final allSettings = args.getAllSettings();

		// argument parsing takes care of mutual exclusivity
		final defaultAnswer =
			if (!allSettings.always && !allSettings.never) null // neither specified
			else (allSettings.always && !allSettings.never); // boolean logic
		final cliMode:OutputMode = if (allSettings.debug) Debug else if (allSettings.quiet) Quiet else None;

		Cli.set(defaultAnswer, cliMode);

		updateCwd(allSettings.cwd);

		final siteInfo = initRemote(allSettings.noTimeout, allSettings.remote);
		siteUrl = siteInfo.url;
		site = siteInfo.site;

		settings = {
			debug: allSettings.debug,
			quiet: allSettings.quiet,
			flat: allSettings.flat,
			global: allSettings.global,
			system: allSettings.system,
			skipDependencies: allSettings.skipDependencies
		};

		commands = createCommandsList();
	}

	function createCommandsList(): List<{ name : String, doc : String, f : Void -> Void, net : Bool, cat : CommandCategory }> {
		final commands = new List();
		function addCommand(name, f, doc, cat, ?net = true)
			commands.add({name: name, doc: doc, f: f, net: net, cat: cat});

		addCommand("install", install, "install a given library, or all libraries from a hxml file", Basic);
		addCommand("update", update, "update a single library (if given) or all installed libraries", Basic);
		addCommand("remove", remove, "remove a given library/version", Basic, false);
		addCommand("list", list, "list all installed libraries", Basic, false);
		addCommand("set", set, "set the current version for a library", Basic, false);

		addCommand("search", search, "list libraries matching a word", Information);
		addCommand("info", info, "list information on a given library", Information);
		addCommand("user", user, "list information on a given user", Information);
		addCommand("config", config, "print the repository path", Information, false);
		addCommand("path", path, "give paths to libraries' sources and necessary build definitions", Information, false);
		addCommand("libpath", libpath, "returns the root path of a library", Information, false);
		addCommand("version", version, "print the currently used haxelib version", Information, false);
		addCommand("help", usage, "display this list of options", Information, false);

		addCommand("submit", submit, "submit or update a library package", Development);
		addCommand("register", register, "register a new user", Development);
		addCommand("dev", dev, "set the development directory for a given library", Development, false);
		//TODO: generate command about VCS by Vcs.getAll()
		addCommand("git", vcs.bind(VcsID.Git), "use Git repository as library", Development);
		addCommand("hg", vcs.bind(VcsID.Hg), "use Mercurial (hg) repository as library", Development);

		addCommand("setup", setup, "set the haxelib repository path", Miscellaneous, false);
		addCommand("newrepo", newRepo, "create a new local repository", Miscellaneous, false);
		addCommand("deleterepo", deleteRepo, "delete the local repository", Miscellaneous, false);
		addCommand("convertxml", convertXml, "convert haxelib.xml file to haxelib.json", Miscellaneous);
		addCommand("run", run, "run the specified library with parameters", Miscellaneous, false);
		addCommand("proxy", proxy, "setup the Http proxy", Miscellaneous);

		// deprecated commands
		addCommand("local", local, "install the specified package locally", Deprecated("Use `haxelib install <file>` instead"), false);
		addCommand("selfupdate", updateSelf, "update haxelib itself", Deprecated('Use `haxelib --global update $HAXELIB_LIBNAME` instead'));
		return commands;
	}

	static function updateCwd(directories:Null<Array<String>>) {
		if (directories == null)
			return;
		for (dir in directories) {
			try {
				Sys.setCwd(dir);
			} catch (e:String) {
				if (e == "std@set_cwd") {
					Cli.showError('Directory $dir unavailable');
					Sys.exit(1);
				}
				rethrow(e);
			}
		}
	}

	static function setCustomRemote(path:String) {
		final r = ~/^(?:(https?):\/\/)?([^:\/]+)(?::([0-9]+))?\/?(.*)$/;
		if (!r.match(path))
			throw "Invalid repository format '" + path + "'";

		final customProtocol = r.matched(1);
		if(r.matched(1) != null)
			SERVER.protocol = customProtocol;

		SERVER.host = r.matched(2);
		SERVER.port = {
			final portStr = r.matched(3);
			if (portStr == null)
				switch (SERVER.protocol) {
					case "https": 443;
					case "http": 80;
					case protocol: throw 'unknown default port for $protocol';
				}
			Std.parseInt(portStr);
		}

		SERVER.dir = {
			final dir = r.matched(4);
			if (dir.length > 0 && !dir.endsWith("/"))
				dir + "/";
			dir;
		}
		trace(SERVER);
	}

	static function initRemote(noTimeout:Bool, remote:Null<String>):{
		url:String,
		site:SiteProxy
	} {
		final noSsl = Sys.getEnv("HAXELIB_NO_SSL");

		if (noSsl == "1" || noSsl == "true") {
			SERVER.noSsl = true;
			SERVER.protocol = "http";
		}
		if (noTimeout)
			haxe.remoting.HttpConnection.TIMEOUT = 0;

		if (remote == null)
			remote = Sys.getEnv("HAXELIB_REMOTE");

		if (remote != null)
			setCustomRemote(remote);

		final siteUrl = '${SERVER.protocol}://${SERVER.host}:${SERVER.port}/${SERVER.dir}';
		final remotingUrl = '${siteUrl}api/${SERVER.apiVersion}/${SERVER.url}';
		final site = new SiteProxy(haxe.remoting.HttpConnection.urlConnect(remotingUrl).resolve("api"));

		return {
			url: siteUrl,
			site: site
		}
	}

	function retry<R>(func:Void -> R, numTries:Int = 3) {
		var hasRetried = false;

		while (numTries-- > 0) {
			try {
				var result = func();

				if (hasRetried) Cli.print("retry sucessful");

				return result;
			} catch (e:Dynamic) {
				if ( e == "Blocked") {
					Cli.print("Failed. Triggering retry due to HTTP timeout");
					hasRetried = true;
				}
				else {
					throw 'Failed with error: $e';
				}
			}
		}
		throw 'Failed due to HTTP timeout after multiple retries';
	}

	function checkUpdate() {
		final latest = try retry(site.getLatestVersion.bind(HAXELIB_LIBNAME)) catch (_:Dynamic) null;
		if (latest != null && latest > VERSION)
			Cli.print('\nA new version ($latest) of haxelib is available.\nDo `haxelib --global update $HAXELIB_LIBNAME` to get the latest version.\n');
	}

	function getArgument(prompt:String){
		final given = args.getNext();
		if (given != null)
			return given;
		return Cli.getInput(prompt);
	}

	function getSecretArgument(prompt:String) {
		final given = args.getNext();
		if (given != null)
			return given;
		return Cli.getSecretInput(prompt);
	}

	function getSafeArgument(prompt:String) {
		final value = getArgument(prompt);
		if (!Data.isSafe(value))
			throw 'Invalid parameter : $value';
		return value;
	}

	function version() {
		final params = args.getNext();
		if ( params == null )
			Cli.print(VERSION_LONG);
		else {
			Cli.showError('no parameters expected, got: ${params}');
			Sys.exit(1);
		}
	}

	function usage() {
		var maxLength = 0;

		final switches = Args.getSwitchInfo();
		for (option in switches){
			final length = '--${option.name}'.length;
			if(length > maxLength)
				maxLength = length;
		}

		final cats = [];
		for( c in commands ) {
			if (c.name.length > maxLength) maxLength = c.name.length;
			if (c.cat.match(Deprecated(_))) continue;
			final i = c.cat.getIndex();
			if (cats[i] == null) cats[i] = [c];
			else cats[i].push(c);
		}

		Cli.print('Haxe Library Manager $VERSION - (c)2006-2019 Haxe Foundation');
		Cli.print("  Usage: haxelib [command] [options]");

		for (cat in cats) {
			Cli.print("  " + cat[0].cat.getName());
			for (c in cat) {
				Cli.print("    " + c.name.rpad(" ", maxLength) + ": " +c.doc);
			}
		}
		Cli.print("  Available switches");
		for (option in switches) {
			Cli.print('    --' + option.name.rpad(' ', maxLength-2) + ': ' + option.description);
		}
	}

	function process() {
		if (!isHaxelibRun && !settings.system) {
			var rep = try RepoManager.getGlobalRepository() catch (_:Dynamic) null;
			if (rep != null && FileSystem.exists(rep + HAXELIB_LIBNAME)) {
				try {
					doRun(rep, HAXELIB_LIBNAME, args.copyOriginal()); // send all arguments
					return;
				} catch(e:Dynamic) {
					Cli.showWarning('failed to run updated haxelib: $e');
					Cli.showWarning('resorting to system haxelib...');
				}
			}
		}

		final cmd = switch(args.getNext()){
			case null:
				usage();
				Sys.exit(1);
				""; // to please the compiler
			case "upgrade":
				"update"; // TODO: maybe we should have some alias system
			case cmd:
				cmd;
		}

		for( c in commands )
			if (c.name == cmd) {
				if (c.cat.match(Deprecated(_))){
					final message = c.cat.getParameters()[0];
					Cli.showWarning('Command `$cmd` is deprecated and will be removed in future. $message.');
				}
				try {
					if( c.net ) {
						loadProxy();
						checkUpdate();
					}
					c.f();
				} catch( e : Dynamic ) {
				switch(e){
					case "std@host_resolve":
						Cli.print('Host ${SERVER.host} was not found');
						Cli.print("Please ensure that your internet connection is on");
						Cli.print("If you don't have an internet connection or if you are behing a proxy");
						Cli.print("please download manually the file from https://lib.haxe.org/files/3.0/");
						Cli.print("and run 'haxelib local <file>' to install the Library.");
						Cli.print("You can also setup the proxy with 'haxelib proxy'.");
						Cli.print(haxe.CallStack.toString(haxe.CallStack.exceptionStack()));
						Sys.exit(1);
					case "Blocked":
						Cli.print("Http connection timeout. Try running haxelib -notimeout <command> to disable timeout");
						Sys.exit(1);
					case "std@get_cwd":
						Cli.showError("Current working directory is unavailable");
						Sys.exit(1);
					case e if(settings.debug):
						rethrow(e);
					case e:
						Cli.showError(Std.string(e));
						Sys.exit(1);
				}
				}
				return;
			}
		Cli.showError('Unknown command: $cmd');
		usage();
		Sys.exit(1);
	}

	inline function createHttpRequest(url:String):Http {
		var req = new Http(url);
		req.addHeader("User-Agent", 'haxelib $VERSION_LONG');
		if (haxe.remoting.HttpConnection.TIMEOUT == 0)
			req.cnxTimeout = 0;
		return req;
	}

	// ---- COMMANDS --------------------

 	function search() {
		final word = getArgument("Search word");
		final l = retry(site.search.bind(word));
		for( s in l )
			Cli.print(s.name);
		Cli.print('${l.length} libraries found');
	}

	function info() {
		final prj = getArgument("Library name");
		final inf = retry(site.infos.bind(prj));
		Cli.print("Name: "+inf.name);
		Cli.print("Tags: "+inf.tags.join(", "));
		Cli.print("Desc: "+inf.desc);
		Cli.print("Website: "+inf.website);
		Cli.print("License: "+inf.license);
		Cli.print("Owner: "+inf.owner);
		Cli.print("Version: "+inf.getLatest());
		Cli.print("Releases: ");
		if( inf.versions.length == 0 )
			Cli.print("  (no version released yet)");
		for( v in inf.versions )
			Cli.print("   "+v.date+" "+v.name+" : "+v.comments);
	}

	function user() {
		final uname = getArgument("User name");
		final inf = retry(site.user.bind(uname));
		Cli.print("Id: "+inf.name);
		Cli.print("Name: "+inf.fullname);
		Cli.print("Mail: "+inf.email);
		Cli.print("Libraries: ");
		if( inf.projects.length == 0 )
			Cli.print("  (no libraries)");
		for( p in inf.projects )
			Cli.print("  "+p);
	}

	function register() {
		doRegister(getArgument("User"));
		Cli.print("Registration successful");
	}

	function doRegister(name) {
		final email = getArgument("Email");
		final fullname = getArgument("Fullname");
		final pass = getSecretArgument("Password");
		final pass2 = getSecretArgument("Confirm");
		if( pass != pass2 )
			throw "Password does not match";
		final encodedPassword = Md5.encode(pass);
		retry(site.register.bind(name, encodedPassword, email, fullname));
		return pass;
	}

	function zipDirectory(root:String):List<Entry> {
		var ret = new List<Entry>();
		function seek(dir:String) {
			for (name in FileSystem.readDirectory(dir)) if (!name.startsWith('.')) {
				var full = '$dir/$name';
				if (FileSystem.isDirectory(full)) seek(full);
				else {
					var blob = File.getBytes(full);
					var entry:Entry = {
						fileName: full.substr(root.length+1),
						fileSize : blob.length,
						fileTime : FileSystem.stat(full).mtime,
						compressed : false,
						dataSize : blob.length,
						data : blob,
						crc32: haxe.crypto.Crc32.make(blob),
					};
					Tools.compress(entry, 9);
					ret.push(entry);
				}
			}
		}
		seek(root);
		return ret;
	}

	function submit() {
		final file = getArgument("Package");

		var data, zip;
		if (FileSystem.isDirectory(file)) {
			zip = zipDirectory(file);
			var out = new BytesOutput();
			new Writer(out).write(zip);
			data = out.getBytes();
		} else {
			data = File.getBytes(file);
			zip = Reader.readZip(new haxe.io.BytesInput(data));
		}

		var infos = Data.readInfos(zip,true);
		Data.checkClassPath(zip, infos);

		var user:String = infos.contributors[0];

		if (infos.contributors.length > 1)
			do {
				Cli.print("Which of these users are you: " + infos.contributors);
				user = getArgument("User");
			} while ( infos.contributors.indexOf(user) == -1 );

		var password;
		if( retry(site.isNewUser.bind(user)) ) {
			Cli.print("This is your first submission as '"+user+"'");
			Cli.print("Please enter the following information for registration");
			password = doRegister(user);
		} else {
			password = readPassword(user);
		}
		retry(site.checkDeveloper.bind(infos.name,user));

		// check dependencies validity
		for( d in infos.dependencies ) {
			var infos = retry(site.infos.bind(d.name));
			if( d.version == "" )
				continue;
			var found = false;
			for( v in infos.versions )
				if( v.name == d.version ) {
					found = true;
					break;
				}
			if( !found )
				throw "Library " + d.name + " does not have version " + d.version;
		}

		// check if this version already exists

		var sinfos = try retry(site.infos.bind(infos.name)) catch( _ : Dynamic ) null;
		if( sinfos != null )
			for( v in sinfos.versions )
				if( v.name == infos.version && !Cli.ask('You\'re about to overwrite existing version \'${v.name}\', please confirm') )
					throw "Aborted";

		// query a submit id that will identify the file
		var id = retry(site.getSubmitId.bind());

		// directly send the file data over Http
		var h = createHttpRequest(SERVER.protocol+"://"+SERVER.host+":"+SERVER.port+"/"+SERVER.url);
		h.onError = function(e) throw e;
		h.onData = Cli.print;

		final inp = Cli.createUploadInput(data);

		h.fileTransfer("file", id, inp, data.length);
		Cli.print("Sending data.... ");
		h.request(true);

		// processing might take some time, make sure we wait
		Cli.print("Processing file.... ");
		if (haxe.remoting.HttpConnection.TIMEOUT != 0) // don't ignore -notimeout
			haxe.remoting.HttpConnection.TIMEOUT = 1000;
		// ask the server to register the sent file
		var msg = retry(site.processSubmit.bind(id,user,password));
		Cli.print(msg);
	}

	function readPassword(user:String, prompt = "Password"):String {
		var password = Md5.encode(getSecretArgument(prompt));
		var attempts = 5;
		while (!retry(site.checkPassword.bind(user, password))) {
			Cli.print('Invalid password for $user');
			if (--attempts == 0)
				throw 'Failed to input correct password';
			password = Md5.encode(getSecretArgument('$prompt ($attempts more attempt${attempts == 1 ? "" : "s"})'));
		}
		return password;
	}

	function install() {
		final rep = getRepository();

		final prj = getArgument("Library name or hxml file");

		// No library given, install libraries listed in *.hxml in given directory
		if( prj == "all") {
			installFromAllHxml(rep);
			return;
		}

		if( sys.FileSystem.exists(prj) && !sys.FileSystem.isDirectory(prj) ) {
			switch(prj){
				case hxml if (hxml.endsWith(".hxml")):
					// *.hxml provided, install all libraries/versions in this hxml file
					installFromHxml(rep, hxml);
					return;
				case zip if (zip.endsWith(".zip")):
					// *.zip provided, install zip as haxe library
					doInstallFile(rep, zip, true, true);
					return;
				case jsonPath if(jsonPath.endsWith("haxelib.json")):
					installFromHaxelibJson(rep, jsonPath);
					return;
			}
		}

		// Name provided that wasn't a local hxml or zip, so try to install it from server
		final inf = retry(site.infos.bind(prj));
		final reqversion = args.getNext();
		final version = getVersion(inf, reqversion);
		doInstall(rep, inf.name, version, version == inf.getLatest());
	}

	function getVersion( inf:ProjectInfos, ?reqversion:String ) {
		if( inf.versions.length == 0 )
			throw "The library "+inf.name+" has not yet released a version";
		var version = if( reqversion != null ) reqversion else inf.getLatest();
		var found = false;
		for( v in inf.versions )
			if( v.name == version ) {
				found = true;
				break;
			}
		if( !found )
			throw "No such version "+version+" for library "+inf.name;

		return version;
	}

	function installFromHxml( rep:String, path:String ) {
		var targets  = [
			'-java ' => 'hxjava',
			'-cpp ' => 'hxcpp',
			'-cs ' => 'hxcs',
		];
		var libsToInstall = new Map<String, {name:String,version:String,type:String,url:String,branch:String,subDir:String}>();

		function processHxml(path) {
			var hxml = normalizeHxml(sys.io.File.getContent(path));
			var lines = hxml.split("\n");
			for (l in lines) {
				l = l.trim();

				for (target in targets.keys())
					if (l.startsWith(target)) {
						var lib = targets[target];
						if (!libsToInstall.exists(lib))
							libsToInstall[lib] = { name: lib, version: null, type:"haxelib", url: null, branch: null, subDir: null }
					}

				var libraryFlagEReg = ~/^(-lib|-L|--library)\b/;
				if (libraryFlagEReg.match(l))
				{
					var key = libraryFlagEReg.matchedRight().trim();
					var parts = ~/:/.split(key);
					var libName = parts[0];
					var libVersion:String = null;
					var branch:String = null;
					var url:String = null;
					var subDir:String = null;
					var type:String;

					if ( parts.length > 1 )
					{
						if ( parts[1].startsWith("git:") )
						{

							type = "git";
							var urlParts = parts[1].substr(4).split("#");
							url = urlParts[0];
							branch = urlParts.length > 1 ? urlParts[1] : null;
						}
						else
						{
							type = "haxelib";
							libVersion = parts[1];
						}
					}
					else
					{
						type = "haxelib";
					}

					switch libsToInstall[key] {
						case null, { version: null } :
							libsToInstall.set(key, { name:libName, version:libVersion, type: type, url: url, subDir: subDir, branch: branch } );
						default:
					}
				}

				if (l.endsWith(".hxml"))
					processHxml(l);
			}
		}
		processHxml(path);

		if (Lambda.empty(libsToInstall))
			return;

		// Check the version numbers are all good
		// TODO: can we collapse this into a single API call?  It's getting too slow otherwise.
		Cli.print("Loading info about the required libraries");
		for (l in libsToInstall)
		{
			if ( l.type == "git" )
			{
				// Do not check git repository infos
				continue;
			}
			var inf = retry(site.infos.bind(l.name));
			l.version = getVersion(inf, l.version);
		}

		// Print a list with all the info
		Cli.print("Haxelib is going to install these libraries:");
		for (l in libsToInstall) {
			var vString = (l.version == null) ? "" : " - " + l.version;
			Cli.print("  " + l.name + vString);
		}

		// Install if they confirm
		if (Cli.ask("Continue?")) {
			for (l in libsToInstall) {
				if ( l.type == "haxelib" )
					doInstall(rep, l.name, l.version, true);
				else if ( l.type == "git" )
					useVcs(VcsID.Git, function(vcs) doVcsInstall(rep, vcs, l.name, l.url, l.branch, l.subDir, l.version));
				else if ( l.type == "hg" )
					useVcs(VcsID.Hg, function(vcs) doVcsInstall(rep, vcs, l.name, l.url, l.branch, l.subDir, l.version));
			}
		}
	}

	function installFromHaxelibJson( rep:String, path:String ) {
		doInstallDependencies(rep, Data.readData(File.getContent(path), false).dependencies);
	}

	function installFromAllHxml(rep:String) {
		var cwd = Sys.getCwd();
		var hxmlFiles = sys.FileSystem.readDirectory(cwd).filter(function (f) return f.endsWith(".hxml"));
		if (hxmlFiles.length > 0) {
			for (file in hxmlFiles) {
				Cli.print('Installing all libraries from $file:');
				installFromHxml(rep, cwd + file);
			}
		} else {
			Cli.print("No hxml files found in the current directory.");
		}
	}

	// strip comments, trim whitespace from each line and remove empty lines
	function normalizeHxml(hxmlContents: String) {
		return ~/\r?\n/g.split(hxmlContents).map(StringTools.trim).filter(function(line) {
			return line != "" && !line.startsWith("#");
		}).join('\n');
	}

	// maxRedirect set to 20, which is most browsers' default value according to https://stackoverflow.com/a/36041063/267998
	function download(fileUrl:String, outPath:String, maxRedirect = 20):Void {
		var out = try File.append(outPath,true) catch (e:Dynamic) throw 'Failed to write to $outPath: $e';
		out.seek(0, SeekEnd);

		var h = createHttpRequest(fileUrl);

		var currentSize = out.tell();
		if (currentSize > 0)
			h.addHeader("range", "bytes="+currentSize + "-");

		final progress = Cli.createDownloadOutput(out, currentSize);

		var httpStatus = -1;
		var redirectedLocation = null;
		h.onStatus = function(status) {
			httpStatus = status;
			switch (httpStatus) {
				case 301, 302, 307, 308:
					switch (h.responseHeaders.get("Location")) {
						case null:
							throw 'Request to $fileUrl responded with $httpStatus, ${h.responseHeaders}';
						case location:
							redirectedLocation = location;
					}
				default:
					// TODO?
			}
		};
		h.onError = function(e) {
			progress.close();

			switch(httpStatus) {
				case 416:
					// 416 Requested Range Not Satisfiable, which means that we probably have a fully downloaded file already
					// if we reached onError, because of 416 status code, it's probably okay and we should try unzipping the file
				default:
					FileSystem.deleteFile(outPath);
					throw e;
			}
		};
		h.customRequest(false, progress);

		if (redirectedLocation != null) {
			FileSystem.deleteFile(outPath);

			if (maxRedirect > 0) {
				download(redirectedLocation, outPath, maxRedirect - 1);
			} else {
				throw "Too many redirects.";
			}
		}
	}

	function doInstall( rep, project, version, setcurrent ) {
		// check if exists already
		if( FileSystem.exists(Path.join([rep, Data.safe(project), Data.safe(version)])) ) {
			Cli.print('You already have $project version $version installed');
			setCurrent(rep,project,version,true);
			return;
		}

		// download to temporary file
		var filename = Data.fileName(project,version);
		var filepath = Path.join([rep, filename]);

		Cli.print('Downloading $filename...');

		var maxRetry = 3;
		var fileUrl = Path.join([siteUrl, Data.REPOSITORY, filename]);
		for (i in 0...maxRetry) {
			try {
				download(fileUrl, filepath);
				break;
			} catch (e:Dynamic) {
				Cli.print('Failed to download ${fileUrl}. (${i+1}/${maxRetry})\n${e}');
				Sys.sleep(1);
			}
		}

		doInstallFile(rep, filepath, setcurrent);
		try {
			retry(site.postInstall.bind(project, version));
		} catch (e:Dynamic) {}
	}

	function doInstallFile(rep,filepath,setcurrent,nodelete = false) {
		// read zip content
		var f = File.read(filepath,true);
		var zip = try {
			Reader.readZip(f);
		} catch (e:Dynamic) {
			f.close();
			// file is corrupted, remove it
			if (!nodelete)
				FileSystem.deleteFile(filepath);
			rethrow(e);
		}
		f.close();
		var infos = Data.readInfos(zip,false);
		Cli.print('Installing ${infos.name}...');
		// create directories
		var pdir = rep + Data.safe(infos.name);
		safeDir(pdir);
		pdir += "/";
		var target = pdir + Data.safe(infos.version);
		safeDir(target);
		target += "/";

		// locate haxelib.json base path
		final basepath = Data.locateBasePath(zip);

		// unzip content
		final entries = [for (entry in zip) if (entry.fileName.startsWith(basepath)) entry];
		final total = entries.length;
		for (i in 0...total) {
			var zipfile = entries[i];
			var n = zipfile.fileName;
			// remove basepath
			n = n.substr(basepath.length,n.length-basepath.length);
			if( n.charAt(0) == "/" || n.charAt(0) == "\\" || n.split("..").length > 1 )
				throw "Invalid filename : "+n;

			final percent = Std.int((i / total) * 100);
			Cli.showDebugOverwritable('${i + 1}/$total ($percent%)');

			final dirs = ~/[\/\\]/g.split(n);
			final file = dirs.pop();
			var path = "";
			for( d in dirs ) {
				path += d;
				safeDir(target+path);
				path += "/";
			}
			if( file == "" ) {
				if( path != "") Cli.showDebugMessage("  Created "+path);
				continue; // was just a directory
			}
			path += file;
			Cli.showDebugMessage('  Install $path');
			final data = Reader.unzip(zipfile);
			File.saveBytes(target+path,data);
		}

		// set current version
		if( setcurrent || !FileSystem.exists(pdir+".current") ) {
			File.saveContent(pdir + ".current", infos.version);
			Cli.print("  Current version is now "+infos.version);
		}

		// end
		if( !nodelete )
			FileSystem.deleteFile(filepath);
		Cli.print("Done");

		// process dependencies
		doInstallDependencies(rep, infos.dependencies);

		return infos;
	}

	function doInstallDependencies( rep:String, dependencies:Array<Dependency> ) {
		if( settings.skipDependencies ) return;

		for( d in dependencies ) {
			if( d.version == "" ) {
				var pdir = rep + Data.safe(d.name);
				var dev = try getDev(pdir) catch (_:Dynamic) null;

				if (dev != null) { // no version specified and dev set, no need to install dependency
					continue;
				}
			}

			if( d.version == "" && d.type == DependencyType.Haxelib )
				d.version = retry(site.getLatestVersion.bind(d.name));
			Cli.print("Installing dependency "+d.name+" "+d.version);

			switch d.type {
				case Haxelib:
					var info = retry(site.infos.bind(d.name));
					doInstall(rep, info.name, d.version, false);
				case Git:
					useVcs(VcsID.Git, function(vcs) doVcsInstall(rep, vcs, d.name, d.url, d.branch, d.subDir, d.version));
				case Mercurial:
					useVcs(VcsID.Hg, function(vcs) doVcsInstall(rep, vcs, d.name, d.url, d.branch, d.subDir, d.version));
			}
		}
	}


	function getRepository():String {
		if (settings.global)
			return RepoManager.getGlobalRepository();
		return RepoManager.findRepository(Sys.getCwd());
	}

	function setup() {
		var rep =
			try RepoManager.getGlobalRepositoryPath()
			catch (_:Dynamic) RepoManager.getSuggestedGlobalRepositoryPath();

		final prompt = 'Please enter haxelib repository path with write access\n'
				+ 'Hit enter for default ($rep)\n'
				+ 'Path';

		var line = getArgument(prompt);
		if (line != "") {
			var splitLine = line.split("/");
			if(splitLine[0] == "~") {
				var home = getHomePath();

				for(i in 1...splitLine.length) {
					home += "/" + splitLine[i];
				}
				line = home;
			}

			rep = line;
		}

		rep = try FileSystem.absolutePath(rep) catch (e:Dynamic) rep;

		RepoManager.saveSetup(rep);

		Cli.print("haxelib repository is now " + rep);
	}

	function config() {
		Cli.print(getRepository());
	}

	function getCurrent( proj, dir ) {
		return try { getDev(dir); return "dev"; } catch( e : Dynamic ) try File.getContent(dir + "/.current").trim() catch( e : Dynamic ) throw "Library "+proj+" is not installed : run 'haxelib install "+proj+"'";
	}

	function getDev( dir ) {
		var path = File.getContent(dir + "/.dev").trim();
		path = ~/%([A-Za-z0-9_]+)%/g.map(path,function(r) {
			var env = Sys.getEnv(r.matched(1));
			return env == null ? "" : env;
		});
		var filters = try Sys.getEnv("HAXELIB_DEV_FILTER").split(";") catch( e : Dynamic ) null;
		if( filters != null && !filters.exists(function(flt) return StringTools.startsWith(path.toLowerCase().split("\\").join("/"),flt.toLowerCase().split("\\").join("/"))) )
			throw "This .dev is filtered";
		return path;
	}

	function list() {
		var rep = getRepository();
		var folders = FileSystem.readDirectory(rep);
		var filter = args.getNext();
		if ( filter != null )
			folders = folders.filter( function (f) return f.toLowerCase().indexOf(filter.toLowerCase()) > -1 );
		var all = [];
		for( p in folders ) {
			if( p.charAt(0) == "." )
				continue;

			var current = try getCurrent("", rep + p) catch(e:Dynamic) continue;
			var dev = try getDev(rep + p) catch( e : Dynamic ) null;

			var semvers = [];
			var others = [];
			for( v in FileSystem.readDirectory(rep+p) ) {
				if( v.charAt(0) == "." )
					continue;
				v = Data.unsafe(v);
				var semver = try SemVer.ofString(v) catch (_:Dynamic) null;
				if (semver != null)
					semvers.push(semver);
				else
					others.push(v);
			}

			if (semvers.length > 0)
				semvers.sort(SemVer.compare);

			var versions = [];
			for (v in semvers)
				versions.push((v : String));
			for (v in others)
				versions.push(v);

			if (dev == null) {
				for (i in 0...versions.length) {
					var v = versions[i];
					if (v == current)
						versions[i] = '[$v]';
				}
			} else {
				versions.push("[dev:"+dev+"]");
			}

			all.push(Data.unsafe(p) + ": "+versions.join(" "));
		}
		all.sort(function(s1, s2) return Reflect.compare(s1.toLowerCase(), s2.toLowerCase()));
		for (p in all) {
			Cli.print(p);
		}
	}

	function update() {
		var rep = getRepository();

		var prj = args.getNext();
		if (prj != null) {
			prj = projectNameToDir(rep, prj); // get project name in proper case
			if (!updateByName(rep, prj))
				Cli.print(prj + " is up to date");
			return;
		}

		var state = { rep : rep, prompt : true, updated : false };
		for( p in FileSystem.readDirectory(state.rep) ) {
			if( p.charAt(0) == "." || !FileSystem.isDirectory(state.rep+"/"+p) )
				continue;
			var p = Data.unsafe(p);
			Cli.print("Checking " + p);
			try {
				doUpdate(p, state);
			} catch (e:VcsError) {
				if (!e.match(VcsUnavailable(_)))
					rethrow(e);
			}
		}
		if( state.updated )
			Cli.print("Done");
		else
			Cli.print("All libraries are up-to-date");
	}

	function projectNameToDir( rep:String, project:String ) {
		var p = project.toLowerCase();
		var l = FileSystem.readDirectory(rep).filter(function (dir) return dir.toLowerCase() == p);

		switch (l) {
			case []: return project;
			case [dir]: return Data.unsafe(dir);
			case _: throw "Several name case for library " + project;
		}
	}

	function updateByName(rep:String, prj:String) {
		var state = { rep : rep, prompt : false, updated : false };
		doUpdate(prj,state);
		return state.updated;
	}

	function doUpdate( p : String, state : { updated : Bool, rep : String, prompt : Bool } ) {
		var pdir = state.rep + Data.safe(p);

		var vcs = Vcs.getVcsForDevLib(pdir, settings.flat);
		if(vcs != null) {
			if(!vcs.available)
				throw VcsError.VcsUnavailable(vcs);

			var oldCwd = Sys.getCwd();
			Sys.setCwd(pdir + "/" + vcs.directory);
			var success = vcs.update(p);

			state.updated = success;
			if(success)
				Cli.print(p + " was updated");
			Sys.setCwd(oldCwd);
		} else {
			var latest = try retry(site.getLatestVersion.bind(p)) catch( e : Dynamic ) { Cli.print(e); return; };

			if( !FileSystem.exists(pdir+"/"+Data.safe(latest)) ) {
				if( state.prompt ) {
					if (!Cli.ask('Update $p to $latest'))
						return;
				}
				var info = retry(site.infos.bind(p));
				doInstall(state.rep, info.name, latest,true);
				state.updated = true;
			} else
				setCurrent(state.rep, p, latest, true);
		}
	}

	function remove() {
		var rep = getRepository();
		var prj = getArgument("Library");
		var version = args.getNext();
		var pdir = rep + Data.safe(prj);
		if( version == null ) {
			if( !FileSystem.exists(pdir) )
				throw "Library "+prj+" is not installed";

			if (prj == HAXELIB_LIBNAME && isHaxelibRun) {
				Cli.showError('Removing "$HAXELIB_LIBNAME" requires the --system flag');
				Sys.exit(1);
			}

			deleteRec(pdir);
			Cli.print("Library "+prj+" removed");
			return;
		}

		var vdir = pdir + "/" + Data.safe(version);
		if( !FileSystem.exists(vdir) )
			throw "Library "+prj+" does not have version "+version+" installed";

		var cur = File.getContent(pdir + "/.current").trim(); // set version regardless of dev
		if( cur == version )
			throw "Can't remove current version of library "+prj;
		var dev = try getDev(pdir) catch (_:Dynamic) null; // dev is checked here
		if( dev == vdir )
			throw "Can't remove dev version of library "+prj;
		deleteRec(vdir);
		Cli.print("Library "+prj+" version "+version+" removed");
	}

	function set() {
		setCurrent(getRepository(), getArgument("Library"), getArgument("Version"), false);
	}

	function setCurrent( rep : String, prj : String, version : String, doAsk : Bool ) {
		var pdir = rep + Data.safe(prj);
		var vdir = pdir + "/" + Data.safe(version);
		if( !FileSystem.exists(vdir) ){
			Cli.print("Library "+prj+" version "+version+" is not installed");
			if(Cli.ask("Would you like to install it?")) {
				var info = retry(site.infos.bind(prj));
				doInstall(rep, info.name, version, true);
			}
			return;
		}
		if( File.getContent(pdir + "/.current").trim() == version )
			return;
		if( doAsk && !Cli.ask('Set $prj to version $version') )
			return;
		File.saveContent(pdir+"/.current",version);
		Cli.print("Library "+prj+" current version is now "+version);
	}

	function checkRec( rep : String, prj : String, version : String, l : List<{ project : String, version : String, dir : String, info : Infos }>, ?returnDependencies : Bool = true ) {
		var pdir = rep + Data.safe(prj);
		var explicitVersion = version != null;
		var version = if( version != null ) version else getCurrent(prj, pdir);

		var dev = try getDev(pdir) catch (_:Dynamic) null;
		var vdir = pdir + "/" + Data.safe(version);

		if( dev != null && (!explicitVersion || !FileSystem.exists(vdir)) )
			vdir = dev;

		if( !FileSystem.exists(vdir) )
			throw "Library "+prj+" version "+version+" is not installed";

		for( p in l )
			if( p.project == prj ) {
				if( p.version == version )
					return;
				throw "Library "+prj+" has two versions included : "+version+" and "+p.version;
			}
		var json = try File.getContent(vdir+"/"+Data.JSON) catch( e : Dynamic ) null;
		var inf = Data.readData(json, json != null ? CheckSyntax : NoCheck);
		l.add({ project : prj, version : version, dir : Path.addTrailingSlash(vdir), info: inf });
		if( returnDependencies ) {
			for( d in inf.dependencies )
				if( !Lambda.exists(l, function(e) return e.project == d.name) )
					checkRec(rep,d.name,if( d.version == "" ) null else d.version,l);
		}
	}

	function path() {
		var rep = getRepository();
		var list = new List();
		var libInfo:Array<String>;
		for(arg in args.getRemaining()){
			libInfo = arg.split(":");
			try {
				checkRec(rep, libInfo[0], libInfo[1], list);
			} catch(e:Dynamic) {
				throw 'Cannot process $libInfo: $e';
			}
		}
		for( d in list ) {
			var ndir = d.dir + "ndll";
			if (FileSystem.exists(ndir))
				Cli.print('-L $ndir/');

			try {
				Cli.print(normalizeHxml(File.getContent(d.dir + "extraParams.hxml")));
			} catch(_:Dynamic) {}

			var dir = d.dir;
			if (d.info.classPath != "") {
				var cp = d.info.classPath;
				dir = Path.addTrailingSlash( d.dir + cp );
			}
			Cli.print(dir);

			Cli.print("-D " + d.project + "="+d.info.version);
		}
	}

	function libpath( ) {
		final rep = getRepository();
		var libInfo:Array<String>;
		for(arg in args.getRemaining() ) {
			libInfo = arg.split(":");
			final results = new List();
			checkRec(rep, libInfo[0], libInfo[1], results, false);
			if (!results.isEmpty()) Cli.print(results.first().dir);
		}
	}

	function dev() {
		final rep = getRepository();
		final project = getArgument("Library");
		var dir = args.getNext();
		final proj = rep + Data.safe(project);
		if( !FileSystem.exists(proj) ) {
			FileSystem.createDirectory(proj);
		}
		var devfile = proj+"/.dev";
		if( dir == null ) {
			if( FileSystem.exists(devfile) )
				FileSystem.deleteFile(devfile);
			Cli.print("Development directory disabled");
		}
		else {
			while ( dir.endsWith("/") || dir.endsWith("\\") ) {
				dir = dir.substr(0,-1);
			}
			if (!FileSystem.exists(dir)) {
				Cli.print('Directory $dir does not exist');
			} else {
				dir = FileSystem.fullPath(dir);
				try {
					File.saveContent(devfile, dir);
					Cli.print("Development directory set to "+dir);
				}
				catch (e:Dynamic) {
					Cli.print('Could not write to $devfile');
				}
			}

		}
	}


	function removeExistingDevLib(proj:String):Void {
		//TODO: ask if existing repo have changes.

		// find existing repo:
		var vcs = Vcs.getVcsForDevLib(proj, settings.flat);
		// remove existing repos:
		while(vcs != null) {
			deleteRec(proj + "/" + vcs.directory);
			vcs = Vcs.getVcsForDevLib(proj, settings.flat);
		}
	}

	inline function useVcs(id:VcsID, fn:Vcs->Void):Void {
		// Prepare check vcs.available:
		var vcs = Vcs.get(id, settings.flat);
		if(vcs == null || !vcs.available)
			throw 'Could not use $id, please make sure it is installed and available in your PATH.';
		return fn(vcs);
	}

	function vcs(id:VcsID) {
		var rep = getRepository();
		useVcs(id, function(vcs)
			doVcsInstall(
				rep, vcs, getArgument("Library name"),
				getArgument(vcs.name + " path"), args.getNext(),
				args.getNext(), args.getNext()
			)
		);
	}

	function doVcsInstall(rep:String, vcs:Vcs, libName:String, url:String, branch:String, subDir:String, version:String) {

		var proj = rep + Data.safe(libName);

		var libPath = proj + "/" + vcs.directory;

		function doVcsClone() {
			Cli.print("Installing " +libName + " from " +url + ( branch != null ? " branch: " + branch : "" ));
			try {
				vcs.clone(libPath, url, branch, version);
			} catch(error:VcsError) {
				deleteRec(libPath);
				var message = switch(error) {
					case VcsUnavailable(vcs):
						'Could not use ${vcs.executable}, please make sure it is installed and available in your PATH.';
					case CantCloneRepo(vcs, repo, stderr):
						'Could not clone ${vcs.name} repository' + (stderr != null ? ":\n" + stderr : ".");
					case CantCheckoutBranch(vcs, branch, stderr):
						'Could not checkout branch, tag or path "$branch": ' + stderr;
					case CantCheckoutVersion(vcs, version, stderr):
						'Could not checkout tag "$version": ' + stderr;
				};
				throw message;
			}
		}

		if ( FileSystem.exists(proj + "/" + Data.safe(vcs.directory)) ) {
			Cli.print("You already have "+libName+" version "+vcs.directory+" installed.");

			var wasUpdated = this.alreadyUpdatedVcsDependencies.exists(libName);
			var currentBranch = if (wasUpdated) this.alreadyUpdatedVcsDependencies.get(libName) else null;

			if (branch != null && (!wasUpdated || (wasUpdated && currentBranch != branch))
				&& Cli.ask("Overwrite branch: " + (currentBranch == null?"<unspecified>":"\"" + currentBranch + "\"") + " with \"" + branch + "\""))
			{
				deleteRec(libPath);
				doVcsClone();
			}
			else if (!wasUpdated)
			{
				Cli.print("Updating " + libName+" version " + vcs.directory + " ...");
				updateByName(rep, libName);
			}
		} else {
			doVcsClone();
		}

		// finish it!
		if (subDir != null) {
			libPath += "/" + subDir;
			File.saveContent(proj + "/.dev", libPath);
			Cli.print("Development directory set to "+libPath);
		} else {
			File.saveContent(proj + "/.current", vcs.directory);
			Cli.print("Library "+libName+" current version is now "+vcs.directory);
		}

		this.alreadyUpdatedVcsDependencies.set(libName, branch);

		var jsonPath = libPath + "/haxelib.json";
		if(FileSystem.exists(jsonPath))
			doInstallDependencies(rep, Data.readData(File.getContent(jsonPath), false).dependencies);
	}


	function run() {
		final rep = getRepository();
		final project = getArgument("Library");
		final libInfo = project.split(":");
		doRun(rep, libInfo[0], args.getRemaining(), libInfo[1]);
	}

	function haxeVersion():SemVer {
		if(__haxeVersion == null) {
			var p = new Process('haxe', ['--version']);
			if(p.exitCode() != 0) {
				throw 'Cannot get haxe version: ${p.stderr.readAll().toString()}';
			}
			var str = p.stdout.readAll().toString();
			__haxeVersion = SemVer.ofString(str.split('+')[0]);
		}
		return __haxeVersion;
	}
	static var __haxeVersion:SemVer;

	function doRun( rep:String, project:String, args:Array<String>, ?version:String ) {
		var pdir = rep + Data.safe(project);
		if( !FileSystem.exists(pdir) )
			throw "Library "+project+" is not installed";
		pdir += "/";
		if (version == null)
			version = getCurrent(project, pdir);
		var dev = try getDev(pdir) catch ( e : Dynamic ) null;
		var vdir = dev != null ? dev : pdir + Data.safe(version);

		var infos =
			try
				Data.readData(File.getContent(vdir + '/haxelib.json'), false)
			catch (e:Dynamic)
				throw 'Error parsing haxelib.json for $project@$version: $e';

		final scriptArgs =
			if (infos.main != null) {
				runScriptArgs(project, infos.main, infos.dependencies);
			} else if(FileSystem.exists('$vdir/run.n')) {
				["neko", vdir + "/run.n"];
			} else if(FileSystem.exists('$vdir/Run.hx')) {
				runScriptArgs(project, 'Run', infos.dependencies);
			} else {
				throw 'Library $project version $version does not have a run script';
			}

		final cmd = scriptArgs.shift();
		final callArgs = scriptArgs.concat(args);

		callArgs.push(Sys.getCwd());
		Sys.setCwd(vdir);

		Sys.putEnv("HAXELIB_RUN", "1");
		Sys.putEnv("HAXELIB_RUN_NAME", project);
 		Sys.exit(Sys.command(cmd, callArgs));
	}

	function runScriptArgs(project:String, main:String, dependencies:Dependencies):Array<String> {
		var deps = dependencies.toArray();
		deps.push( { name: project, version: DependencyVersion.DEFAULT } );
		var args = [];
		// TODO: change comparison to '4.0.0' upon Haxe 4.0 release
		if(settings.global && SemVer.compare(haxeVersion(), SemVer.ofString('4.0.0-rc.5')) >= 0) {
			args.push('--haxelib-global');
		}
		for (d in deps) {
			args.push('-lib');
			args.push(d.name + if (d.version == '') '' else ':${d.version}');
		}
		args.unshift('haxe');
		args.push('--run');
		args.push(main);
		return args;
	}

	function proxy() {
		final rep = getRepository();
		final host = getArgument("Proxy host");
		if( host == "" ) {
			if( FileSystem.exists(rep + "/.proxy") ) {
				FileSystem.deleteFile(rep + "/.proxy");
				Cli.print("Proxy disabled");
			} else
				Cli.print("No proxy specified");
			return;
		}
		final port = Std.parseInt(getArgument("Proxy port"));
		final authName = getArgument("Proxy user login");
		final authPass = authName == "" ? "" : getArgument("Proxy user pass");
		final proxy = {
			host : host,
			port : port,
			auth : authName == "" ? null : { user : authName, pass : authPass },
		};
		Http.PROXY = proxy;
		Cli.print("Testing proxy...");
		try Http.requestUrl(SERVER.protocol + "://lib.haxe.org") catch( e : Dynamic ) {
			if(!Cli.ask("Proxy connection failed. Use it anyway")) {
				return;
			}
		}
		File.saveContent(rep + "/.proxy", haxe.Serializer.run(proxy));
		Cli.print("Proxy setup done");
	}

	function loadProxy() {
		var rep = getRepository();
		try Http.PROXY = haxe.Unserializer.run(File.getContent(rep + "/.proxy")) catch( e : Dynamic ) { };
	}

	function convertXml() {
		var cwd = Sys.getCwd();
		var xmlFile = cwd + "haxelib.xml";
		var jsonFile = cwd + "haxelib.json";

		if (!FileSystem.exists(xmlFile)) {
			Cli.print('No `haxelib.xml` file was found in the current directory.');
			Sys.exit(0);
		}

		var xmlString = File.getContent(xmlFile);
		var json = ConvertXml.convert(xmlString);
		var jsonString = ConvertXml.prettyPrint(json);

		File.saveContent(jsonFile, jsonString);
		Cli.print('Saved to $jsonFile');
	}

	function newRepo() {
		try {
			final path = RepoManager.newRepo(Sys.getCwd());
			Cli.print('Local repository created ($path)');
		} catch(e:RepoException)
			Cli.print(e.message);
	}

	function deleteRepo() {
		try {
			final path = RepoManager.deleteRepo(Sys.getCwd());
			Cli.print('Local repository deleted ($path)');
		} catch(e:RepoException)
			Cli.print(e.message);
	}

	// ----------------------------------

	static function main() {
		final args = Sys.args();
		final isHaxelibRun = (Sys.getEnv("HAXELIB_RUN_NAME") == HAXELIB_LIBNAME);
		if (isHaxelibRun)
			Sys.setCwd(args.pop());

		try {
			new Main(args, isHaxelibRun).process();
		} catch(e:Dynamic) {
			if(Sys.args().contains("--debug"))
				Util.rethrow(e);
			Cli.showError(Std.string(e));
		}
	}

	// deprecated commands
	function local() {
		doInstallFile(getRepository(), getArgument("Package"), true, true);
	}

	function updateSelf() {
		updateByName(RepoManager.getGlobalRepository(), HAXELIB_LIBNAME);
	}
}
