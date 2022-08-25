package haxelib;

import haxe.macro.Context;
import haxe.macro.Expr;

// adds a fromDynamic method


// function fromDynamic(object:Dynamic, strict = true);
class DynamicConverter {
	public static macro function build():Array<Field> {
		final fields = Context.getBuildFields();


		// switch (Context.getLocalClass()) {
		// 	case {kind: KAbstractImpl(_.get() => ab)}:

		trace(Context.getLocalClass().get);

		// }
		switch (Context.getLocalClass().get()) {
			case {kind: KAbstractImpl(_.get() => ab), superClass: sc}:
				trace(sc);
			default:
		}




		for (field in fields) {
			trace(field);
		}


		return fields;
	}
}

