package main

import "testing"

func TestNormalizePrefix(t *testing.T) {
	cases := map[string]prefixKey{
		"C-t":   {Display: "C-t", Key: "ctrl+t"},
		"C-b":   {Display: "C-b", Key: "ctrl+b"},
		"C-A":   {Display: "C-A", Key: "ctrl+a"},
		"M-x":   {Display: "M-x", Key: "alt+x"},
		"C-":    {Display: "C-b", Key: "ctrl+b"},
		"None":  {Display: "C-b", Key: "ctrl+b"},
		"F1":    {Display: "C-b", Key: "ctrl+b"},
		"":      {Display: "C-b", Key: "ctrl+b"},
		"C-Foo": {Display: "C-b", Key: "ctrl+b"},
		// 修飾なしの単一 rune の prefix はそのまま使える (C-b へ落とさない)
		"a": {Display: "a", Key: "a"},
		"N": {Display: "N", Key: "N"},
	}
	for raw, want := range cases {
		if got := normalizePrefix(raw); got != want {
			t.Errorf("normalizePrefix(%q) = %+v, want %+v", raw, got, want)
		}
	}
}

func TestNormalizeKey(t *testing.T) {
	cases := map[string]string{
		"C-n": "ctrl+n",
		"C-N": "ctrl+n",
		"M-x": "alt+x",
		"N":   "N",
		"b":   "b",
		// 写せない表記は元のまま。従来どおり生の文字列比較に委ねる
		"F1":   "F1",
		"None": "None",
		"":     "",
	}
	for raw, want := range cases {
		if got := normalizeKey(raw); got != want {
			t.Errorf("normalizeKey(%q) = %q, want %q", raw, got, want)
		}
	}
}
