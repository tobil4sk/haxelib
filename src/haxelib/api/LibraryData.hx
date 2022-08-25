package haxelib.api;

import haxe.DynamicAccess;

import haxelib.VersionData;

/** Exception thrown upon errors regarding library data, such as invalid versions. **/
class LibraryDataException extends haxe.Exception {}

/**
	Library version, which can be used in commands.

	This type of library version has a physical folder in the project root directory
	(i.e. it is not a dev version)
**/
abstract Version(String) to String from SemVer from VcsID {
	inline function new(s:String) {
		this = s;
	}

	public static function ofString(s:String):Version {
		if (!isValid(s))
			throw new LibraryDataException('`$s` is not a valid library version');
		return new Version(s);
	}

	static function ofStringUnsafe(s:String):Version {
		return new Version(s);
	}

	/** Returns whether `s` constitues a valid library version. **/
	public static function isValid(s:String):Bool {
		return VcsID.isValid(s) || SemVer.isValid(s);
	}
}

/** A library version which can only be `dev`. **/
@:noDoc
enum abstract Dev(String) to String {
	final Dev = "dev";
}

/** Like `Version`, but also has the possible value of `dev`. **/
abstract VersionOrDev(String) from VcsID from SemVer from Version from Dev to String {}

/** Data for a library installed from the haxelib server. **/

typedef LibraryData = {
	final version:SemVer;
}

/** Data for a library installed via vcs. **/
typedef VcsLibraryData = {
	final version:VcsID;
	/** Reproducible vcs information **/
	final vcs:VcsData;
}

/** Data for a library located in a local development path. **/
typedef DevLibraryData = {
	final version:Dev;
	final path:String;
}

private final hashRegex = ~/^([a-f0-9]{7,40})$/;
function isCommitHash(str:String)
	return hashRegex.match(str);


function matchLibraryData(version:Version, libData:LibraryData):Bool {
	// check that version matches
	return cast(version, VersionOrDev) == libData.version;
}

@:forward
abstract LockFormat(Map<ProjectName, VersionData>) {
	inline function new()
		this = [];

	@:from
	public static function fromDynamic(object:Dynamic):LockFormat {
		final lock = new LockFormat();

		for (field in Reflect.fields(object)) {
			final name = ProjectName.ofString(field);
			final dataObject = Reflect.field(object, field);
			final versionString = Reflect.field(dataObject, "version");
			final data:VersionData = switch versionString {
				case v if (SemVer.isValid(v)):
					Haxelib(SemVer.ofString(v));
				case v if (VcsID.isValid(v)):
					VcsInstall(VcsID.ofString(v), {
						url: dataObject.vcs.url,
						ref: dataObject.vcs.ref,
						tag: dataObject.vcs.tag,
						branch: dataObject.vcs.branch,
						subDir: dataObject.vcs.subDir,
					});
				case null: throw 'Library $name has no field `version`';
				default: throw 'Library $name has invalid `version` value';
			}
			lock[name] = data;
		}
		return lock;
	}

	@:op([])
	public function get(name:ProjectName)
		return this[name];

	@:op([])
	public function set(name:ProjectName, data:VersionData)
		this[name] = data;
}
