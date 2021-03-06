module nectar_client.util;

import std.conv : to;
import std.json;

immutable string TIMEZONE_MAPPINGS_URL = "https://gist.githubusercontent.com/jython234/ad5827eb14b5c22109ba652a1a267af5/raw/9769d8a1fe06aaac660ea7148c1fcf6ad1ebb160/timezone-mappings.csv";

version(Windows) {
	immutable string PATH_SEPARATOR = "\\";
} else {
	immutable string PATH_SEPARATOR = "/";
}

@safe unittest {
	assert(convertTZLinuxToWindows("America/Chicago") == "Central Standard Time");
	assert(convertTZWindowsToLinux("Central Standard Time") == "America/Chicago");
}

enum ClientState {
	ONLINE = 0,
	SHUTDOWN = 1,
	SLEEP = 2,
	RESTART = 3,
	UNKNOWN = 4
}

static ClientState fromInt(int state) @safe {
	switch(state) {
		case 0:
			return ClientState.ONLINE;
		case 1:
			return ClientState.SHUTDOWN;
		case 2:
			return ClientState.SLEEP;
		case 3:
			return ClientState.RESTART;
		default:
			throw new Exception("State is invalid.");
	}
}

/**
 * Get the current time in milliseconds (since epoch).
 * This method uses bindings to the C functions gettimeofday and
 * GetSystemTime depending on the platform.
 */
long getTimeMillis() @system nothrow {
	version(Posix) {
		pragma(msg, "INFO: Using core.sys.posix.sys.time.gettimeofday() for getTimeMillis()");
		import core.sys.posix.sys.time;

		timeval t;
		gettimeofday(&t, null);
		
		return (t.tv_sec) * 1000 + (t.tv_usec) / 1000;
	} else version(Windows) {
		pragma(msg, "INFO: Using core.sys.windows.winbase.GetSystemTime() for getTimeMillis()");
		import core.sys.windows.winbase : FILETIME, GetSystemTimeAsFileTime;
		import core.sys.windows.winnt : LARGE_INTEGER;
		
		FILETIME ftime;
		GetSystemTimeAsFileTime(&ftime);
		
		LARGE_INTEGER date, adjust;
		
		date.HighPart = ftime.dwHighDateTime;
		date.LowPart = ftime.dwLowDateTime;
		
		adjust.QuadPart = 11644473600000 * 10000;
		
		date.QuadPart -= adjust.QuadPart;
		
		return date.QuadPart / 10000;
	} else {
		//pragma(msg, "Need to implement getTimeMillis() for this platform!");
		assert(0, "Need to implement getTimeMillis() for this platform!");
	}
}

JSONValue getPeerInfo() {
	import nectar_client.client : SOFTWARE, SOFTWARE_VERSION, RUNTIME, API_MAJOR, API_MINOR;
	import std.system : os;
	import std.socket : Socket;
	import core.cpuid;

	JSONValue root = JSONValue();
	root["software"] = SOFTWARE;
	root["softwareVersion"] = SOFTWARE_VERSION;
	root["apiVersionMajor"] = to!int(API_MAJOR);
	root["apiVersionMinor"] = to!int(API_MINOR);
	root["serverID"] = "unknown";
	root["hostname"] = Socket.hostName();
	
	JSONValue sysInfo = JSONValue();

	sysInfo["runtime"] = RUNTIME;
	version(X86) {
		sysInfo["arch"] = "x86";
	} else version(X86_64) {
		sysInfo["arch"] = "x86_64";
	} else version(ARM) {
		sysInfo["arch"] = "ARM";
	} else {
		sysInfo["arch"] = "unknown";
	}
	sysInfo["os"] = to!string(os);
	sysInfo["osVersion"] = "unknown";
	sysInfo["cpu"] = processor();
	sysInfo["cpus"] = coresPerCPU();

	root["systemInfo"] = sysInfo;

	return root;
}

JSONValue getUpdatesInfo() {
	import std.stdio : File;
	import std.file : readText;
	import std.string;
	import std.process;

	JSONValue root = JSONValue();

	version(linux) {
		//File tmpOut = createNewTmpSTDIOFile("nectar-client-apt-check-output.txt");

		try {
			//auto pid = spawnProcess(["/usr/lib/update-notifier/apt-check"], std.stdio.stdin, tmpOut, tmpOut);
			auto pipes = pipeProcess("/usr/lib/update-notifier/apt-check", Redirect.stdout | Redirect.stderr);

			if(wait(pipes.pid) != 0) {
				// Process exited with non-zero exit code, set to unknown.
				root["securityUpdates"] = -1;
				root["updates"] = -1;
			} else {
				string[] exploded = pipes.stderr.readln().split(";");
				root["securityUpdates"] = to!int(exploded[1]);
				root["updates"] = to!int(exploded[0]);
			}
		} catch(ProcessException e) {
			// Failed to get the update count, set to unknown then.
			root["securityUpdates"] = -1;
			root["updates"] = -1;	
		}
	} else {
		pragma(msg, "WARN: getUpdatesInfo() only supports Linux currently.");

		root["securityUpdates"] = -1;
		root["updates"] = -1;
	}

	return root;
}

