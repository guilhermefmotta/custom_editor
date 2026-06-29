package lsp

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// ---------------------------------------------------------------------------
// Signature help manager
// ---------------------------------------------------------------------------

Sig_Help_State :: enum { Idle, Pending, Ready }

Sig_Help_Manager :: struct {
	state:      Sig_Help_State,
	request_id: int,
	result:     Signature_Help,
}

sig_help_manager_init :: proc(m: ^Sig_Help_Manager) {
	m^ = {}
	m.request_id = -1
}

sig_help_manager_destroy :: proc(m: ^Sig_Help_Manager) {
	signature_help_destroy(&m.result)
}

// Request signature help at cursor position.
sig_help_request :: proc(c: ^Language_Client, path: string, line, char: int, retrigger: bool) {
	if c.state != .Running || !c.caps.has_signature_help { return }
	m := &c.sig_help

	if m.state == .Pending && m.request_id >= 0 {
		client_cancel_request(c, m.request_id)
	}

	trigger_kind := 1 // Invoked
	if retrigger { trigger_kind = 3 }

	uri    := path_to_uri(path)
	params := fmt.tprintf(
		`{"textDocument":{"uri":%s},"position":{"line":%d,"character":%d},"context":{"triggerKind":%d,"isRetrigger":%v}}`,
		json_str(uri), line, char, trigger_kind, retrigger,
	)

	m.state = .Pending
	m.request_id = client_send_request(c, "textDocument/signatureHelp", params, Response_Callback{
		proc_ = _on_sig_help_response,
	})
}

sig_help_clear :: proc(c: ^Language_Client) {
	m := &c.sig_help
	if m.state == .Pending && m.request_id >= 0 {
		client_cancel_request(c, m.request_id)
	}
	signature_help_destroy(&m.result)
	m.state      = .Idle
	m.request_id = -1
}

sig_help_get :: proc(c: ^Language_Client) -> (^Signature_Help, bool) {
	m := &c.sig_help
	if m.state == .Ready && len(m.result.signatures) > 0 { return &m.result, true }
	return nil, false
}

_on_sig_help_response :: proc(c: ^Language_Client, result: json.Value, error: json.Value, user: rawptr) {
	defer json.destroy_value(result)
	defer json.destroy_value(error)

	m := &c.sig_help
	m.request_id = -1

	if error != nil || result == nil { m.state = .Idle; return }
	if _, is_null := result.(json.Null); is_null { m.state = .Idle; return }

	obj, is_obj := result.(json.Object)
	if !is_obj { m.state = .Idle; return }

	signature_help_destroy(&m.result)
	m.result = {}

	m.result.active_signature, _ = json_obj_int(obj, "activeSignature")
	m.result.active_parameter, _ = json_obj_int(obj, "activeParameter")

	if sigs_arr, ok := json_obj_arr(obj, "signatures"); ok {
		sigs := make([dynamic]Signature_Info)
		for sig_v in sigs_arr {
			sig_obj, is_sig := sig_v.(json.Object)
			if !is_sig { continue }

			sig: Signature_Info
			if s, ok2 := json_obj_str(sig_obj, "label"); ok2 {
				sig.label = strings.clone(s)
			}
			if ap, ok2 := json_obj_int(sig_obj, "activeParameter"); ok2 {
				sig.active_parameter = ap
			}

			if doc_v, has := sig_obj["documentation"]; has {
				#partial switch v in doc_v {
				case string:      sig.documentation = strings.clone(v)
				case json.Object:
					if val_s, ok2 := json_obj_str(v, "value"); ok2 { sig.documentation = strings.clone(val_s) }
				case:
				}
			}

			// Parameters
			if params_arr, ok2 := json_obj_arr(sig_obj, "parameters"); ok2 {
				params_out := make([dynamic]Parameter_Info)
				for p_v in params_arr {
					p_obj, is_p := p_v.(json.Object)
					if !is_p { continue }
					p: Parameter_Info
					if label_v, has := p_obj["label"]; has {
						#partial switch lv in label_v {
						case string:
							p.label = strings.clone(lv)
						case json.Array:
							if len(lv) >= 2 {
								start, _ := lv[0].(i64)
								end,   _ := lv[1].(i64)
								if int(start) < len(sig.label) && int(end) <= len(sig.label) {
									p.label = strings.clone(sig.label[start:end])
								}
							}
						case: // ignore
						}
					}
					if doc_v2, has := p_obj["documentation"]; has {
						#partial switch v in doc_v2 {
						case string:      p.documentation = strings.clone(v)
						case json.Object:
							if vs, ok3 := json_obj_str(v, "value"); ok3 { p.documentation = strings.clone(vs) }
						case:
						}
					}
					append(&params_out, p)
				}
				sig.parameters = params_out[:]
			}

			append(&sigs, sig)
		}
		m.result.signatures = sigs[:]
	}

	m.state = .Ready
}
