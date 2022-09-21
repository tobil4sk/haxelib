package tests.integration;

import haxe.io.Bytes;
import haxelib.server.Update;
import haxelib.server.Hashing;
import haxelib.server.SiteDb;

class TestServerDatabaseUpdate extends IntegrationTests {

	override function setup() {
		super.setup();
		// create all the tables
		SiteDb.init();
	}

	override function tearDown() {
		SiteDb.cleanup();
		super.tearDown();
	}

	/**
		Simulates an old database still containing md5 hashes
	**/
	function simulateOldDatabase(users:Array<{
		user:String,
		email:String,
		fullname:String,
		pw:String
	}>) {
		final meta = Meta.manager.all().first();
		meta.dbVersion = 0;
		meta.update();

		for (data in users) {
			final user = new User();
			user.name = data.user;
			user.fullname = data.fullname;
			user.email = data.email;
			user.pass = haxe.crypto.Md5.encode(data.pw);
			// ignore salt and hashmethod
			user.insert();
		}
	}

	function testUpdate() {
		simulateOldDatabase([foo, bar]);

		Update.runNeededUpdates();

		final users = User.manager.all().iterator();
		final fooAccount = users.next();

		assertEquals(fooAccount.pass, Hashing.hash(haxe.crypto.Md5.encode(foo.pw), fooAccount.salt));
		assertEquals(fooAccount.salt.length, 32);
		assertEquals(fooAccount.hashmethod, cast Md5);

		final barAccount = users.next();

		assertEquals(barAccount.pass, Hashing.hash(haxe.crypto.Md5.encode(bar.pw), barAccount.salt));
		assertEquals(barAccount.salt.length, 32);
		assertEquals(barAccount.hashmethod, cast Md5);
	}

	function createNewUserAccount(data:{
		user:String,
		email:String,
		fullname:String,
		pw:String
	}) {
		final user = new User();
		user.name = data.user;
		user.fullname = data.fullname;
		user.email = data.email;
		final salt = Hashing.generateSalt();
		user.pass = Hashing.hash(data.pw, salt);
		user.salt = salt;
		user.hashmethod = Argon2id;
		user.insert();
	}

	function testReUpdate() {
		simulateOldDatabase([foo]);

		// should fix foo account
		Update.runNeededUpdates();

		createNewUserAccount(bar);
		createNewUserAccount(deepAuthor);

		// re-update should not change anything
		Update.runNeededUpdates();

		final users = User.manager.all().iterator();
		final fooAccount = users.next();

		assertEquals(fooAccount.pass, Hashing.hash(haxe.crypto.Md5.encode(foo.pw), fooAccount.salt));
		assertEquals(fooAccount.salt.length, 32);
		assertEquals(fooAccount.hashmethod, cast Md5);

		// accounts added after first update

		final barAccount = users.next();

		assertEquals(barAccount.pass, Hashing.hash(bar.pw, barAccount.salt));
		assertEquals(barAccount.salt.length, 32);
		assertEquals(barAccount.hashmethod, cast Argon2id);

		final deepAccount = users.next();

		assertEquals(deepAccount.pass, Hashing.hash(deepAuthor.pw, deepAccount.salt));
		assertEquals(deepAccount.salt.length, 32);
		assertEquals(deepAccount.hashmethod, cast Argon2id);
	}

}
