/*
 * Copyright (c) 2006, Motion-Twin
 * All rights reserved.
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 *   - Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 *   - Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY MOTION-TWIN "AS IS" AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE HAXE PROJECT CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
 * DAMAGE.
 */
package mtwin.mail.imap;

import neko.net.Socket;
import mtwin.mail.Exception;
import mtwin.mail.imap.Tools;

enum FlagMode {
	Add;
	Remove;
	Replace;
}

typedef FetchResponse = {
	id: Int,
	uid: Int,
	bodyType: String,
	body: String,
	flags: Flags,
	structure: BodyStructure,
	internalDate: String,
	envelope: Envelope
}

class Connection {
	public static var DEBUG = false;
	public static var TIMEOUT = 25;

	var cnx : Socket;
	var count : Int;
	var selected : String;
	var logged : Bool;

	static var REG_RESP = ~/(OK|NO|BAD) (\[([^\]]+)\] )?(([A-Z]{2,}) )? ?(.*)/;
	static var REG_EXISTS = ~/^([0-9]+) EXISTS$/;
	static var REG_RECENT = ~/^([0-9]+) RECENT$/;
	static var REG_UNSEEN = ~/^OK \[UNSEEN ([0-9]+)\]/;
	static var REG_FETCH_MAIN = ~/([0-9]+) FETCH \(/;
	static var REG_FETCH_PART = ~/^(BODY\[[A-Za-z0-9.]*\]|RFC822\.?[A-Z]*) \{([0-9]+)\}/;
	static var REG_FETCH_FLAGS = ~/^FLAGS \(([ \\A-Za-z0-9$]*)\) */;
	static var REG_FETCH_UID = ~/^UID ([0-9]+) */;
	static var REG_FETCH_BODYSTRUCTURE = ~/^BODY(STRUCTURE)? \(/;
	static var REG_FETCH_ENVELOPE = ~/^ENVELOPE \(/;
	static var REG_FETCH_INTERNALDATE = ~/^INTERNALDATE "([^"]+)" */;
	static var REG_FETCH_END = ~/^([A0-9]{4}) (OK|BAD|NO)/;
	static var REG_STATUS = ~/STATUS .*? \(([^)]+)\)/;
	static var REG_STATUS_VAL = ~/^ ?([A-Z]+) (-?[0-9]+)/;
	static var REG_LIST_RESP = ~/LIST \(([ \\A-Za-z0-9]*)\) [A-z0-9".]* "?([^"]+)"?/;
	static var REG_CRLF = ~/\r?\n/g;

	static function rmCRLF(s){
		return REG_CRLF.replace(s, "");
	}

	static function debug(s:String){
		if( DEBUG ) neko.Lib.print(Std.string(s)+"\n");
	}

	//////

	public function new(){
		count = 0;
		logged = false;
	}

	/**
		Connect to Imap Server
	**/
	public function connect( host : String, ?port : Int ){
		if( cnx != null ) throw AlreadyConnected;

		if( port == null ) port = 143;
		cnx = new Socket();
		try{
			cnx.connect( new neko.net.Host(host), port );
		}catch( e : Dynamic ){
			cnx.close();
			throw ConnectionError(host,port);
		}
		debug("socket connected");
		cnx.setTimeout( TIMEOUT );
		cnx.input.readLine();
		logged = false;
	}

	/**
		Login to server
	**/
	public function login( user : String, pass : String ){
		var r = command("LOGIN",Tools.quote(user)+" "+Tools.quote(pass));
		if( !r.success ){
			throw BadResponse(r.response);
		}
		logged = true;
	}

	/**
		Logout
	**/
	function logout(){
		if( !logged ) return;
		var r = command("LOGOUT");
		if( !r.success ) throw BadResponse(r.response);
		logged = false;
	}

	/**
		Close connection to server
	**/
	public function close(){
		logout();
		cnx.close();
		cnx = null;
	}

	/**
		List mailboxes that match pattern (all mailboxes if pattern is null)
	**/
	public function mailboxes( ?pattern : String, ?flat : Bool ) : Array<Mailbox> {
		if( pattern == null ) pattern = "*";
		if( flat == null ) flat = false;

		var r = command("LIST",Tools.quote("")+" "+Tools.quote(pattern));
		if( !r.success ){
			throw BadResponse(r.response);
		}

		var hash = new Hash();
		for( v in r.result ){
			if( REG_LIST_RESP.match(v) ){
				var name = REG_LIST_RESP.matched(2);
				var flags = REG_LIST_RESP.matched(1).split(" ");

				var t = Mailbox.init( this, name, flags );
				hash.set(name,t);
			}
		}

		var ret = new Array();
		for( t in hash ){
			var a = t.name.split(".");
			a.pop();
			var p = a.join(".");
			if( p.length > 0 && hash.exists(p) ){
				var par = hash.get(p);
				par.children.push( t );
				untyped t.parent = par;
				if( flat ) ret.push( t );
			}else{
				ret.push( t );
			}

		}

		return ret;
	}

	public function getMailbox( name : String ){
		var m = mailboxes(name)[0];
		if( m == null )
			throw "No such mailbox "+name;
		return m;
	}

	/**
		Select a mailbox
	**/
	public function select( mailbox : String ){
		if( selected == mailbox ) return null;

		var r = command("SELECT",Tools.quote(mailbox));
		if( !r.success )
			throw BadResponse(r.response);

		selected = mailbox;

		var ret = {recent: 0,exists: 0,firstUnseen: null};
		for( v in r.result ){
			if( REG_EXISTS.match(v) ){
				ret.exists = Std.parseInt(REG_EXISTS.matched(1));
			}else if( REG_UNSEEN.match(v) ){
				ret.firstUnseen = Std.parseInt(REG_UNSEEN.matched(1));
			}else if( REG_RECENT.match(v) ){
				ret.recent = Std.parseInt(REG_RECENT.matched(1));
			}
		}

		return ret;
	}

	public function status( mailbox : String ){
		var r = command("STATUS",Tools.quote(mailbox)+" (MESSAGES RECENT UNSEEN)");
		if( !r.success ) throw BadResponse( r.response );

		var ret = new Hash<Int>();
		if( REG_STATUS.match( r.result.first() ) ){
			var t = REG_STATUS.matched(1);
			while( REG_STATUS_VAL.match(t) ){
				ret.set(REG_STATUS_VAL.matched(1),Std.parseInt(REG_STATUS_VAL.matched(2)));
				t = REG_STATUS_VAL.matchedRight();
			}
		}else{
			throw UnknowResponse(r.result.first());
		}
		return ret;
	}

	/**
		Search for messages. Pattern syntax described in RFC 3501, section 6.4.4
	**/
	public function search( ?pattern : String, ?useUid : Bool ) : List<Int> {
		if( pattern == null ) pattern = "ALL";
		if( useUid == null ) useUid = false;

		var r = command(if( useUid) "UID SEARCH" else "SEARCH",pattern);
		if( !r.success ){
			throw BadResponse(r.response);
		}

		var l = new List();

		for( v in r.result ){
			if( StringTools.startsWith(v,"SEARCH ") ){
				var t = v.substr(7,v.length-7).split(" ");
				for( i in t ){
					l.add( Std.parseInt(i) );
				}
			}
		}

		return l;
	}

	public function sort( criteria : String, ?pattern : String, ?charset : String, ?useUid : Bool ){
		if( pattern == null ) pattern = "ALL";
		if( useUid == null ) useUid = false;
		if( charset == null ) charset = "US-ASCII";

		var r = command(if( useUid) "UID SORT" else "SORT","("+criteria+") "+charset+" "+pattern);
		if( !r.success ){
			throw BadResponse(r.response);
		}

		var l = new List();

		for( v in r.result ){
			if( StringTools.startsWith(v,"SORT ") ){
				var t = v.substr(5,v.length-5).split(" ");
				for( i in t ){
					l.add( Std.parseInt(i) );
				}
			}
		}

		return l;
	}

	/**
		Fetch messages from the currently selected mailbox.
	**/
	public function fetchRange( iRange: Collection, ?iSection : Array<Section>, ?useUid : Bool ) : List<FetchResponse>{
		if( iRange == null ) return null;
		if( iSection == null ) iSection = [Body(null)];
		if( useUid == null ) useUid = false;

		var range = Tools.collString(iRange);
		var section = Tools.sectionString(iSection);

		if( useUid )
			command("UID FETCH",range+" "+section,false);
		else
			command("FETCH",range+" "+section,false);

		var tmp = new IntHash();
		var ret = new List();
		while( true ){
			var l = cnx.input.readLine();
			if( REG_FETCH_MAIN.match(l) ){
				var id = Std.parseInt(REG_FETCH_MAIN.matched(1));

				var o = if( tmp.exists(id) ){
					tmp.get(id);
				}else {
					var o = {bodyType: null,body: null,flags: null,uid: null,structure: null,internalDate: null,envelope: null,id: id};
					tmp.set(id,o);
					ret.add(o);
					o;
				}

				var s = REG_FETCH_MAIN.matchedRight();
				while( s.length > 0 ){
					if( REG_FETCH_FLAGS.match( s ) ){
						o.flags = REG_FETCH_FLAGS.matched(1).split(" ");
						s = REG_FETCH_FLAGS.matchedRight();
					}else if( REG_FETCH_UID.match( s ) ){
						o.uid = Std.parseInt(REG_FETCH_UID.matched(1));
						s = REG_FETCH_UID.matchedRight();
					}else if( REG_FETCH_INTERNALDATE.match( s ) ){
						o.internalDate = REG_FETCH_INTERNALDATE.matched(1);
						s = REG_FETCH_INTERNALDATE.matchedRight();
					}else if( REG_FETCH_ENVELOPE.match( s ) ){
						var t = REG_FETCH_ENVELOPE.matchedRight();
						t = completeString(t);
						o.envelope = mtwin.mail.imap.Envelope.parse( t );
						s = StringTools.ltrim(t.substr(o.envelope.__length,t.length));
					}else if( REG_FETCH_BODYSTRUCTURE.match( s ) ){
						var t = REG_FETCH_BODYSTRUCTURE.matchedRight();
						t = completeString(t);
						o.structure = mtwin.mail.imap.BodyStructure.parse( t );
						s = StringTools.ltrim(t.substr(o.structure.__length,t.length));
					}else if( REG_FETCH_PART.match( s ) ){
						var len = Std.parseInt(REG_FETCH_PART.matched(2));

						o.body = cnx.input.readString( len );
						o.bodyType = REG_FETCH_PART.matched(1);

						cnx.input.readLine();
						break;
					}else{
						break;
					}
				}

			}else if( REG_FETCH_END.match(l) ){
				var resp = REG_FETCH_END.matched(2);
				if( resp == "OK" ){
					break;
				}else{
					throw BadResponse(l);
				}
			}else{
				throw UnknowResponse(l);
			}
		}

		return ret;
	}

	/**
		Append content as a new message at the end of mailbox.
	**/
	public function append( mailbox : String, content : String, ?flags : Flags ){
		var f = if( flags != null ) "("+flags.join(" ")+") " else "";
		command("APPEND",Tools.quote(mailbox)+" "+f+"{"+content.length+"}",false);
		cnx.write( content );
		cnx.write( "\r\n" );
		var r = read( StringTools.lpad(Std.string(count),"A000",4) );
		if( !r.success )
			throw BadResponse(r.response);
	}

	/**
		Remove permanently all messages flagged as \Deleted in the currently selected mailbox.
	**/
	public function expunge(){
		var r = command("EXPUNGE");
		if( !r.success )
			throw BadResponse(r.response);
	}

	/**
		Add, remove or replace flags on message(s) of the currently selected mailbox.
	**/
	public function storeFlags( iRange : Collection, flags : Flags, ?mode : FlagMode, ?useUid : Bool, ?fetchResult : Bool ) : IntHash<Array<String>> {
		if( mode == null ) mode = Add;
		if( fetchResult == null ) fetchResult = false;
		if( useUid == null ) useUid = false;

		var range = Tools.collString(iRange);
		var elem = switch( mode ){
			case Add: "+FLAGS";
			case Remove: "-FLAGS";
			case Replace: "FLAGS";
		}
		if( !fetchResult ){
			elem += ".SILENT";
		}

		var r = command( if( useUid ) "UID STORE" else "STORE", range + " " + elem + " ("+flags.join(" ")+")");
		if( !r.success ) throw BadResponse( r.response );
		if( !fetchResult ) return null;

		var ret = new IntHash();
		for( line in r.result ){
			if( REG_FETCH_MAIN.match(line) ){
				var id = Std.parseInt(REG_FETCH_MAIN.matched(1));
				if( REG_FETCH_FLAGS.match( REG_FETCH_MAIN.matchedRight() ) ){
					ret.set(id,REG_FETCH_FLAGS.matched(1).split(" "));
				}
			}
		}
		return ret;
	}

	/**
		Create a new mailbox.
	**/
	public function create( mailbox : String ){
		var r = command( "CREATE", Tools.quote(mailbox) );
		if( !r.success ) throw BadResponse( r.response );
	}

	/**
		Delete a mailbox.
	**/
	public function delete( mailbox : String ){
		var r = command( "DELETE", Tools.quote(mailbox) );
		if( !r.success ) throw BadResponse( r.response );
	}

	/**
		Rename a mailbox.
	**/
	public function rename( mailbox : String, newName : String ){
		var r = command( "RENAME", Tools.quote(mailbox)+" "+Tools.quote(newName) );
		if( !r.success ) throw BadResponse( r.response );
	}

	/**
		Copy message(s) from the currently selected mailbox to the end of an other mailbox.
	**/
	public function copy( iRange : Collection, toMailbox : String, ?useUid : Bool ){
		if( useUid == null ) useUid = false;

		var range = Tools.collString(iRange);
		var r = command(if(useUid) "UID COPY" else "COPY",range+" "+Tools.quote(toMailbox));
		if( !r.success ) throw BadResponse( r.response );
	}



	/////

	function completeString( s ){
		var reg = ~/(?<!\] )\{([0-9]+)\}$/;
		while( reg.match( s ) ){
			var len = Std.parseInt( reg.matched(1) );
			var t = cnx.input.readString( len );
			var e = cnx.input.readLine();
			s = s.substr(0,-reg.matchedPos().len)+"\""+t.split("\"").join("\\\"")+"\"" +e;
		}
		return s;
	}

	function command( command : String, ?args : String , ?r : Bool ){
		if( cnx == null )
			throw NotConnected;
		if( r == null ) r = true;
		if( args == null ) args = "" else args = " "+args;

		count++;
		var c = Std.string(count);
		c = StringTools.lpad(c,"A000",4);
		cnx.write( c+" "+command+args+"\r\n" );
		debug( "S: "+c+" "+command+args );

		if( !r ){
			return null;
		}
		return read(c);
	}


	function read( c ){
		var resp = new List();
		var sb : StringBuf = null;
		while( true ){
			var line = cnx.input.readLine();
			debug("R: "+line);
			line = rmCRLF(line);

			if( c != null && line.substr(0,4) == c ){
				if( REG_RESP.match(line.substr(5,line.length-5)) ){
					if( sb != null ){
						resp.add( sb.toString() );
					}
					return {
						result: resp,
						success: REG_RESP.matched(1) == "OK",
						error: REG_RESP.matched(1),
						command: REG_RESP.matched(4),
						response: REG_RESP.matched(6),
						comment: REG_RESP.matched(3)
					};
				}else{
					throw UnknowResponse(line);
				}
			}else{
				if( StringTools.startsWith(line,"* ") ){
					if( sb != null ){
						resp.add( sb.toString() );
					}
					sb = new StringBuf();
					sb.add( line.substr(2,line.length - 2) );
				}else{
					if( sb != null ){
						sb.add( line+"\r\n" );
					}else{
						resp.add( line );
					}
				}
			}
		}
		return null;
	}
}
