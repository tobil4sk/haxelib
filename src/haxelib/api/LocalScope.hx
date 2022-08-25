package haxelib.api;

import haxe.DynamicAccess;
import haxe.Json;
import sys.io.File;
import sys.FileSystem;

import haxelib.VersionData;

import haxelib.api.ScriptRunner.CallData;
import haxelib.api.Scope;
import haxelib.api.LibraryData;

using StringTools;
using haxe.io.Path;

class LocalScopeException extends haxe.Exception {}

/**
	A Local Scope, which resolves libraries using a `haxelib-lock.json` file.
**/
class LocalScope extends Scope {
	static final LOCK_FILE = "haxelib-lock.json";
	final lockData:LockFormat;
	final lockFilePath:String;

	function new(repository:Repository, scopeDir:String) {
		super(true, repository);
		lockFilePath = Path.join([scopeDir, LOCK_FILE]);
		final content = try {
			File.getContent(lockFilePath);
		} catch (e) {
			throw new LocalScopeException('Unable to read data from $lockFilePath: $e');
		}
		lockData = try {
			Json.parse(content);
		} catch (e) {
			throw new LocalScopeException('Invalid lock format in file $lockFilePath: $e');
		}
	}

	function save() {
		final object = {};

		for (name => data in lockData) {
			switch (data) {
				case VcsInstall(version, vcsData):
					Reflect.setField(object, name, {
						version: version,
						vcs: vcsData.getCleaned()
					});
				case Haxelib(version):
					Reflect.setField(object, name, {
						version: version
					});
			}
		}
		sys.io.File.saveContent(lockFilePath, Json.stringify(object, "\t"));
	}

	/**
		Searches up the directory tree for a directory which has a local scope.

		If none is found, returns null.
	 **/
	public static function findLocalScope(dir:String):Null<String> {
		var current = dir;
		while (current != "") {
			final scopeFile = Path.join([current, LOCK_FILE]);
			if (FileSystem.exists(scopeFile))
				return current;
			current = current.directory();
		}
		return null;
	}

	public function runScript(library:ProjectName, ?callData:CallData, ?version:Version) {
		throw new haxe.exceptions.NotImplementedException();
	}

	public function getVersion(library:ProjectName):Version {
		return switch (lockData[library]) {
			case Haxelib(version): version;
			case VcsInstall(version, _): version;
			case null: throw new ScopeException('$library has no version set in the current scope');
		}
	}

	public function setVersion(library:ProjectName, version:SemVer) {
		lockData[library] = Haxelib(version);
		save();
	}

	public function setVcsVersion(library:ProjectName, vcsVersion:VcsID, ?data:VcsData) {
		lockData[library] = VcsInstall(vcsVersion, data);
		save();
	}

	public function isLibraryInstalled(library:ProjectName):Bool {
		return lockData.exists(library);
	}

	public function isOverridden(library:ProjectName):Bool {
		// TODO: Implement
		return false;
	}

	public function getLibraryNames():Array<ProjectName> {
		return [for (name in lockData.keys()) name];
	}

	public function getArrayOfLibraryInfo(?filter:String):Array<InstallationInfo> {
		throw new haxe.exceptions.NotImplementedException();
	}

	public function getPath(library:ProjectName, ?version:Version):String {
		return switch lockData[library] {
			case Haxelib((_:Version) => v) | VcsInstall(v, _) if (version == null || v == version):
				repository.getValidVersionPath(library, v);
			case null if (version == null):
				throw new ScopeException('Library `$library` has no version set in this scope');
			default:
				throw new ScopeException('Library `$library` version `$version` is not set in this scope');
		}
	}

	public function getArgsAsHxml(library:ProjectName, ?version:Version):String {
		throw new haxe.exceptions.NotImplementedException();
	}

	public function getArgsAsHxmlForLibraries(libraries:Array<{library:ProjectName, version:Null<Version>}>):String {
		throw new haxe.exceptions.NotImplementedException();
	}

	function resolveCompiler():LibraryData {
		throw new haxe.exceptions.NotImplementedException();
	}

	public function resolve(library:ProjectName):VersionData {
		if (!lockData.exists(library))
			throw new ScopeException('Library `$library` has no version set in this scope');
		return lockData[library];
	}
}
