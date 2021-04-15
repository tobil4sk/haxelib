package tests;

import sys.FileSystem;
import haxe.io.*;

import haxelib.client.Vcs;
import haxelib.client.Cli;

class TestVcsNotFound extends TestBase
{
	//----------- properties, fields ------------//

	static inline var REPO_ROOT = "test/libraries";
	static inline var REPO_DIR = "vcs-no";
	static var CWD:String = null;

	//--------------- constructor ---------------//
	public function new()
	{
		super();
		CWD = Sys.getCwd();
	}


	//--------------- initialize ----------------//

	override public function setup():Void
	{
		Sys.setCwd(Path.join([CWD, REPO_ROOT]));

		if(FileSystem.exists(REPO_DIR)) {
			deleteDirectory(REPO_DIR);
		}
		FileSystem.createDirectory(REPO_DIR);

		Sys.setCwd(REPO_DIR);
		Cli.set(null, Quiet);
	}

	override public function tearDown():Void
	{
		// restore original CWD & PATH:
		Sys.setCwd(CWD);

		deleteDirectory(Path.join([CWD, REPO_ROOT, REPO_DIR]));
		Cli.set(null, None);
	}

	//----------------- tests -------------------//


	public function testAvailableHg():Void
	{
		assertFalse(getHg().available);
	}

	public function testAvailableGit():Void
	{
		assertFalse(getGit().available);
	}


	public function testCloneHg():Void
	{
		var vcs = getHg();
		try
		{
			vcs.clone(vcs.directory, "https://bitbucket.org/fzzr/hx.signal");
			assertFalse(true);
		}
		catch(error:VcsError)
		{
			switch(error)
			{
				case VcsError.CantCloneRepo(_, repo, stderr): assertTrue(true);
				default: assertFalse(true);
			}
		}
	}

	public function testCloneGit():Void
	{
		var vcs = getGit();
		try
		{
			vcs.clone(vcs.directory, "https://github.com/fzzr-/hx.signal.git");
			assertFalse(true);
		}
		catch(error:VcsError)
		{
			switch(error)
			{
				case VcsError.CantCloneRepo(_, repo, stderr): assertTrue(true);
				default: assertFalse(true);
			}
		}
	}


	//----------------- tools -------------------//

	inline function getHg():Vcs
	{
		return new WrongHg();
	}

	inline function getGit():Vcs
	{
		return new WrongGit();
	}
}



class WrongHg extends Mercurial
{
	public function new()
	{
		super();
		directory = "no-hg";
		executable = "no-hg";
		name = "Mercurial-not-found";
	}

	// copy of Mercurial.searchExecutablebut have a one change - regexp.
	override private function searchExecutable():Void
	{
		super.searchExecutable();

		if(available)
			return;

		// if we have already msys git/cmd in our PATH
		var match = ~/(.*)no-hg-no([\\|\/])cmd$/;
		for(path in Sys.getEnv("PATH").split(";"))
		{
			if(match.match(path.toLowerCase()))
			{
				var newPath = match.matched(1) + executable + match.matched(2) + "bin";
				Sys.putEnv("PATH", Sys.getEnv("PATH") + ";" + newPath);
			}
		}
		checkExecutable();
	}
}

class WrongGit extends Git
{

	public function new()
	{
		super();
		directory = "no-git";
		executable = "no-git";
		name = "Git-not-found";
	}

	// copy of Mercurial.searchExecutablebut have a one change - regexp.
	override private function searchExecutable():Void
	{
		super.searchExecutable();

		if(available)
			return;

		// if we have already msys git/cmd in our PATH
		var match = ~/(.*)no-git-no([\\|\/])cmd$/;
		for(path in Sys.getEnv("PATH").split(";"))
		{
			if(match.match(path.toLowerCase()))
			{
				var newPath = match.matched(1) + executable + match.matched(2) + "bin";
				Sys.putEnv("PATH", Sys.getEnv("PATH") + ";" + newPath);
			}
		}
		if(checkExecutable())
			return;
		// look at a few default paths
		for(path in ["C:\\Program Files (x86)\\Git\\bin", "C:\\Progra~1\\Git\\bin"])
			if(FileSystem.exists(path))
			{
				Sys.putEnv("PATH", Sys.getEnv("PATH") + ";" + path);
				if(checkExecutable())
					return;
			}
	}
}
