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

/** Manager for the location of the haxelib database. **/
class RepoManager {
	static final REPONAME = "lib";
	static final REPODIR = ".haxelib";

	/** Returns the default path for the global directory. **/
	public static function getSuggestedGlobalRepositoryPath():String {
		if (IS_WINDOWS)
			return getWindowsDefaultGlobalRepositoryPath();

		return if (FileSystem.exists("/usr/share/haxe")) // for Debian
			'/usr/share/haxe/$REPONAME'
		else if (Sys.systemName() == "Mac") // for newer OSX, where /usr/lib is not writable
			'/usr/local/lib/haxe/$REPONAME'
		else '/usr/lib/haxe/$REPONAME'; // for other unixes
	}

	/**
		Returns the path to the repository local to `dir` if one exists,
		otherwise returns global repository path.
	**/
	public static function findRepository(dir:String) {
		return switch getLocalRepository(dir) {
			case null: getGlobalRepository();
			case repo: Path.addTrailingSlash(FileSystem.fullPath(repo));
		}
	}

	/**
		Searches for the path to local repository, starting in `dir`
		and then going up until root directory is reached.

		Returns the directory path if it is found, else returns null.
	**/
	static function getLocalRepository(dir:String):Null<String> {
		var dir = FileSystem.absolutePath(dir);
		while (dir != null) {
			final repo = Path.join([dir, REPODIR]);
			if (FileSystem.exists(repo) && FileSystem.isDirectory(repo))
				return repo;
			dir = Path.directory(dir);
		}
		return null;
	}

	/**
		Returns the global repository path, but throws an exception
		if it does not exist or if it is not a directory.
	**/
	public static function getGlobalRepository():String {
		final rep = getGlobalRepositoryPath(true);
		if (!FileSystem.exists(rep))
			throw new RepoException('haxelib Repository $rep does not exist. Please run `haxelib setup` again.');
		else if (!FileSystem.isDirectory(rep))
			throw new RepoException('haxelib Repository $rep exists, but is a file, not a directory. Please remove it and run `haxelib setup` again.');
		return Path.addTrailingSlash(rep);
	}

	/** Sets `path` as the global haxelib repository in the user's haxelib config file. **/
	public static function saveSetup(path:String):Void {
		final configFile = getConfigFile();

		if (isSamePath(path, configFile))
			throw new RepoException('Can\'t use $path because it is reserved for config file');

		safeDir(path);
		File.saveContent(configFile, path);
	}

	/**
		Returns the global Haxelib repository path, without validating
		that it exists.

		First checks HAXELIB_PATH environment variable,
		then checks the content of user config file.

		If both are empty:
		- On Unix-like systems, checks `/etc/.haxelib` for system wide configuration,
		and throws an exception if this has not been set.
		- On Windows, returns the default suggested repository path, after
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

		if (!IS_WINDOWS) {
			// on unixes, try to read system-wide config
			rep = try File.getContent("/etc/.haxelib").trim() catch (_:Dynamic) null;
			if (rep == null)
				throw new RepoException("This is the first time you are running haxelib. Please run `haxelib setup` first");
		} else {
			// on windows, try to use haxe installation path
			rep = getWindowsDefaultGlobalRepositoryPath();
			if (create)
				try
					safeDir(rep)
				catch (e:Dynamic)
					throw new RepoException('Error accessing Haxelib repository: $e');
		}

		return rep;
	}

	/**
		Creates a new local repository in the directory `dir` if one doesn't already exist.

		Returns its full path if successful.

		Throws RepoException if repository already exists.
	**/
	public static function newRepo(dir:String):String {
		final path = FileSystem.absolutePath(Path.join([dir, REPODIR]));
		final created = FsUtils.safeDir(path, true);
		if(!created)
			throw new RepoException('Local repository already exists ($path)');
		return path;
	}

	/**
		Deletes the local repository in the directory `dir`, if it exists.

		Returns the full path of the deleted repository if successful.

		Throws RepoException if no repository found.
	**/
	public static function deleteRepo(dir:String):String {
		final path = FileSystem.absolutePath(Path.join([dir, REPODIR]));
		final deleted = FsUtils.deleteRec(path);
		if (!deleted)
			throw new RepoException('No local repository found ($path)');
		return path;
	}

	static function getConfigFile():String {
		return Path.join([getHomePath(), ".haxelib"]);
	}

	/**
		The Windows haxe installer will setup `%HAXEPATH%`.
		We will default haxelib repo to `%HAXEPATH%/lib.`

		When there is no `%HAXEPATH%`, we will use a `/haxelib`
		directory next to the config file, ".haxelib".
	**/
	static function getWindowsDefaultGlobalRepositoryPath():String {
		final haxepath = Sys.getEnv("HAXEPATH");
		if (haxepath != null)
			return Path.join([haxepath.trim(), REPONAME]);
		return Path.join([Path.directory(getConfigFile()), "haxelib"]);
	}

}
