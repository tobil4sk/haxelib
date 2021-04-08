package haxelib.client;

import sys.FileSystem;
import sys.io.File;
import haxe.io.Path;

import haxelib.client.FsUtils.*;

using StringTools;

#if (haxe_ver < 4.1)
#error "RepoManager requires Haxe 4.1 or newer"
#end

class RepoException extends haxe.Exception {}

/** Manages the haxelib database. **/
class RepoManager {
	static final REPNAME = "lib";
	static final REPODIR = ".haxelib";

	/** Return the default path for the global directory. **/
	public static function getSuggestedGlobalRepositoryPath():String {
		if (Main.IS_WINDOWS)
			return getWindowsDefaultGlobalRepositoryPath();

		return if (FileSystem.exists("/usr/share/haxe")) // for Debian
			'/usr/share/haxe/$REPNAME'
		else if (Sys.systemName() == "Mac") // for newer OSX, where /usr/lib is not writable
			'/usr/local/lib/haxe/$REPNAME'
		else '/usr/lib/haxe/$REPNAME'; // for other unixes
	}

	/** Get the repository path to the local one if it exists, otherwise get global repo path. **/
	public static function findRepository() {
		return switch getLocalRepository() {
			case null: getGlobalRepository();
			case repo: Path.addTrailingSlash(FileSystem.fullPath(repo));
		}
	}

	/**
		Search for the path to local repository, starting in current working directory
		and then going up until root directory is reached.

		Returns null if no local repository is found.
	**/
	static function getLocalRepository():Null<String> {
		var dir = Path.removeTrailingSlashes(Sys.getCwd());
		while (dir != null) {
			final repo = Path.join([dir, REPODIR]);
			if (FileSystem.exists(repo) && FileSystem.isDirectory(repo))
				return repo;
			dir = Path.directory(dir);
		}
		return null;
	}

	/** Return the global repository path, but throw an error if it doesn't exist or if it is not a directory. **/
	public static function getGlobalRepository():String {
		var rep = getGlobalRepositoryPath(true);
		if (!FileSystem.exists(rep))
			throw "haxelib Repository " + rep + " does not exist. Please run `haxelib setup` again.";
		else if (!FileSystem.isDirectory(rep))
			throw "haxelib Repository " + rep + " exists, but is a file, not a directory. Please remove it and run `haxelib setup` again.";
		return Path.addTrailingSlash(rep);
	}

	/** Set `path` as the global haxelib repository in the haxelib config file. **/
	public static function saveSetup(path:String):Void {
		var configFile = getConfigFile();

		if (isSamePath(path, configFile))
			throw "Can't use " + path + " because it is reserved for config file";

		safeDir(path);
		File.saveContent(configFile, path);
	}

	/**
		Return the global Haxelib repository path. First check HAXELIB_PATH environment variable,
		then content of user config file.

		If both are empty:

		- on Unix, check `/etc/.haxelib` for system wide configuration, and show error if this has not been set.
		- on Windows, return the default suggested repository path, after
		attempting to create this directory if `create` is set to true.

	 **/
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

	/**
		Create a new local repository in the current working directory if one doesn't already exist.

		Returns its path if successful.

		Throws RepoException if repository already exists.
	**/
	public static function newRepo():String {
		var path = FileSystem.absolutePath(REPODIR);
		var created = FsUtils.safeDir(path, true);
		if(!created)
			throw new RepoException('Local repository already exists ($path)');
		return path;
	}

	/**
		Delete the local repository in the current working directory if it exists.

		Returns the path of the deleted repository if successful.

		Throws RepoException if no repository found.
	**/
	public static function deleteRepo():String {
		var path = FileSystem.absolutePath(REPODIR);
		var deleted = FsUtils.deleteRec(path);
		if (!deleted)
			throw new RepoException('No local repository found ($path)');
		return path;
	}

	static function getConfigFile():String {
		return Path.join([getHomePath(), ".haxelib"]);
	}

	/**
		The Windows haxe installer will setup %HAXEPATH%. We will default haxelib repo to %HAXEPATH%/lib.

		When there is no %HAXEPATH%, we will use a "haxelib" directory next to the config file, ".haxelib".
	**/
	static function getWindowsDefaultGlobalRepositoryPath():String {
		final haxepath = Sys.getEnv("HAXEPATH");
		if (haxepath != null)
			return Path.join([haxepath.trim(), REPNAME]);
		return Path.join([Path.directory(getConfigFile()), "haxelib"]);
	}

}
