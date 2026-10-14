#+build windows
package forge

// Windows Credential Manager (generic credentials, target "SERVICE:<host>").
// core:sys/windows has no Cred* bindings, so they are declared here.

import "core:strings"
import win32 "core:sys/windows"

foreign import advapi32 "system:Advapi32.lib"

@(private="file") CRED_TYPE_GENERIC          :: 1
@(private="file") CRED_PERSIST_LOCAL_MACHINE :: 2

@(private="file")
CREDENTIALW :: struct {
	Flags:              win32.DWORD,
	Type:               win32.DWORD,
	TargetName:         win32.LPWSTR,
	Comment:            win32.LPWSTR,
	LastWritten:        win32.FILETIME,
	CredentialBlobSize: win32.DWORD,
	CredentialBlob:     [^]u8,
	Persist:            win32.DWORD,
	AttributeCount:     win32.DWORD,
	Attributes:         rawptr,
	TargetAlias:        win32.LPWSTR,
	UserName:           win32.LPWSTR,
}

@(default_calling_convention = "system", private = "file")
foreign advapi32 {
	CredWriteW :: proc(Credential: ^CREDENTIALW, Flags: win32.DWORD) -> win32.BOOL ---
	CredReadW  :: proc(TargetName: win32.LPCWSTR, Type: win32.DWORD, Flags: win32.DWORD, Credential: ^^CREDENTIALW) -> win32.BOOL ---
	CredFree   :: proc(Buffer: rawptr) ---
}

@(private)
_wincred_load :: proc(host: string) -> (tok: string, ok: bool) {
	target := win32.utf8_to_wstring(strings.concatenate({SERVICE, ":", host}, context.temp_allocator), context.temp_allocator)
	cred: ^CREDENTIALW
	if !CredReadW(target, CRED_TYPE_GENERIC, 0, &cred) || cred == nil { return "", false }
	defer CredFree(cred)
	if cred.CredentialBlobSize == 0 { return "", false }
	return strings.clone(string(cred.CredentialBlob[:cred.CredentialBlobSize])), true
}

@(private)
_wincred_save :: proc(host, tok: string) -> (err: string) {
	target := win32.utf8_to_wstring(strings.concatenate({SERVICE, ":", host}, context.temp_allocator), context.temp_allocator)
	user   := win32.utf8_to_wstring(host, context.temp_allocator)
	blob   := transmute([]u8)tok
	cred := CREDENTIALW{
		Type               = CRED_TYPE_GENERIC,
		TargetName         = win32.LPWSTR(rawptr(target)),
		CredentialBlobSize = win32.DWORD(len(blob)),
		CredentialBlob     = raw_data(blob),
		Persist            = CRED_PERSIST_LOCAL_MACHINE,
		UserName           = win32.LPWSTR(rawptr(user)),
	}
	if !CredWriteW(&cred, 0) { return strings.clone("could not save token in the Windows Credential Manager") }
	return ""
}
