package cases.issues;

class Issue11177 extends TestCase {
	function test(_) {
		vfs.putContent("Main.hx", getTemplate("issues/Issue11177/Main.hx"));
		vfs.putContent("Buttons.hx", getTemplate("issues/Issue11177/Buttons.hx"));
		vfs.putContent("KeyCode.hx", getTemplate("issues/Issue11177/KeyCode.hx"));
		var args = ["-main", "Main", "--interp"];
		runHaxeJsonCb(args, DisplayMethods.Diagnostics, {file: new FsPath("Buttons.hx")}, res -> {
			Assert.equals(0, res.length);
		});
		vfs.putContent("Main.hx", getTemplate("issues/Issue11177/Main2.hx"));
		runHaxeJson([], ServerMethods.Invalidate, {file: new FsPath("Main.hx")});
		runHaxe(args);
		runHaxeJsonCb(args, DisplayMethods.Diagnostics, {file: new FsPath("Buttons.hx")}, res -> {
			Assert.equals(0, res.length);
		});
	}

	function testLegacyDiagnostics(_) {
		vfs.putContent("Main.hx", getTemplate("issues/Issue11177/Main.hx"));
		vfs.putContent("Buttons.hx", getTemplate("issues/Issue11177/Buttons.hx"));
		vfs.putContent("KeyCode.hx", getTemplate("issues/Issue11177/KeyCode.hx"));
		var args = ["-main", "Main", "--interp"];
		runHaxe(args.concat(["--display", "Buttons.hx@0@diagnostics"]));
		vfs.putContent("Main.hx", getTemplate("issues/Issue11177/Main2.hx"));
		runHaxeJson([], ServerMethods.Invalidate, {file: new FsPath("Main.hx")});
		runHaxe(args);
		runHaxe(args.concat(["--display", "Buttons.hx@0@diagnostics"]));
		Assert.isTrue(lastResult.stderr.length == 2);
	}
}
