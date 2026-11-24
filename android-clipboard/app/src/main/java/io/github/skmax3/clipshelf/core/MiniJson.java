package io.github.skmax3.clipshelf.core;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** 小さな JSON の読み書き（外部のライブラリを使わず、Java だけで試せるようにするため）。 */
public final class MiniJson {
    private final String s;
    private int i;

    private MiniJson(String s) {
        this.s = s;
    }

    /** JSON を読む。結果は Map / List / String / Double / Boolean / null。壊れていたら IllegalArgumentException */
    public static Object parse(String text) {
        MiniJson p = new MiniJson(text);
        p.skip();
        Object v = p.value();
        p.skip();
        if (p.i != p.s.length()) throw new IllegalArgumentException("JSON の後ろに余計な文字があります");
        return v;
    }

    @SuppressWarnings("unchecked")
    public static Map<String, Object> parseObject(String text) {
        Object v = parse(text);
        if (!(v instanceof Map)) throw new IllegalArgumentException("JSON のオブジェクトではありません");
        return (Map<String, Object>) v;
    }

    /** 文字列を JSON の文字列（引用符つき）にする */
    public static String quote(String text) {
        StringBuilder b = new StringBuilder("\"");
        for (int k = 0; k < text.length(); k++) {
            char c = text.charAt(k);
            switch (c) {
                case '"': b.append("\\\""); break;
                case '\\': b.append("\\\\"); break;
                case '\n': b.append("\\n"); break;
                case '\r': b.append("\\r"); break;
                case '\t': b.append("\\t"); break;
                default:
                    if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
                    else b.append(c);
            }
        }
        return b.append('"').toString();
    }

    private void skip() {
        while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++;
    }

    private Object value() {
        if (i >= s.length()) throw new IllegalArgumentException("JSON が途中で終わっています");
        char c = s.charAt(i);
        if (c == '{') return object();
        if (c == '[') return array();
        if (c == '"') return string();
        if (s.startsWith("true", i)) { i += 4; return Boolean.TRUE; }
        if (s.startsWith("false", i)) { i += 5; return Boolean.FALSE; }
        if (s.startsWith("null", i)) { i += 4; return null; }
        int start = i;
        while (i < s.length() && "+-0123456789.eE".indexOf(s.charAt(i)) >= 0) i++;
        if (start == i) throw new IllegalArgumentException("JSON を読めません（位置 " + i + "）");
        return Double.valueOf(s.substring(start, i));
    }

    private Map<String, Object> object() {
        Map<String, Object> map = new LinkedHashMap<>();
        i++;
        skip();
        if (i < s.length() && s.charAt(i) == '}') { i++; return map; }
        while (true) {
            skip();
            String key = string();
            skip();
            if (i >= s.length() || s.charAt(i) != ':') throw new IllegalArgumentException("':' がありません");
            i++;
            skip();
            map.put(key, value());
            skip();
            if (i < s.length() && s.charAt(i) == ',') { i++; continue; }
            if (i < s.length() && s.charAt(i) == '}') { i++; return map; }
            throw new IllegalArgumentException("JSON のオブジェクトが閉じていません");
        }
    }

    private List<Object> array() {
        List<Object> list = new ArrayList<>();
        i++;
        skip();
        if (i < s.length() && s.charAt(i) == ']') { i++; return list; }
        while (true) {
            skip();
            list.add(value());
            skip();
            if (i < s.length() && s.charAt(i) == ',') { i++; continue; }
            if (i < s.length() && s.charAt(i) == ']') { i++; return list; }
            throw new IllegalArgumentException("JSON の配列が閉じていません");
        }
    }

    private String string() {
        if (i >= s.length() || s.charAt(i) != '"') throw new IllegalArgumentException("文字列の始まりがありません");
        i++;
        StringBuilder b = new StringBuilder();
        while (i < s.length()) {
            char c = s.charAt(i++);
            if (c == '"') return b.toString();
            if (c != '\\') { b.append(c); continue; }
            if (i >= s.length()) break;
            char e = s.charAt(i++);
            switch (e) {
                case 'n': b.append('\n'); break;
                case 'r': b.append('\r'); break;
                case 't': b.append('\t'); break;
                case 'b': b.append('\b'); break;
                case 'f': b.append('\f'); break;
                case 'u':
                    if (i + 4 > s.length()) throw new IllegalArgumentException("\\u の後ろが足りません");
                    b.append((char) Integer.parseInt(s.substring(i, i + 4), 16));
                    i += 4;
                    break;
                default: b.append(e);  // " \ /
            }
        }
        throw new IllegalArgumentException("文字列が閉じていません");
    }
}
