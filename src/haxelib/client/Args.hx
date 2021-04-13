package haxelib.client;

import haxe.iterators.ArrayIterator;

using StringTools;

class ParsingFail extends haxe.Exception {}

private final splitDash = ~/-[A-Za-z]/g;
private inline function dashSplitToCamel(s:String) {
	return splitDash.map(s, (r) -> r.matched(0).toUpperCase().substr(1));
}

private function parseSwitch(s:String):Null<String> {
	if (s.startsWith('--'))
		return s.substr(2);
	if (s.startsWith('-'))
		return s.substr(1);
	return null;
}

class Args {
	static final FLAGS = [
		"global",
		"debug",
		"quiet",
		"flat",
		"always",
		"never",
		"system",
		"skip-dependencies",
		// hidden
		"notimeout"
	];

	static final ABOUT_FLAGS = [
		"global" => "force global repo if a local one exists",
		"debug" => "run in debug mode, imply not --quiet",
		"quiet" => "print fewer messages, imply not --debug",
		"flat" => "do not use --recursive cloning for git",
		"always" => "answer all questions with yes",
		"never" => "answer all questions with no",
		"system" => "run bundled haxelib version instead of latest update",
		"skip-dependencies" => "do not install dependencies",
	];

	static final MUTUALLY_EXCLUSIVE_FLAGS = [
		["quiet", "debug"],
		["always", "never"]
	];
	static final OPTIONS = ["R"];
	/** Array of options that can be put in more than once**/
	static final REPEATED_OPTIONS = ["cwd"];
	// just because this is how --cwd worked before

	final originalArgs:Array<String>;

	final flags:Array<String> = [];
	final options:Map<String, String> = [];
	final repeatedOptions:Map<String, Array<String>> = [];
	final restIterator:ArrayIterator<String>;

	public function new(args:Array<String>){
		originalArgs = args;
		final rest = [];

		var arg:String;
		var index = 0;

		function requireNext():String {
			final current = args[index - 1];
			final next = args[index++];
			if(next == null)
				throw new ParsingFail('$current requires an extra argument');
			return next;
		}

		while(index < args.length) {
			arg = args[index++];
			switch (parseSwitch(arg)) {
				case flag if (FLAGS.contains(flag)):
					flags.push(flag);

				case option if (OPTIONS.contains(option)):
					options[option] = requireNext();

				case rOption if (REPEATED_OPTIONS.contains(rOption)):
					if(repeatedOptions[rOption] == null)
						repeatedOptions[rOption] = [];
					repeatedOptions[rOption].push(requireNext());
				// case invalid if(invalid != null):
				// 	throw new ParsingFail('unknown switch $arg');
				case _:
					rest.push(arg);
					// put all of them into the rest array
					if (arg == "run")
						while (index < args.length)
							rest.push(args[index++]);
			}
		}
		validate();

		restIterator = rest.iterator();
	}

	function validate() {
		// check if both mutually exclusive flags are present
		for (pair in MUTUALLY_EXCLUSIVE_FLAGS)
			if(flags.contains(pair[0]) && flags.contains(pair[1]))
				throw throw new ParsingFail('--${pair[0]} and --${pair[1]} are mutually exclusive');
	}

	public function getAllSettings():Dynamic {
		final settings = {};

		function set<T>(name:String, value:T) {
			Reflect.setField(settings, dashSplitToCamel(name), value);
		}

		for(flag in FLAGS)
			set(flag, flags.contains(flag));

		for(option in OPTIONS)
			set(option, options[option]);

		for(rOption in REPEATED_OPTIONS)
			set(rOption, repeatedOptions[rOption]);

		return settings;
	}

	/** Returns a copy of the original arguments array passed in **/
	public function copyOriginal()
		return originalArgs.copy();

	/** Returns the next argument **/
	public function getNext():Null<String> {
		if (restIterator.hasNext())
			return restIterator.next();
		return null;
	}

	/** Returns any remaining arguments **/
	public function getRemaining()
		return [ for (arg in restIterator) arg ];

	/**
		Returns an array of objects storing the names and
		descriptions for available switches.
	**/
	public static function getSwitchInfo(): Array<{name:String, description:String}>{
		final info = [];
		// flags to get settings on
		final visibleSwitches = [for (key in ABOUT_FLAGS.keys()) key];
		for(flag in FLAGS){
			if(visibleSwitches.contains(flag)){
				info.push({
					name: flag,
					description: ABOUT_FLAGS[flag]
				});
			}
		}
		return info;
	}

}
