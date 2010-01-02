/* Copyleft 2k9 -- pancake // nopcode.org */

using Vala;

public class SwigWriter : CodeVisitor {
	private CodeContext context;
	private FileStream stream;
	public bool show_externs;
	public bool glib_mode;
	public string[] files;
	public GLib.List<string> includefiles;
	public GLib.List<Method> methods;
	private string classname;
	private string classcname;
	private string externs;
	private string statics;
	private string extends;
	private string enums;
	private string nspace;
	private string modulename;

	public SwigWriter (string name) {
		classname = "";
		statics = "";
		externs = "";
		extends = "";
		enums = "";
		this.modulename = name;
		this.includefiles = new GLib.List<string>();
	}

	private string get_alias (string name) {
		switch (name) {
		case "del":
			return "_del";
		case "continue":
			return "cont";
		}
		return name;
	}

	private string get_ctype (string _type) {
		string type = _type;
		if (type.has_prefix (nspace))
			type = type.substring (nspace.length) + "*";
		if (type.str (".") != null)
			type = type.replace (".", "");

		switch (type) {
		case "bool":
			return "bool"; // no conversion needed
		case "string":
			return "char *"; // ??? 
		case "gint":
	 		return "int";
		case "guint64":
	 		return "unsigned long long";
		case "guint8":
			return "unsigned char";
		case "guint8*":
			return "unsigned char*";
		case "gboolean":
			return "int"; // XXX bool?
		}
		return type;
	}

	private bool is_target_file (string path) {
		foreach (var file in files)
			if (file == path)
				return true;
		return false;
	}

	public override void visit_source_file (SourceFile source) {
		if (is_target_file (source.filename))
			source.accept_children (this);
	}

	public void process_includes (Symbol s) {
		foreach (var foo in s.get_cheader_filenames ()) {
			var include = true;
			foreach (var inc in includefiles) {
				if (inc == foo) {
					include = false;
					break;
				}
			}
			if (include)
				includefiles.prepend (foo);
		}
	}

	public void walk_class (Class c) {
		classname = c.name;
		classcname = c.get_cname ();
		process_includes (c);

		{
			var dest = c.destructor;
			var sdest = c.static_destructor;
			var cdest = c.class_destructor;
			print ("DESTRUCTOR: %p %p %p\n", dest, sdest, cdest);
		}
		//print (" ==>%s, %s<==\n", nspace, classcname);

		if (glib_mode)
			classname = "%s%s".printf (nspace, classname);

		if (glib_mode) extends += "typedef struct _%s {\n%%extend {\n".printf (classcname);
		else extends += "%%extend %s {\n".printf (classname);
		foreach (var e in c.get_enums ())
			walk_enum (e);
		foreach (var m in c.get_methods ())
			walk_method (m);
		if (glib_mode) {
			extends += "};\n} %s;\n".printf (classname);
		} else extends += "};\n";
		classname = "";
	}

	public void walk_enum (Enum e) {
		var tmp = "%{\n";
		enums += "/* enum: %s (%s) */\n".printf (
			e.name, e.get_cname ());
		enums += "enum {\n";
		foreach (var v in e.get_values ()) {
			enums += "  %s_%s,\n".printf (e.name, v.name);
			tmp += "#define %s_%s %s\n".printf (e.name, v.name, v.get_cname ());
		}
		extends += enums + "};\n";
		extends += tmp + "%}\n";
		enums = "";
	}

	public void walk_method (Method m) {
		bool notbegin = false;
		string cname = m.get_cname ();
		string name = m.name;
		string alias = get_alias (m.name);
		string ret = get_ctype (m.return_type.to_string ());
		string def_args = "";
		string call_args = "";
		bool void_return = (ret == "void");
		bool is_static = (m.binding & MemberBinding.STATIC) != 0;
		bool is_constructor = (name == ".new"); // weak way to check it?

		if (m.is_private_symbol ())
			return;

		foreach (var foo in m.get_parameters ()) {
			string arg_name = foo.name;
			string arg_type = "???";
			DataType? bar = foo.parameter_type;
			if (bar == null)
				continue;
			arg_type = get_ctype (bar.get_cname ());

			if (notbegin) {
				call_args += ", ";
				def_args += ", ";
			} else notbegin = true;

			def_args += "%s %s".printf (arg_type, arg_name);
			call_args += "%s".printf (arg_name);
		}

		/* object oriented shit */
		if (classname != "") {
			if (is_constructor) {
				externs += "extern %s* %s (%s);\n".printf (classcname, cname, def_args);
				extends += "  %s (%s) {\n".printf (classname, def_args);
				extends += "    return %s (%s);\n  }\n".printf (cname, call_args);
			} else {
				if (is_static)
					statics += "extern %s* %s (%s);\n".printf (classcname, cname, def_args);
				else call_args = "self, " + call_args;
				externs += "extern %s %s (%s*, %s);\n".printf (ret, cname, classname, def_args);
				extends += "  %s %s (%s) {\n".printf (ret, alias, def_args);
				extends += "    %s %s (%s);\n  }\n".printf (
					void_return?"":"return", cname, call_args);
			}
		} else {
			externs += "extern %s %s (%s);\n".printf (ret, cname, def_args);
		}
	}

	public override void visit_namespace (Namespace ns) {
		if (ns.name == null)
			return;

		SourceReference? sr = ns.source_reference;
		if (sr != null && !is_target_file (sr.file.filename))
			return;

		nspace = ns.name;
		process_includes (ns);

		foreach (var m in ns.get_methods ())
			walk_method (m);

		foreach (var c in ns.get_classes ())
			walk_class (c);

		foreach (var e in ns.get_enums ())
			walk_enum (e);

		foreach (var c in ns.get_structs ()) {
			/* TODO: refactor to walk_struct */
			print ("struct: %s\n", c.get_cname ());
			foreach (var m in c.get_methods ())
				walk_method (m);
		}

		ns.accept_children (this);
	}

	public void write_file (CodeContext context, string filename) {
		this.stream = FileStream.open (filename, "w");
		this.context = context;

		context.accept (this);

		stream.printf ("%%module %s\n", modulename);

		stream.printf ("%%{\n");
		stream.printf ("#define bool int\n");
		if (includefiles.length () > 0) {
			foreach (var inc in includefiles)
				stream.printf ("#include <%s>\n", inc);
		}
		stream.printf ("%%}\n");
		foreach (var inc in includefiles)
			stream.printf ("%%include <%s>\n", inc);

		stream.printf ("%s\n", enums);
		if (show_externs)
			stream.printf ("%s\n", externs);
		stream.printf ("%s\n", statics);
		stream.printf ("%s\n", extends);

		this.stream = null;
	}
}
