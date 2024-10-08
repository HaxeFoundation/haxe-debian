package unit;

private typedef Foo = {
	var bar(get, null):Bar;
}

private typedef Bar = {
	var data:Int;
}

private class AdrianV {
	public var bar(get, null):Bar = {data: 100};

	function get_bar() {
		return bar;
	}

	public function new() {}

	static public function testFoo(foo:Foo) {
		return foo.bar.data;
	}
}

@:generic @:keepSub @:keep
class GenericKeepSub<T> {}

class ChildOfGenericKeepSub extends GenericKeepSub<String> {}

@:analyzer(no_local_dce)
class DCEClass {
	// used statics
	static function staticUsed() {}

	@:keep static function staticKeep() {}

	static var staticVarUsed = "foo";
	@:isVar static var staticPropUsed(get, set):Int = 1;

	static function get_staticPropUsed()
		return staticPropUsed;

	static function set_staticPropUsed(i:Int)
		return 0;

	// used members
	function memberUsed() {}

	@:keep function memberKeep() {}

	var memberVarUsed = 0;
	@:isVar var memberPropUsed(get, set):Int = 1;

	function get_memberPropUsed()
		return memberPropUsed;

	function set_memberPropUsed(i:Int)
		return 0;

	// unused statics
	static function staticUnused() {}

	static var staticVarUnused = "bar";
	static var staticPropUnused(get, set):Int;

	static function get_staticPropUnused()
		return 0;

	static function set_staticPropUnused(i:Int)
		return 0;

	// unused members
	function memberUnused() {}

	var memberVarUnused = 1;
	var memberPropUnused(get, set):Int;

	function get_memberPropUnused()
		return 0;

	function set_memberPropUnused(i:Int)
		return 0;

	static var c:Array<Dynamic> = [null, unit.UsedReferenced2];

	public function new() {
		staticUsed();
		staticVarUsed = "foo";
		staticPropUsed = 1;
		staticPropUsed;

		memberUsed();
		memberVarUsed = 0;
		memberPropUsed = 2;
		memberPropUsed;

		new UsedConstructed();

		try
			cast(null, UsedReferenced)
		catch (e:Dynamic) {}

		new UsedAsBaseChild();
		c.push(null);
	}
}

@:analyzer(no_local_dce)
class TestDCE extends Test {
	public function testFields() {
		var dce = new DCEClass();
		var c = Type.getClass(dce);
		hf(c, "memberKeep");
		hf(c, "memberUsed");
		hf(c, "memberVarUsed");
		hf(c, "memberPropUsed");
		hf(c, "get_memberPropUsed");
		hf(c, "set_memberPropUsed");

		hsf(c, "staticKeep");
		hsf(c, "staticUsed");
		hsf(c, "staticVarUsed");
		hsf(c, "staticPropUsed");
		hsf(c, "get_staticPropUsed");
		hsf(c, "set_staticPropUsed");

		nhf(c, "memberUnused");
		nhf(c, "memberVarUnused");
		nhf(c, "memberPropUnused");
		nhf(c, "get_memberPropUnused");
		nhf(c, "set_memberPropUnused");

		nhsf(c, "staticUnused");
		nhsf(c, "staticVarUnused");
		nhsf(c, "staticPropUnused");
		nhsf(c, "get_staticPropUnused");
		nhsf(c, "set_staticPropUnused");
	}

	public function testInterface() {
		var l:UsedInterface = new UsedThroughInterface();
		var l2:UsedInterface = new InterfaceMethodFromBaseClassChild();
		var ic = Type.resolveClass("unit.UsedInterface");
		var c = Type.getClass(l);
		var bc = Type.resolveClass("unit.InterfaceMethodFromBaseClass");

		l.usedInterfaceFunc();
		hf(ic, "usedInterfaceFunc");
		hf(c, "usedInterfaceFunc");
		hf(bc, "usedInterfaceFunc");
		nhf(ic, "unusedInterfaceFunc");
		nhf(c, "unusedInterfaceFunc");
		nhf(bc, "unusedInterfaceFunc");
	}

	public function testProperty() {
		var l:PropertyInterface = new PropertyAccessorsFromBaseClassChild();
		var ic = Type.resolveClass("unit.PropertyInterface");
		var c = Type.getClass(l);
		var bc = Type.resolveClass("unit.PropertyAccessorsFromBaseClass");

		l.x = "bar";
		hf(c, "set_x");
		hf(bc, "set_x");
		hf(ic, "set_x");
		nhf(ic, "get_x");
		nhf(c, "get_x");
		nhf(bc, "get_x");
	}

