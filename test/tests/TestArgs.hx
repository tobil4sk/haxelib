package tests;

import haxe.unit.TestCase;
import haxelib.client.Args;

class TestArgs extends TestCase {

	public function testFlags() {
		final settings = new Args([
			"--debug", "--global", "--system", "--skip-dependencies", "--no-timeout",
			"--flat", "--always"
		]).getAllSettings();

		assertTrue(settings.debug);
		assertTrue(settings.global);
		assertTrue(settings.system);
		assertTrue(settings.skipDependencies);
		assertTrue(settings.noTimeout);
		assertTrue(settings.flat);
		assertTrue(settings.always);

		assertFalse(settings.quiet);
		assertFalse(settings.never);
	}

	public function testMutuallyExclusiveFlags() {
		// debug and quiet
		assertFalse(isValid(["--debug", "--quiet"]));
		assertFalse(isValid(["--quiet", "--debug"]));

		// always and never
		assertFalse(isValid(["--always", "--never"]));
		assertFalse(isValid(["--never", "--always"]));

		// everything
		assertFalse(isValid(["--never", "--always", "--debug", "--quiet"]));
	}

	function isValid(args:Array<String>):Bool {
		try {
			new Args(args);
			return true;
		} catch (e:ParsingFail) {
			return false;
		}
	}

	public function testOptions() {
		// one value given
		final settings = new Args(["--remote", "remotePath"]).getAllSettings();
		assertEquals("remotePath", settings.remote);

		// option without value should give error
		assertFalse(isValid(["--remote"]));

		// when a normal option is repeated, should just give the last one.
		final settings = new Args(["--remote", "remotePath", "--remote", "otherPath"]).getAllSettings();
		assertEquals("otherPath", settings.remote);

		// not included
		final settings = new Args([]).getAllSettings();
		assertEquals(null, settings.remote);
	}

	public function testRepeatedOptions() {
		// test once
		final dirs = new Args(["--cwd", "../path"]).getAllSettings().cwd;
		assertEquals(1, dirs.length);
		assertEquals("../path", dirs[0]);

		// multiple times
		final dirs = new Args(["--cwd", "../path", "--cwd", "path2"]).getAllSettings().cwd;
		assertEquals(2, dirs.length);
		assertEquals("../path", dirs[0]);
		assertEquals("path2", dirs[1]);

		// no value given
		final dirs = new Args([]).getAllSettings().cwd;
		assertEquals(null, dirs);
	}

	public function testSingleDashes() {
		// flags
		final settings = new Args([
			"-debug", "-skip-dependencies"
		]).getAllSettings();

		assertTrue(settings.debug);
		assertTrue(settings.skipDependencies);
		// options
		final settings = new Args(["-cwd", "path", "-remote", "remotePath"]).getAllSettings();

		assertEquals("path", settings.cwd[0]);
		assertEquals("remotePath", settings.remote);

		// mixing single and double
		final directories = new Args(["-cwd", "path", "--cwd", "otherPath"]).getAllSettings().cwd;

		assertEquals("path", directories[0]);
		assertEquals("otherPath", directories[1]);
	}

	public function testAliases() {
		final settings = new Args(["-R", "remotePath", "--notimeout"]).getAllSettings();

		assertEquals("remotePath", settings.remote);
		assertTrue(settings.noTimeout);
	}

	public function testCommandArguments() {
		final args = new Args(["path", "libname", "--debug"]);

		assertEquals("path", args.getNext());
		assertEquals("libname", args.getNext());
		// ensure flag IS captured and not given here
		assertEquals(null, args.getNext());

		// test retrieving all arguments
		final args = new Args(["path", "libname", "--debug", "otherlibname", "--always"]).getRemaining();

		final expectedArgs = ["path", "libname", "otherlibname"];

		assertEquals(expectedArgs.length, args.length);

		for(i in 0...expectedArgs.length) {
			assertEquals(expectedArgs[i], args[i]);
		}

	}

	public function testRunCommand() {
		final args = new Args(["run", "libname", "--debug", "value"]);

		assertEquals("run", args.getNext());
		assertEquals("libname", args.getNext());
		// ensure flag ISN'T captured and is still given
		assertEquals("--debug", args.getNext());
		assertEquals("value", args.getNext());
	}

}