string getNewExecutablePath(in bool useSystemDirs = false) @system {
	if(!useSystemDirs) {
		return "."; // Current directory
	}
	
	version(Posix) {
		return "/var/cache";
	} else {
		return "C:\\NectarClient";
	}
}

std.stdio.File createNewTmpSTDIOFile(in string name, in string mode = "w") @system {
	import std.stdio : File;

	return File(getTempDirectoryPath() ~ PATH_SEPARATOR ~ name, mode);
}

string getTempDirectoryPath() @system {
	version(Posix) {
		import core.stdc.stdlib : getenv;
		import std.string: toStringz, fromStringz;

		auto env = fromStringz(getenv(toStringz("TMPDIR")));
		if(env == "") {
			return "/tmp";
		} else return cast(string) env;
	} else version(Windows) {
		import core.sys.windows.winbase : GetTempPath, DWORD, TCHAR;
		import std.string : fromStringz;
		
		//TCHAR[128] data;
		//DWORD length = GetTempPath(128, data.ptr);
		//return cast(string) fromStringz(cast(char*) data[0..length].ptr);
		return "C:\\Windows\\Temp";
	} else {
		pragma(msg, "WARN: Need to implement getTempDirectoryPath() correctly for this operating system.");
		
		return "tmp"; // From current directory
	}
}

string convertTZLinuxToWindows(in string linuxTZ) @trusted {
	import std.file : exists, readText;
	import std.csv : csvReader;
	import std.net.curl : download;
	import std.typecons : Tuple;

	string mappingsFile = getTempDirectoryPath() ~ PATH_SEPARATOR ~ "nectar-client-timezone-mappings.csv";
	if(!exists(mappingsFile)) {
		try {
			download(TIMEZONE_MAPPINGS_URL, mappingsFile);
		} catch(Exception e) {
			throw new Exception("Failed to download Timezone mappings from " ~ TIMEZONE_MAPPINGS_URL);
		}
	}

	auto content = readText(mappingsFile);
	foreach(record; csvReader!(Tuple!(string, string, string))(content)) {
		if(record[2] == linuxTZ) {
			return record[0];
		}
	}

	return linuxTZ;
}

string convertTZWindowsToLinux(in string windowsTZ) @trusted {
	import std.file : exists, readText;
	import std.csv : csvReader;
	import std.net.curl : download;
	import std.typecons : Tuple;

	string mappingsFile = getTempDirectoryPath() ~ PATH_SEPARATOR ~ "nectar-client-timezone-mappings.csv";
	if(!exists(mappingsFile)) {
		try {
			download(TIMEZONE_MAPPINGS_URL, mappingsFile);
		} catch(Exception e) {
			throw new Exception("Failed to download Timezone mappings from " ~ TIMEZONE_MAPPINGS_URL);
		}
	}

	auto content = readText(mappingsFile);
	foreach(record; csvReader!(Tuple!(string, string, string))(content)) {
		if(record[0] == windowsTZ) {
			return record[2];
		}
	}

	return windowsTZ;
}

string generateFileSHA256Checksum(in string file) {
	import deimos.openssl.sha;

	import std.stdio : File;

	import core.stdc.stdio : fread, sprintf;


	// Initalize variables
	SHA256_CTX shaCtx;
	File f = File(file, "rb");
	ubyte[SHA256_DIGEST_LENGTH] hash;
	immutable int chunkSize = 8192;
	byte[chunkSize] buffer;

	// Initalize the SHA256 context
	SHA256_Init(&shaCtx);

	// Read chunks from the file and pass them to OpenSSL
	size_t bytesRead = 0;
	while((bytesRead = fread(buffer.ptr, 1, chunkSize, f.getFP())) != false) {
		SHA256_Update(&shaCtx, buffer.ptr, bytesRead);
	}

	// Finalize and create the hash
	SHA256_Final(hash.ptr, &shaCtx);
	f.close();

	// Format the digest to the full length hexadecimal string
	char[SHA256_DIGEST_LENGTH*2+1] output;

	for(uint i = 0; i < SHA256_DIGEST_LENGTH; i++) {
		sprintf(&output[i * 2], "%02X", hash[i]);
	}

	// There is an extra zero at the end of the array, which causes problems when checking if hashes are equal.
	return cast(string) (output.dup[0..$-1]);
}