	// TODO: this should be possible in lua
	#if (!cpp && !java && !cs && !lua)
	public function testProperty2() {
		var a = new RemovePropertyKeepAccessors();
		a.test = 3;
		eq(a.test, 3);
		Reflect.setProperty(a, "test", 2);
		eq(a.test, 2);

		var c = Type.resolveClass("unit.RemovePropertyKeepAccessors");
		hf(c, "get_test");
		hf(c, "set_test");
		hf(c, "_test");
		nhf(c, "test");
	}
	#end

	public function testClasses() {
		t(Type.resolveClass("unit.UsedConstructed") != null);
		t(Type.resolveClass("unit.UsedReferenced") != null);
		t(Type.resolveClass("unit.UsedReferenced2") != null);
		t(Type.resolveClass("unit.UsedInterface") != null);
		t(Type.resolveClass("unit.UsedThroughInterface") != null);
		t(Type.resolveClass("unit.UsedAsBase") != null);
		t(Type.resolveClass("unit.UsedAsBaseChild") != null);

		t(Type.resolveClass("unit.Unused") == null);
		t(Type.resolveClass("unit.UnusedChild") == null);
		t(Type.resolveClass("unit.UnusedImplements") == null);
		t(Type.resolveClass("unit.UsedConstructedChild") == null);
		t(Type.resolveClass("unit.UsedReferencedChild") == null);
	}

	public function testThrow() {
		// class has to be known for this to work
		var c = new ThrownWithToString();
		try {
			throw c;
		} catch (_:Dynamic) {}
		#if js
		if (!js.Browser.supported || js.Browser.navigator.userAgent.indexOf('MSIE 8') == -1)
		#end
		hf(ThrownWithToString, "toString");
	}

	function testIssue6500() {
		t(Type.resolveClass("unit.ChildOfGenericKeepSub") != null);
	}

	public function testIssue7259() {
		var me = new AdrianV();
		AdrianV.testFoo(me);
		var c = Type.getClass(me);
		hf(c, "get_bar");
	}

	public function testIssue10162() {
		eq('bar', foo(ClassWithBar));
	}

	static function foo<T:Class<Dynamic> & {function bar():String;}>(cls:T)
		return cls.bar();
}

class ClassWithBar {
	static public function bar()
		return 'bar';
}

class UsedConstructed {
	public function new() {}
}

class UsedReferenced {}
class UsedReferenced2 {}
class UsedConstructedChild extends UsedConstructed {}
class UsedReferencedChild extends UsedReferenced {}

interface UsedInterface {
	public function usedInterfaceFunc():Void;
	public function unusedInterfaceFunc():Void;
}

class UsedThroughInterface implements UsedInterface {
	public function new() {}

	public function usedInterfaceFunc():Void {}

	public function unusedInterfaceFunc():Void {}

	public function otherFunc() {}
}

class UsedAsBase {}

class UsedAsBaseChild extends UsedAsBase {
	public function new() {}
}

class Unused {}
class UnusedChild extends Unused {}

class UnusedImplements implements UsedInterface {
	public function usedInterfaceFunc():Void {}

	public function unusedInterfaceFunc():Void {}
}

interface PropertyInterface {
	public var x(get, set):String;
}

class PropertyAccessorsFromBaseClass {
	public function get_x()
		return throw "must not set";

	public function set_x(x:String)
		return "ok";
}

class PropertyAccessorsFromBaseClassChild extends PropertyAccessorsFromBaseClass implements PropertyInterface {
	public var x(get, set):String;

	public function new() {}
}

class InterfaceMethodFromBaseClass {
	public function usedInterfaceFunc():Void {}

	public function unusedInterfaceFunc():Void {}
}

class InterfaceMethodFromBaseClassChild extends InterfaceMethodFromBaseClass implements UsedInterface {
	public function new() {}
}

class ThrownWithToString {
	public function new() {}

	public function toString() {
		return "I was thrown today";
	}
}

class RemovePropertyKeepAccessors {
	public function new() {}

	var _test:Float;

	public var test(get, set):Float;

	public function get_test():Float
		return _test;

	public function set_test(a:Float):Float {
		_test = a;
		return _test;
	}
}
