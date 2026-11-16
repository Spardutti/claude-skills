import { existsSync, readFileSync } from "node:fs";
import { basename, dirname, resolve } from "node:path";

const JS_TEST = "\\.(test|spec)\\.[cm]?[jt]sx?$";
const PY_TEST = "(^|/)(test_[^/]*|[^/]*_test)\\.py$";
const IS_TEST = new RegExp(`${JS_TEST}|${PY_TEST}`);

// Assertions that pass while the value is wrong: the mutants they let live are the gate's most common finding.
export const WEAK_ASSERTS = [
  {
    id: "weak-assert-js",
    files: JS_TEST,
    // A Testing Library query already names the exact text or role, so its presence check is exact.
    pattern: "^(?!.*\\b(get|find|query)(All)?By\\w*\\().*(\\.(toBeDefined|toBeTruthy|toBeFalsy)\\(\\)|\\.not\\.(toBeNull|toBeUndefined)\\(\\)|\\.length\\)\\.toBeGreaterThan\\(0\\))",
    flags: "m",
    message: "assert the exact value (toBe, toEqual), not that something exists",
    bad: "expect(user).toBeDefined()",
    good: "expect(user).toEqual({ id: 1, name: 'Ana' })",
  },
  {
    id: "weak-assert-py",
    files: PY_TEST,
    pattern: "^\\s*assert .+ is not None\\s*$|^\\s*assert [\\w.\\[\\]'\"]+\\s*$|^\\s*assert len\\(.+\\) (> 0|>= 1)\\s*$",
    flags: "m",
    message: "assert the exact value (==), not that something exists",
    bad: "    assert user is not None",
    good: "    assert user == {'id': 1, 'name': 'Ana'}",
  },
].map((r) => ({ ...r, applies: (f) => new RegExp(r.files).test(f) }));

const NEEDS = [
  [/\border_?by\b|\.sort\(|\bsorted\(|\bORDER BY\b/i, "two rows tied on the sort key, so a dropped tiebreak fails"],
  [/\.limit\(|\bLIMIT\b|\.take\(|\[:\s*\w+\]|\.slice\(0,/, "more rows than the limit, so a dropped limit fails"],
  [/\.where\(|\bWHERE\b|\.filter\(|\bfilter_by\(|\bi?like\(|\.exclude\(/i, "a row that must not match, so a dropped filter fails"],
  [/\s(<|>|<=|>=)\s/, "both sides of each comparison: exactly at the boundary and one past it", true],
  [/&&|\|\||\s(and|or)\s/, "each side of every && / || on its own: one case where only one side is true", true],
  [/\?\?|\?\.|\.get\(\s*['"][^'"]+['"]\s*,/, "a missing value, so the default or fallback shows"],
  [/throw new \w*Error\(|\braise \w+\(|HTTPException\(/, "the exact error message or status, not only that it failed"],
];

const CODE = /\.([cm]?[jt]sx?|astro|py)$/;
const stemOf = (rel) => basename(rel).replace(/\.(test|spec)(?=\.)/, "").replace(/^test_|_test(?=\.py$)/, "").replace(CODE, "");

export function subjectOf(rel, files) {
  const stem = stemOf(rel);
  const py = rel.endsWith(".py");
  const named = files.filter((f) => CODE.test(f) && f.endsWith(".py") === py && !IS_TEST.test(f) && basename(f).replace(CODE, "") === stem);
  const shared = (f) => f.split("/").filter((part, i) => part === rel.split("/")[i]).length;
  const near = dirname(rel).replace(/\/__tests__$/, "");
  return named.find((f) => dirname(f) === near) ?? named.sort((a, b) => shared(b) - shared(a))[0] ?? null;
}

// Comments and docstrings are prose: an "or" there is no branch to test.
function codeLines(text) {
  let doc = false;
  return text.split("\n").map((line) => {
    const quotes = (line.match(/"""|'''/g) ?? []).length;
    const prose = doc || quotes > 0 || /^\s*(#|\/\/|\/?\*)/.test(line);
    if (quotes % 2) doc = !doc;
    return prose ? "" : line;
  });
}

export function checklist(root, rel, files) {
  if (!IS_TEST.test(rel)) return [];
  const subject = subjectOf(rel, files);
  if (!subject || !existsSync(resolve(root, subject))) return [];
  const lines = codeLines(readFileSync(resolve(root, subject), "utf8"));
  const unquoted = lines.map((l) => l.replace(/(["'`])(?:\\.|(?!\1).)*\1/g, '""'));
  const found = NEEDS.flatMap(([re, need, codeOnly]) => {
    const at = (codeOnly ? unquoted : lines).flatMap((l, i) => (re.test(l) ? [i + 1] : [])).slice(0, 3);
    return at.length ? [`  - ${need} (${subject}:${at.join(",")})`] : [];
  });
  return found.length ? [`TESTS — ${subject} needs a test for each of these, or the mutation gate will find the gap:`, ...found] : [];
}