// THE FOLLOWING CODE IS FROM THE JWTD PROJECT, UNDER THE MIT LICENSE
// You can find the original project and code here: https://github.com/olehlong/jwtd

/**
 * Encode a string with URL-safe Base64.
 */
string urlsafeB64Encode(string inp) pure nothrow {
	import std.base64 : Base64URL;
	import std.string : indexOf;

	auto enc = Base64URL.encode(cast(ubyte[])inp);
	auto idx = enc.indexOf('=');
	return cast(string)enc[0..idx > 0 ? idx : $];
}

/**
 * Decode a string with URL-safe Base64.
 */
string urlsafeB64Decode(string inp) pure {
	import std.base64 : Base64URL;
	import std.array : replicate;

	int remainder = inp.length % 4;
	if(remainder > 0) {
		int padlen = 4 - remainder;
		inp ~= replicate("=", padlen);
	}
	return cast(string)(Base64URL.decode(cast(ubyte[])inp));
}

// END JWTD

bool jsonValueToBool(std.json.JSONValue value) {
	import std.json : JSON_TYPE;

	switch(value.type) {
		case JSON_TYPE.TRUE:
			return true;
		case JSON_TYPE.FALSE:
			return false;
		default:
			throw new Exception("Value is not a boolean!");
	}
}

import std.net.curl;

template RequestErrorHandleMixin(string operation, int[] expectedStatusCodes, bool fatal, bool doReturn = false) {
	const char[] RequestErrorHandleMixin = 
	"
	bool failure = false;

	if(!(ce is null) && !canFind(ce.toString(), \"request returned status code\")) {
		logger.error(\"Failed to connect to \" ~ url ~ \", CurlException.\");
		logger.trace(ce.toString());
		logger." ~ (fatal ? "fatal" : "error") ~ "(\"Failed to process " ~ operation ~ "!\");
		failure = true;
		" ~ (doReturn ? "return;" : "") ~ "
	}

	if(!canFind(" ~ to!string(expectedStatusCodes) ~ ", status)) {
		logger.error(\"Failed to connect to \" ~ url ~ \", server returned non-expected status code. (\" ~ to!string(status) ~ \")\");
		logger." ~ (fatal ? "fatal" : "error") ~ "(\"Failed to process " ~ operation ~ "!\");
		failure = true;
		" ~ (doReturn ? "return;" : "") ~ "
	}
	";
}

void issueGETRequest(in string url, void delegate(ushort status, string content, CurlException err) callback) @trusted {

	string content;

	auto request = HTTP(url);
	try {
		content = cast(string) get(url, request);
	} catch(CurlException e) {
		callback(request.statusLine().code, content, e);
		return;
	}

	callback(request.statusLine().code, content, null);
}

void issueGETRequestDownload(in string url, in string downloadLocation) @system {
	import etc.c.curl;

	import std.string : toStringz;
	import std.stdio : File;
	import std.array : split, join;
	import std.file : mkdirRecurse;

	// In case this file is under directories that have not been created, create the parent ones that house the file

	// Split the downloadLocation string by path separator to isolate the actual filename and remove it from the path, leaving the parent directories only.
	string[] pathDirsArray = split(downloadLocation, PATH_SEPARATOR)[0..$ - 1];
	string pathDirs = join(pathDirsArray, PATH_SEPARATOR);

	mkdirRecurse(pathDirs); // Recursively create new directories that this file may need, if they exist it ignores them

	// Variables

	CURL *curl;
	CURLcode res;
	auto urlPtr = toStringz(url);
	auto outName = toStringz(downloadLocation);

	// Begin download process

	curl = curl_easy_init();
	if(curl) {
		File file = File(downloadLocation, "wb");
		curl_easy_setopt(curl, CurlOption.url, toStringz(url));
		curl_easy_setopt(curl, CurlOption.writefunction, &issueGETRequestDownload_writeData);
		curl_easy_setopt(curl, CurlOption.writedata, file.getFP());

		CURLcode response = curl_easy_perform(curl);

		debug {
			import std.stdio;
			writeln("CURLcode is: ", response);
		}

		curl_easy_cleanup(curl);
		file.close();
	}
}

extern(C) private size_t issueGETRequestDownload_writeData(void *ptr, size_t size, size_t nmemb, core.stdc.stdio.FILE *stream) {
	import core.stdc.stdio;
	return fwrite(ptr, size, nmemb, stream);
}

