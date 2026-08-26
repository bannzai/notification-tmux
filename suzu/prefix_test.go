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
	}
	for raw, want := range cases {
		if got := normalizePrefix(raw); got != want {
			t.Errorf("normalizePrefix(%q) = %+v, want %+v", raw, got, want)
		}
	}
}
