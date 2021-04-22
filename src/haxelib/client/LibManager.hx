package haxelib.client;

import sys.FileSystem;
import sys.io.File;
import haxe.io.Path;

import haxelib.Data;
import haxelib.client.RepoManager;
import haxelib.client.FsUtils;

using Lambda;
using StringTools;

typedef InstallationInfo = {
	final name:String;
	final versions:Array<String>;
	final current:String;
	final devPath:Null<String>;
}

private typedef LibCallInfo = {
	final name:String;
	final type:RunType;
	final libPath:String;
	final version:String;
}

private enum RunType {
	Neko;
	Script(main:String, dependencies:Dependencies);
}

private typedef CallState = {
	final dir:String;
	final run:String;
	final runName:String;
}

abstract Name(String) to String {
	public static function isValid(name:String) {
		try {
			Data.safe(name);
			return true;
		} catch(e:Exception)
			return false;
	}

	@:from public static function fromString(name:String){
		return Data.safe(name);
	}
}

abstract Version(String) to String {

	@:from public static function fromString(){

	}

}

/**
	Class used to set and get project versions in a repository.

	Throws a RepoException when trying to change or access a library version
	in a repository that has been deleted.
**/
class LibManager {

	static final CURRENT = ".current";
	static final DEV = ".dev";

	/**
		Return the path to the repository.
		Throws an exception if it has been deleted.
	 **/
	var repo(get,null):String;
	final forceGlobal:Bool;

	function get_repo(){
		if (!FileSystem.exists(repo))
			throw new RepoException('repository $repo has been deleted.');
		return repo;
	}

	/**
		Create a version manager.

		If `dir` is passed in, use it instead of the current directory
		for searching for a local repository.

		If `forceGlobal` is set to true, do not look for local repository
		and go straight to getting the global one.
	**/
	public function new(?dir:String, forceGlobal = false) {
		final verison:DependencyVersion = "git";

		this.forceGlobal = forceGlobal;
		repo =
			if (forceGlobal)
				RepoManager.getGlobalRepository()
			else {
				if(dir == null)
					dir = Sys.getCwd();
				RepoManager.findRepository(dir);
			};
	}

	/**
		Returns a map of installled project versions by their names.

		If `filter` is given, ignores projects that do not
		contain it as a substring.
	**/
	public function getProjectsInstallationInfo(filter:String = null):Array<InstallationInfo> {
		if(filter != null)
			filter = filter.toLowerCase();

		inline function isFiltered(name:String) {
			if(filter == null)
				return false;
			return name.toLowerCase().contains(filter);
		}

		final projects:Array<InstallationInfo> = [];
		var projectName:ProjectName;

		for (dir in FileSystem.readDirectory(repo)){
			// if it is a hidden file, or meant to be filtered
			if(dir.startsWith(".") || isFiltered(dir) || projectName = try )
				continue;
			projects.push(getInstallationInfo(dir));
		}
		// sort projects alphabetically
		projects.sort(
			function(a, b) return Reflect.compare(a.name.toLowerCase(), b.name.toLowerCase())
		);

		return projects;
	}

	/** Returns an array of all currently installed versions for project `name` **/
	function getInstallationInfo(name:ProjectName):InstallationInfo {
		final semVers:Array<SemVer> = [];
		final others:Array<String> = [];

		for (sub in FileSystem.readDirectory(getProjectRoot(name))) {
			// ignore .dev and .current files
			if (sub.startsWith("."))
				continue;

			final version = Data.unsafe(sub);
			final semVer = try SemVer.ofString(version) catch (e:haxe.Exception) null;
			if (semVer != null)
				semVers.push(semVer);
			else
				others.push(version);
		}
		if (semVers.length != 0)
			semVers.sort(SemVer.compare);

		final versions = [];
		for (v in semVers)
			versions.push((v : String));
		for (v in others)
			versions.push(v);

		final devPath = getDevPath(name);
		return {
			name: Data.unsafe(name),
			versions: versions,
			current: if (devPath != null) "dev" else getCurrentVersion(name),
			devPath: devPath
		};
	}

	/** Returns whether project `name` is installed **/
	public function isInstalled(name:ProjectName):Bool {
		return FileSystem.exists(getProjectRoot(name));
	}

