package server

import "testing"

// TestDisambiguatePromoNames 同域同名的优惠模型补标签，其余一个不动（issue #286：
// hy4flash 与 hy4flash-free 都叫「Hy4 flash」，一个 x0.03 一个 0 分）。
func TestDisambiguatePromoNames(t *testing.T) {
	list := []map[string]any{
		{"id": "cn:hy4flash-free", "name": "Hy4 flash", "promo_label": "限时免费"},
		{"id": "cn:hy4flash", "name": "Hy4 flash"},
		{"id": "cn:glm-5.2", "name": "GLM-5.2", "promo_label": "夜间折扣"},                 // 同域无重名：不动
		{"id": "global:hy4flash-free", "name": "Hy4 flash", "promo_label": "Free now"}, // 跨域同名：不动
	}
	disambiguatePromoNames(list)
	if got := list[0]["name"]; got != "Hy4 flash（限时免费）" {
		t.Fatalf("免费版应带上标签以便区分，got %v", got)
	}
	if got := list[1]["name"]; got != "Hy4 flash" {
		t.Fatalf("付费版不该被改名，got %v", got)
	}
	if got := list[2]["name"]; got != "GLM-5.2" {
		t.Fatalf("无同名兄弟时不该改名，got %v", got)
	}
	if got := list[3]["name"]; got != "Hy4 flash" {
		t.Fatalf("跨域同名不该改名，got %v", got)
	}
}

func TestDisambiguatePromoNamesSameLabel(t *testing.T) {
	list := []map[string]any{
		{"id": "cn:model-a", "name": "Model", "promo_label": "限时免费"},
		{"id": "cn:model-b", "name": "Model", "promo_label": "限时免费"},
	}
	disambiguatePromoNames(list)
	if list[0]["name"] == list[1]["name"] {
		t.Fatalf("同名同标签的两个模型仍无法区分：%v", list)
	}
}
