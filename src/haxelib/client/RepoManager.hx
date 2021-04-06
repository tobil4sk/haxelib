package haxelib.client;

import sys.FileSystem;
import sys.io.File;
import haxe.io.Path;

import haxelib.client.FsUtils.*;

using StringTools;

class RepoException extends haxe.Exception {}

class RepoManager {
	static var REPNAME = "lib";
	static var REPODIR = ".haxelib";

	public static function getSuggestedGlobalRepositoryPath():String {
		if (Main.IS_WINDOWS)
			return getWindowsDefaultGlobalRepositoryPath();

		return if (FileSystem.exists("/usr/share/haxe")) // for Debian
			'/usr/share/haxe/$REPNAME'
		else if (Sys.systemName() == "Mac") // for newer OSX, where /usr/lib is not writable
			'/usr/local/lib/haxe/$REPNAME'
		else '/usr/lib/haxe/$REPNAME'; // for other unixes
	}

	public static function findRepository() {
		return switch getLocalRepository() {
			case null: getGlobalRepository();
			case repo: Path.addTrailingSlash(FileSystem.fullPath(repo));
		}
	}

	static function getLocalRepository():Null<String> {
		var dir = Path.removeTrailingSlashes(Sys.getCwd());
		while (dir != null) {
			var repo = Path.addTrailingSlash(dir) + REPODIR;
			if (FileSystem.exists(repo) && FileSystem.isDirectory(repo)) {
				return repo;
			} else {
				dir = new Path(dir).dir;
			}
		}
		return null;
	}

	public static function getGlobalRepository():String {
		var rep = getGlobalRepositoryPath(true);
		if (!FileSystem.exists(rep))
			throw "haxelib Repository " + rep + " does not exist. Please run `haxelib setup` again.";
		else if (!FileSystem.isDirectory(rep))
			throw "haxelib Repository " + rep + " exists, but is a file, not a directory. Please remove it and run `haxelib setup` again.";
		return Path.addTrailingSlash(rep);
	}

	public static function saveSetup(path:String):Void {
		var configFile = getConfigFile();

		if (isSamePath(path, configFile))
			throw "Can't use " + path + " because it is reserved for config file";

		safeDir(path);
		File.saveContent(configFile, path);
	}

	public static function getGlobalRepositoryPath(create = false):String {
		// first check the env var
		var rep = Sys.getEnv("HAXELIB_PATH");
		if (rep != null)
			return rep.trim();

		// try to read from user config
		rep = try File.getContent(getConfigFile()).trim() catch (_:Dynamic) null;
		if (rep != null)
			return rep;

		if (!Main.IS_WINDOWS) {
			// on unixes, try to read system-wide config
			rep = try File.getContent("/etc/.haxelib").trim() catch (_:Dynamic) null;
			if (rep == null)
				throw "This is the first time you are running haxelib. Please run `haxelib setup` first";
		} else {
			// on windows, try to use haxe installation path
			rep = getWindowsDefaultGlobalRepositoryPath();
			if (create)
				try
					safeDir(rep)
				catch (e:Dynamic)
					throw 'Error accessing Haxelib repository: $e';
		}

		return rep;
	}

	public static function newRepo():String {
		var path = absolutePath(REPODIR);
		var created = FsUtils.safeDir(path, true);
		if(!created)
			throw new RepoException('Local repository already exists ($path)');
		return path;
	}
	public static function deleteRepo():String {
		var path = absolutePath(REPODIR);
		var deleted = FsUtils.deleteRec(path);
		if (!deleted)
			throw new RepoException('No local repository found ($path)');
		return path;
	}

	static function getConfigFile():String {
		return Path.addTrailingSlash(getHomePath()) + ".haxelib";
	}

	static function getWindowsDefaultGlobalRepositoryPath():String {
		var haxepath = Sys.getEnv("HAXEPATH");
		if (haxepath != null)
			return Path.addTrailingSlash(haxepath.trim()) + REPNAME;
		else
			return Path.join([Path.directory(getConfigFile()), "haxelib"]);
	}

}
