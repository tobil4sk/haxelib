/*
 * Copyright (C)2005-2016 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */
package haxelib.client;

import haxe.Timer;
import sys.io.FileOutput;

enum OutputMode {
	Quiet;
	Debug;
	None;
}

private class ProgressOut extends haxe.io.Output {
	final o:haxe.io.Output;
	final startSize:Int;
	final start:Float;

	var cur:Int;
	var curReadable:Float;
	var max:Null<Int>;
	var maxReadable:Null<Float>;

	public function new(o, currentSize) {
		this.o = o;
		startSize = currentSize;
		cur = currentSize;
		start = Timer.stamp();
	}

	function report(n) {
		cur += n;

		final tag:String = ((max != null ? max : cur) / 1000000) > 1 ? "MB" : "KB";

		curReadable = tag == "MB" ? cur / 1000000 : cur / 1000;
		curReadable = Math.round(curReadable * 100) / 100; // 2 decimal point precision.

		if (max == null)
			Sys.print('${curReadable} ${tag}\r');
		else {
			maxReadable = tag == "MB" ? max / 1000000 : max / 1000;
			maxReadable = Math.round(maxReadable * 100) / 100; // 2 decimal point precision.

			Sys.print('${curReadable}${tag} / ${maxReadable}${tag} (${Std.int((cur * 100.0) / max)}%)\r');
		}
	}

	public override function writeByte(c) {
		o.writeByte(c);
		report(1);
	}

	public override function writeBytes(s, p, l) {
		final r = o.writeBytes(s, p, l);
		report(r);
		return r;
	}

	public override function close() {
		super.close();
		o.close();

		final downloadedBytes = cur - startSize;
		var time = Timer.stamp() - start;
		var speed = (downloadedBytes / time) / 1000;
		time = Std.int(time * 10) / 10;
		speed = Std.int(speed * 10) / 10;

		final tag:String = (downloadedBytes / 1000000) > 1 ? "MB" : "KB";
		var readableBytes:Float = (tag == "MB") ? downloadedBytes / 1000000 : downloadedBytes / 1000;
		readableBytes = Math.round(readableBytes * 100) / 100; // 2 decimal point precision.
		Sys.println('Download complete: ${readableBytes}${tag} in ${time}s (${speed}KB/s)');
	}

	public override function prepare(m) {
		max = m + startSize;
	}
}

private class ProgressIn extends haxe.io.Input {
	final i:haxe.io.Input;
	final tot:Int;
	var pos:Int;

	public function new(i, tot) {
		this.i = i;
		this.pos = 0;
		this.tot = tot;
	}

	public override function readByte() {
		final c = i.readByte();
		report(1);
		return c;
	}

	public override function readBytes(buf, pos, len) {
		final k = i.readBytes(buf, pos, len);
		report(k);
		return k;
	}

	function report(nbytes:Int) {
		pos += nbytes;
		Sys.print(Std.int((pos * 100.0) / tot) + "%\r");
	}
}

class Cli {
	static var defaultAnswer:Null<Bool> = null;
	static var mode = None;

	public static function set(defaultAnswer:Null<Bool>, ?mode:OutputMode){
		Cli.defaultAnswer = defaultAnswer;
		if(mode != null)
			Cli.mode = mode;
	}

	public static function createDownloadOutput(out:FileOutput, currentSize:Int):haxe.io.Output {
		if (mode == Quiet)
			return out;
		return new ProgressOut(out, currentSize);
	}

	public static function createUploadInput(data:haxe.io.Bytes):haxe.io.Input {
		final dataBytes = new haxe.io.BytesInput(data);
		if (mode == Quiet)
			return dataBytes;
		return new ProgressIn(dataBytes, data.length);
	}

	public static function ask(question:String):Bool {
		if (defaultAnswer != null)
			return defaultAnswer;

		while (true) {
			Sys.print('$question [y/n/a] ? ');
			try {
				switch (Sys.stdin().readLine()) {
					case "n": return false;
					case "y": return true;
					case "a": return defaultAnswer = true;
				}
			} catch (e:haxe.io.Eof) {
				Sys.println("n");
				return false;
			}
		}
		return false;
	}

	public static function getInput(prompt:String) {
		Sys.print('$prompt : ');
		return Sys.stdin().readLine();
	}

	public static function getSecretInput(prompt:String){
		Sys.print('$prompt : ');
		final s = new StringBuf();
		do {
			switch Sys.getChar(false) {
			case 10, 13:
				break;
			case 0: // ignore (windows bug)
			case c:
				s.addChar(c);
			}
		} while (true);
		Sys.println("");
		return s.toString();
	}

	public static inline function print(str)
		Sys.println(str);

	/** Outputs `message` to standard output if not in quiet mode **/
	public static function showOptional(message:String) {
		if (mode == Quiet)
			return;
		Sys.println(message);
	}

	/** Prints a debug message, and adds a newline, only when in debug mode **/
	public static function showDebugMessage(message:String) {
		if (mode != Debug)
			return;
		Sys.println('$message\n');
	}

	/** Prints a debug message that will be overwritten by the next message,
		only when in debug mode.
	 **/
	public static function showDebugOverwritable(message:String){
		if(mode != Debug)
			return;
		Sys.println('$message\r');
	}

	public static function showWarning(message:String){
		Sys.println('Warning: $message\n');
	}

	/** Adds an error message to the error output **/
	public static function showError(message:String){
		Sys.stderr().writeString('Error: $message\n');
	}

	/** Adds an error message to the error output only if in debug mode **/
	public static function showDebugError(message:String) {
		if (mode != Debug)
			return;
		Sys.stderr().writeString('Error: $message\n');
	}

}