	/** Returns whether `version` of project `name` is installed **/
	public function isVersionInstalled(name:ProjectName, version:SemVer):Bool {
		if(version == "dev")
			return getDevPath(name) != null;
		return FileSystem.exists(getVersionPath(name, version));
	}

	/** Removes the project `name` from the repository **/
	public function removeProject(name:ProjectName) {
		final path = getProjectRoot(name);

		if(!FileSystem.exists(path))
			throw 'Library $name is not installed';

		FsUtils.deleteRec(path);
	}

	/**
		Removes `version` of project `name`.

		Throws an exception if the version is not installed, if
		`version` matches the current version, or if it matches
		its development path.
	**/
	public function removeProjectVersion(name:ProjectName, version:SemVer){
		final versionPath = getVersionPath(name, version);
		if(!FileSystem.exists(versionPath))
			throw 'Library $name version $version is not installed';

		// get version regardless of dev
		final current = File.getContent(getCurrentFile(name)).trim();
		if (current == version)
			throw 'Cannot remove current version of library $name';
		// dev is checked here
		if (getDevPath(name) == versionPath)
			throw 'Cannot remove dev version of library $name';

		FsUtils.deleteRec(versionPath);
	}

	/**
		If the environment variable `HAXELIB_DEV_FILTER` is set,
		returns true if `path` does not start with it or its values.

		Otherwise always returns false.
	**/
	static function isDevPathExcluded(path:String):Bool {
		final filters = switch (Sys.getEnv("HAXELIB_DEV_FILTER")) {
			case null:
				return false;
			case filters:
				filters.split(";");
		}

		function normalize(path:String)
			return Path.normalize(path).toLowerCase();

		return !filters.exists(function(flt) return normalize(path).startsWith(normalize(flt)));
	}

	function setCurrentVersion(name:String, version:String) {}

	/**
		Returns the current version of project `name`,
		or "dev" if there is a development directory set.

		Throws an exception if the project is not installed.
	**/
	public function getCurrentVersion(name:String):String {
		if(!isInstalled(name))
			throw 'Library $name is not installed : run \'haxelib install $name\'';

		if(getDevPath(name) != null)
			return "dev";

		return File.getContent(getCurrentFile(name)).trim();
	}

	/**
		Executes the script for project `name` in the directory `dir`.

		`version` can be provided optionally to run a specific version.

		Returns the process output code.
	**/
	public function runProjectScript(name:String, dir:String, ?extraArgs:Array<String>, ?version:String):Int {
		if (version == null)
			version = getCurrentVersion(name);

		final libPath = getValidVersionPath(name, version);

		final infos = try Data.readData(File.getContent(libPath + '/haxelib.json'), false)
			catch (e:Dynamic) throw 'Error parsing haxelib.json for $name@$version: $e';

		final type = switch(infos.main){
			case null if (FileSystem.exists('$libPath/run.n')):
				Neko;
			case main if (main != null || FileSystem.exists('$libPath/Run.hx')):
				if(main == null)
					main = "Run";
				Script(main, infos.dependencies);
			case _:
				throw 'Library $name version $version does not have a run script';
		}

		return runLibrary(
			{
				name: name,
				libPath: libPath,
				type: type,
				version: version
			},
			dir,
			extraArgs
		);
	}

	function runLibrary(lib:LibCallInfo, dir:String, args:Array<String>) {
		// get state
		final oldState = getState();

		// call setup
		setState({
			dir: lib.libPath,
			run: "1",
			runName: lib.name
		});

		// call
		final output = {
			var callArgs:Array<String>;
			var cmd:String;
			switch (lib.type) {
				case Neko:
					cmd = "neko";
					callArgs = args.copy();
					callArgs.unshift('${lib.libPath}/run.n');
				case Script(main, dependencies):
					cmd = "haxe";
					callArgs = generateScriptArgs(lib.name, main, dependencies);
					for(arg in args)
						callArgs.push(arg);
			}
			callArgs.push(dir);
			Sys.command(cmd, callArgs);
		}
		// call teardown
		setState(oldState);

		return output;
	}

	/**
		If you call inside of a library, you want to revert to the previous state after.
	**/
	static function getState(): CallState {
		function getEnv(name:String){
			final value = Sys.getEnv(name);
			return value != null ? value : "";
		}
		return {
			dir: Sys.getCwd(),
			run: getEnv("HAXELIB_RUN"),
			runName: getEnv("HAXELIB_RUN_NAME")
		};
	}

