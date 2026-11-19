// Minimal stand-in for nomad-pack's renderer, used only by the tests:
// Go text/template with [[ ]] delimiters and the pack functions this pack uses
// (var, meta, quote, toJson, list, fileContents, fail).
//
//	go run ./test/render <pack_dir> <vars.json> <out_dir>
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"text/template"
)

type ctx struct {
	Vars     map[string]interface{}
	PackPath string
}

func main() {
	packDir, varsFile, outDir := os.Args[1], os.Args[2], os.Args[3]
	raw, err := os.ReadFile(varsFile)
	must(err)
	vars := map[string]interface{}{}
	must(json.Unmarshal(raw, &vars))
	abs, _ := filepath.Abs(packDir)
	c := &ctx{Vars: vars, PackPath: abs}

	funcs := template.FuncMap{
		"var": func(name string, c *ctx) (interface{}, error) {
			v, ok := c.Vars[name]
			if !ok {
				return nil, fmt.Errorf("variable %q not declared", name)
			}
			return v, nil
		},
		"meta": func(name string, c *ctx) (string, error) {
			switch name {
			case "pack.path":
				return c.PackPath, nil
			case "pack.name":
				return "doris", nil
			}
			return "", fmt.Errorf("unknown meta %q", name)
		},
		"quote": func(v interface{}) string { return strconv.Quote(fmt.Sprint(v)) },
		"toJson": func(v interface{}) (string, error) {
			b, err := json.Marshal(v)
			return string(b), err
		},
		"list": func(v ...interface{}) []interface{} { return v },
		"fileContents": func(p string) (string, error) {
			b, err := os.ReadFile(p)
			return strings.TrimRight(string(b), "\n"), err
		},
		"fail": func(msg string) (string, error) { return "", fmt.Errorf("%s", msg) },
	}

	files, _ := filepath.Glob(filepath.Join(packDir, "templates", "*.tpl"))
	t := template.New("pack").Delims("[[", "]]").Funcs(funcs).Option("missingkey=error")
	for _, f := range files {
		b, err := os.ReadFile(f)
		must(err)
		_, err = t.New(filepath.Base(f)).Parse(string(b))
		must(err)
	}
	must(os.MkdirAll(outDir, 0o755))
	for _, f := range files {
		base := filepath.Base(f)
		if strings.HasPrefix(base, "_") || !strings.HasSuffix(base, ".nomad.tpl") {
			continue
		}
		var sb strings.Builder
		if err := t.ExecuteTemplate(&sb, base, c); err != nil {
			fmt.Fprintln(os.Stderr, "render error:", err)
			os.Exit(2)
		}
		out := sb.String()
		if strings.TrimSpace(out) == "" { // nomad-pack skips empty templates
			continue
		}
		must(os.WriteFile(filepath.Join(outDir, strings.TrimSuffix(base, ".tpl")), []byte(out+"\n"), 0o644))
	}
}

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
