package haxelib.api;

import haxelib.VersionData;
import haxelib.api.LibraryData;
import haxelib.api.ScriptRunner;

using StringTools;

/** Information on the installed versions of a library. **/
typedef InstallationInfo = {
	final name:ProjectName;
	final versions:Array<String>;
	final current:String;
	final devPath:Null<String>;
}

// class ResolvedLibrary {
// 	public final name:ProjectName;
// 	/** The internal type of the library **/
// 	public final version:SemVer;
// 	public final path:String;
// 	public var dependencies(get, null):Map<ProjectName, Null<Version>>;
// 	public function get_dependencies(){
// 		return dependencies.copy();
// 	}
// 	final type:ResolvedType;
// 	function new(name:ProjectName, type:ResolvedType, version:SemVer, path:String, dependencies:Map<ProjectName, Null<Version>>){
// 		this.name = name;
// 		this.version = version;
// 		this.path = path;
// 		this.type = type;
// 		this.dependencies = dependencies;
// 	}
// 	@:allow(haxelib.client.GlobalScope)
// 	static function fromLock(name:ProjectName, libData:LibraryData, dependencyVersions:Map<ProjectName, Version>):ResolvedLibrary {
// 		final version:Version = if (libData.vcs != null) libData.vcs.type else libData.version;
// 		final type = Installed(version);
// 		return new ResolvedLibrary(name, type, libData.version, libData.path, [for (d in libData.dependencies) d => null]);
// 	}
// 	@:allow(haxelib.client.GlobalScope)
// 	static function fromDev(name:ProjectName, version:SemVer, path:String, dependencies:Map<ProjectName, Version>) {
// 		return new ResolvedLibrary(name, Dev, version, path, dependencies);
// 	}
// 	public function getVersionString():String {
// 		return switch (type) {
// 			case Installed(ver):
// 				ver;
// 			case Dev:
// 				"dev";
// 		}
// 	}
// }

class ScopeException extends haxe.Exception {}

/**
	Returns scope for directory `dir`. If `dir` is omitted, uses the current
	working directory.

	The scope will resolve libraries to the local repository if one exists,
	otherwise to the global one.
**/
function getScope(?dir:String):Scope {
	dir = dir ?? Sys.getCwd();
	final localScopeDirectory = LocalScope.findLocalScope(dir);
	if (localScopeDirectory == null)
		return @:privateAccess new GlobalScope(Repository.get(dir));
	return @:privateAccess new LocalScope(Repository.get(localScopeDirectory), localScopeDirectory);
}

/** Returns the global scope. **/
function getGlobalScope(?dir:String):GlobalScope {
	@:privateAccess
	return new GlobalScope(Repository.get(dir));
}

/**
	Returns scope created for directory `dir`, resolving libraries to `repository`

	If `dir` is omitted, uses the current working directory.
**/
function getScopeForRepository(repository:Repository, ?dir:String):Scope {
	dir = dir ?? Sys.getCwd();
	final localScopeDirectory = LocalScope.findLocalScope(dir);
	if (localScopeDirectory == null)
		return @:privateAccess new GlobalScope(repository);
	return @:privateAccess new LocalScope(repository, localScopeDirectory);
}

/**
	This is an abstract class which the GlobalScope (and later on LocalScope)
	inherits from.

	It is responsible for managing current library versions, resolving them,
	giving information on them, or running them.
**/
abstract class Scope {
	/** Whether the scope is local. **/
	public final isLocal:Bool;
	/** The repository which is used to resolve the scope's libraries. **/
	public final repository:Repository;
	final overrides:LockFormat;

	function new(isLocal:Bool, repository:Repository) {
		this.isLocal = isLocal;
		this.repository = repository;

		overrides = loadOverrides();
	}

	/* TODO: This method should maybe check global overrides file in the future,
		and give a warning if a global version of the library will still be available
		after the local one is removed.
	*/
	//public abstract function remove(library:ProjectName, ?version:Version):Void;

	/**
		Runs the script for `library` with `callData`.

		If `version` is specified, that version will be used,
		or an error is thrown if that version isn't installed
		in the scope.

		Should the script return a non zero code, a ScriptError
		exception is thrown containing the error code.
	**/
	public abstract function runScript(library:ProjectName, ?callData:CallData, ?version:Version):Void;

	/** Returns the current version of `library`, ignoring overrides and dev directories. **/
	public abstract function getVersion(library:ProjectName):Version;

	/**
		Set `library` to `version`.

		Requires that the library is already installed.
	  **/
	public abstract function setVersion(library:ProjectName, version:SemVer):Void;
	/**
		Set `library` to `vcsVersion`, with `data`.

		If `data` is omitted or incomplete then the required data is obtained manually.

		Requires that the library is already installed.
	**/
	public abstract function setVcsVersion(library:ProjectName, vcsVersion:VcsID, ?data:VcsData):Void;

	/** Returns whether `library` is currently installed in this scope (ignoring overrides). **/
	public abstract function isLibraryInstalled(library:ProjectName):Bool;

	/** Returns whether `library` version is currently overridden. **/
	public abstract function isOverridden(library:ProjectName):Bool;

	/** Returns an array of the libraries in the scope. **/
	public abstract function getLibraryNames():Array<ProjectName>;

	/**
		Returns an array of installation information on libraries in the scope.

		If `filter` is given, ignores libraries that do not contain it as a substring.
	 **/
	public abstract function getArrayOfLibraryInfo(?filter:String):Array<InstallationInfo>;

	/**
		Returns the path to the source directory of `version` of `library`.

		If `version` is not specified, the scope's current set version is used.

		If the library does not exist in the scope or is not installed, an error is thrown.

	**/
	public abstract function getPath(library:ProjectName, ?version:Version):String;

	//public abstract function getArgs(library:ProjectName, ?version:Version):Array<String>;

	/** Returns the required build arguments for `version` of `library` as an hxml string. **/
	public abstract function getArgsAsHxml(library:ProjectName, ?version:Version):String;

	/**
		Returns the required build arguments for each library version in `libraries`
		as one combined hxml string.
	**/
	public abstract function getArgsAsHxmlForLibraries(libraries:Array<{library:ProjectName, version:Null<Version>}>):String;

	abstract function resolveCompiler():LibraryData;

	/**
		Returns the full version data for `library`.
	**/
	public abstract function resolve(library:ProjectName):VersionData;

	//function resolve(library:ProjectName, version:Version):LibraryData {}

	// TODO: placeholders until https://github.com/HaxeFoundation/haxe/wiki/Haxe-haxec-haxelib-plan
	static function loadOverrides():LockFormat {
		//return {};
		return @:privateAccess new LockFormat();
	}

}