	static function setState(state:CallState){
		Sys.setCwd(state.dir);
		Sys.putEnv("HAXELIB_RUN", state.run);
		Sys.putEnv("HAXELIB_RUN_NAME", state.runName);
	}

	function generateScriptArgs(project:String, main:String, dependencies:Dependencies):Array<String> {
		final deps = dependencies.toArray();
		deps.push({name: project, version: DependencyVersion.DEFAULT});
		final args = [];
		// TODO: change comparison to '4.0.0' upon Haxe 4.0 release
		if (forceGlobal && SemVer.compare(getHaxeVersion(), SemVer.ofString('4.0.0-rc.5')) >= 0)
			args.push('--haxelib-global');

		for (d in deps) {
			args.push('-lib');
			args.push(d.name + if (d.version == '') '' else ':${d.version}');
		}
		args.push('--run');
		args.push(main);
		return args;
	}

	/**
		Returns the path to `version` project `name`.

		Throws an exception if the path does not exist.
	**/
	function getValidVersionPath(name:String, version:String):String {
		if (version == "dev") {
			final devPath = getDevPath(name);
			if (devPath == null)
				throw 'no development path set for $name';
			if (!FileSystem.exists(devPath))
				throw 'development path for $name is set to non existant path: $devPath';
			return devPath;
		}
		final path = getVersionPath(name, version);
		if (!FileSystem.exists(path))
			throw 'Library $name version $version is not installed';
		return path;
	}

	/**
		Sets the dev path for project `name` to `path`.
	**/
	public function setDevPath(name:String, path:String) {
		final root = getProjectRoot(name);

		if (!FileSystem.exists(root)) {
			FileSystem.createDirectory(root);
		}

		final devFile = Path.join([root, DEV]);

		File.saveContent(devFile, path);
	}

	/**
		Returns the development path for `name`.

		If no development path is set, or it is filtered out,
		returns null.
	**/
	function getDevPath(name:ProjectName):Null<String> {
		final devFile = getDevFile(name);
		if (!FileSystem.exists(devFile))
			return null;

		final path = {
			final path = File.getContent(devFile).trim();
			// windows environment variables
			~/%([A-Za-z0-9_]+)%/g.map(path, function(r) {
				final env = Sys.getEnv(r.matched(1));
				return env == null ? "" : env;
			});
		}

		if (isDevPathExcluded(path))
			return null;

		return path;
	}

	/**
		Removes the development directory for `name`, if one was set.
	**/
	public function removeDevPath(name:String) {
		final devFile = getDevFile(name);
		if (FileSystem.exists(devFile))
			FileSystem.deleteFile(devFile);
	}


	/** Returns path to the .dev file of project `name` **/
	function getDevFile(name:String):String {
		return addToRepoPath(Data.safe(name), DEV);
	}

	/** Returns the content of the .current file for project `name` **/
	inline function getCurrentFileContent(name:ProjectName):String {
		return File.getContent(getCurrentFile(name)).trim();
	}

	/** Returns path to the .current file of project `name` **/
	inline function getCurrentFile(name:ProjectName):String {
		return addToRepoPath(Data.safe(name), CURRENT);
	}

	/**
		Returns the root directory of a project,
		which contains all the subdirectories for specific versions
		and .current and .dev files
	**/
	inline function getProjectRoot(name:ProjectName):String {
		return addToRepoPath(name);
	}

	/**
		Returns the path to `version` of project `name`.
		(only works for "real" versions, ie not "dev")
	**/
	inline function getVersionPath(name:ProjectName, version:DependencyVersion): String {
		return addToRepoPath(name, Data.safe(version));
	}

	/**
		Add project `name` to the repo path and return it.

		`sub` can be specified to get the path to a version folder
		or a file in the project directory.
	**/
	inline function addToRepoPath(name:String, ?sub:String):String {
		return Path.join([repo, name, if(sub != null) sub else ""]);
	}

	function getHaxeVersion():SemVer {
		if (__haxeVersion == null) {
			final p = new sys.io.Process('haxe', ['--version']);
			if (p.exitCode() != 0) {
				throw 'Cannot get haxe version: ${p.stderr.readAll().toString()}';
			}
			final str = p.stdout.readAll().toString();
			__haxeVersion = SemVer.ofString(str.split('+')[0]);
		}
		return __haxeVersion;
	}

	static var __haxeVersion:SemVer;
}
