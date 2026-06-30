package lsp_features

import proto "../protocol"
import conn  "../connection"
import "core:encoding/json"
import "core:fmt"
import "core:strings"

Sig_Help_Callback :: proc(result: ^proto.Signature_Help, user: rawptr)

Sig_Help_Feature :: struct {
	c:          ^conn.Conn,
	pending_id: int,
}

sig_help_feature_create :: proc(c: ^conn.Conn) -> ^Sig_Help_Feature {
	sf := new(Sig_Help_Feature)
	sf.c          = c
	sf.pending_id = -1
	return sf
}

sig_help_feature_destroy :: proc(sf: ^Sig_Help_Feature) {
	free(sf)
}

sig_help_cancel :: proc(sf: ^Sig_Help_Feature) {
	if sf.pending_id >= 0 {
		conn.cancel_request(sf.c, sf.pending_id)
		sf.pending_id = -1
	}
}

_Sig_CB_Data :: struct {
	cb:   Sig_Help_Callback,
	user: rawptr,
}

_on_sig_response :: proc(result: json.Value, error: json.Value, user: rawptr) {
	cb_data := cast(^_Sig_CB_Data)user
	defer free(cb_data)
	defer json.destroy_value(result)
	defer json.destroy_value(error)

	if error != nil || result == nil { cb_data.cb(nil, cb_data.user); return }
	switch result.(type) {
	case json.Null: cb_data.cb(nil, cb_data.user); return
	}

	obj, is_obj := result.(json.Object)
	if !is_obj { cb_data.cb(nil, cb_data.user); return }

	sh := new(proto.Signature_Help)
	sh.active_signature, _ = proto.obj_int(obj, "activeSignature")
	sh.active_parameter,  _ = proto.obj_int(obj, "activeParameter")

	if sigs_arr, ok := proto.obj_arr(obj, "signatures"); ok {
		sh.signatures = make([]proto.Signature_Info, len(sigs_arr))
		for sig_v, i in sigs_arr {
			sig_obj, sok := sig_v.(json.Object)
			if !sok { continue }
			sig := &sh.signatures[i]
			if lbl, ok := proto.obj_str(sig_obj, "label"); ok { sig.label = strings.clone(lbl) }
			if doc, ok := proto.obj_str(sig_obj, "documentation"); ok {
				sig.documentation = strings.clone(doc)
			} else if doc_obj, ok := proto.obj_obj(sig_obj, "documentation"); ok {
				if v, ok2 := proto.obj_str(doc_obj, "value"); ok2 { sig.documentation = strings.clone(v) }
			}
			sig.active_parameter, _ = proto.obj_int(sig_obj, "activeParameter")
			if params_arr, ok2 := proto.obj_arr(sig_obj, "parameters"); ok2 {
				sig.parameters = make([]proto.Parameter_Info, len(params_arr))
				for p_v, j in params_arr {
					p_obj, pok := p_v.(json.Object)
					if !pok { continue }
					p := &sig.parameters[j]
					if lbl, ok3 := proto.obj_str(p_obj, "label"); ok3 { p.label = strings.clone(lbl) }
					if doc, ok3 := proto.obj_str(p_obj, "documentation"); ok3 {
						p.documentation = strings.clone(doc)
					} else if doc_obj, ok3 := proto.obj_obj(p_obj, "documentation"); ok3 {
						if v, ok4 := proto.obj_str(doc_obj, "value"); ok4 { p.documentation = strings.clone(v) }
					}
				}
			}
		}
	}
	cb_data.cb(sh, cb_data.user)
}

sig_help_request :: proc(sf: ^Sig_Help_Feature, uri: string, pos: proto.Position,
                          trigger_char: string, retrigger: bool,
                          cb: Sig_Help_Callback, user: rawptr) {
	sig_help_cancel(sf)

	trigger_kind := 1
	trigger_part := ""
	retrigger_str := "false"
	if trigger_char != "" {
		trigger_kind = 2
		trigger_part = fmt.tprintf(`,"triggerCharacter":%s`, proto.json_str(trigger_char))
	}
	if retrigger {
		trigger_kind = 3
		retrigger_str = "true"
	}
	params := fmt.tprintf(
		`{"textDocument":{"uri":%s},"position":{"line":%d,"character":%d},"context":{"triggerKind":%d,"isRetrigger":%s%s}}`,
		proto.json_str(uri), pos.line, pos.character, trigger_kind, retrigger_str, trigger_part)

	cb_data := new(_Sig_CB_Data)
	cb_data.cb   = cb
	cb_data.user = user
	sf.pending_id = conn.send_request(sf.c, "textDocument/signatureHelp", params,
		proto.Response_Callback{proc_ = _on_sig_response, user = cb_data})
}
