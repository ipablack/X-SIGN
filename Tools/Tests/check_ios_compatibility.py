"""Catch the reviewed iOS-16+ API regressions before allocating a Mac.

This lexical guard is supplementary; only Xcode can type-check the complete app.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SYMBOLS = {
    r'\bTab\s*\(\s*value\s*:': 18.0,
    r'\bURL\.documentsDirectory\b': 16.0,
    r'\.searchScopes\s*\(': 16.0,
    r'\bUnevenRoundedRectangle\s*\(': 17.0,
    r'\bUIHostingConfiguration\s*\{': 16.0,
    r'\.toolbarTitleMenu\s*(?:\(|\{)': 16.0,
    r'\.autocorrectionDisabled\s*\(': 16.0,
    r'\bButton\s*\([^{}]*?,\s*systemImage\s*:': 17.0,
    r'\bNavigationStack\s*\{': 16.0,
    r'\bContentUnavailableView\s*\{': 17.0,
    r'\bTabViewCustomization\s*\(': 18.0,
    r'\.glassEffect\s*\(': 26.0,
    r'\.tabViewSearchActivation\s*\(': 26.0,
    r'\.translationTask\s*\(': 18.0,
    r'\.translationPresentation\s*\(': 17.4,
    r'\.onScrollGeometryChange\s*\(': 18.0,
    r'\.path\s*\(\s*(?:percentEncoded\s*:|\))': 16.0,
    r'\.onTapGesture(?:\([^{}]*\))?\s*\{\s*[A-Za-z_]\w*\s+in\b': 17.0,
    # A general View.bold() modifier needs iOS 16. Prefer Font.bold() on iOS 15.
    r'(?m)^\s*\.bold\s*\(\s*\)': 16.0,
}


def erase_literals(text):
    # Keep positions and lines intact; patterns are API tokens, not strings/comments.
    pattern = r'//[^\n]*|/\*[\s\S]*?\*/|"""[\s\S]*?"""|"(?:\\.|[^"\\])*"'
    return re.sub(pattern, lambda match: re.sub(r'[^\n]', ' ', match[0]), text)


def violations(text):
    code = erase_literals(text)
    active = [15.0]
    events = []
    boundary = 0
    # A declaration @available or the true arm of if #available protects its body.
    for index, character in enumerate(code):
        if character == '{':
            header = code[boundary:index]
            availability = re.findall(r'(?:#|@)available\s*\(\s*iOS\s+([0-9]+(?:\.[0-9]+)?)', header)
            minimum = max(active[-1], *(float(value) for value in availability)) if availability else active[-1]
            active.append(minimum)
            events.append((index, minimum))
            boundary = index + 1
        elif character == '}':
            if len(active) > 1:
                active.pop()
            events.append((index, active[-1]))
            boundary = index + 1
    problems = []
    for pattern, required in SYMBOLS.items():
        for match in re.finditer(pattern, code):
            # UIHostingConfiguration includes the closure brace; its context starts before it.
            context = 15.0
            for index, minimum in events:
                if index >= match.start():
                    break
                context = minimum
            if context < required:
                line = code.count('\n', 0, match.start()) + 1
                problems.append((line, match[0].strip(), required))
    # Conditionals directly in ToolbarContentBuilder use buildIf/buildEither (iOS 16).
    # Conditions INSIDE ToolbarItem/ToolbarItemGroup use ViewBuilder and work on 15.
    stack = []
    boundary = 0
    for match in re.finditer(r'[{}]|\b(?:if|switch)\b', code):
        token = match[0]
        if token == '{':
            header = code[boundary:match.start()]
            inherited = stack[-1][1] if stack else 15.0
            availability = re.findall(r'(?:#|@)available\s*\(\s*iOS\s+([0-9]+(?:\.[0-9]+)?)', header)
            minimum = max([inherited] + [float(value) for value in availability])
            toolbar = bool(re.search(r'\.toolbar\s*(?:\([^{}]*\))?\s*$|some\s+ToolbarContent\s*$|@ToolbarContentBuilder', header))
            stack.append((toolbar, minimum))
            boundary = match.end()
        elif token == '}':
            if stack: stack.pop()
            boundary = match.end()
        elif stack and stack[-1][0] and stack[-1][1] < 16.0:
            problems.append((code.count('\n', 0, match.start()) + 1,
                             'conditional ToolbarContentBuilder; put the condition inside ToolbarItem', 16.0))
    return problems


class GuardChecks(unittest.TestCase):
    def test_rejects_unprotected_and_else_branches(self):
        self.assertTrue(violations('func f() { URL.documentsDirectory }'))
        self.assertTrue(violations('func f() { if #available(iOS 16, *) { self } else { self.searchScopes(x) } }'))

    def test_accepts_runtime_and_declaration_guards_and_ignores_examples(self):
        self.assertEqual(violations('func f() { if #available(iOS 17, *) { UIHostingConfiguration { self } } }'), [])
        self.assertEqual(violations('@available(iOS 18, *) struct V { var body: some View { NavigationStack { self } } }'), [])
        self.assertEqual(violations('// URL.documentsDirectory\nlet help = "UIHostingConfiguration {"'), [])

    def test_latest_native_run_regressions_are_detected(self):
        for source in [
            'func f() { tmpDirectory.path() }',
            'struct V { var body: some View { self.onTapGesture { point in go() } } }',
            'struct V { var body: some View { Text(title).frame(maxWidth: .infinity)\n.bold() } }',
            'func f() { self.toolbar { if showing { NBToolbarButton() } } }',
            'func f() { self.toolbar { if showing { ToolbarItem {} } else { ToolbarItem {} } } }',
        ]:
            self.assertTrue(violations(source), source)

    def test_ios15_toolbar_item_conditions_stay_supported(self):
        self.assertEqual(violations('func f() { self.toolbar { ToolbarItem { if showing { Button() } else { ProgressView() } } } }'), [])
        self.assertEqual(violations('func f() { if #available(iOS 16, *) { self.toolbar { if showing { ToolbarItem {} } } } }'), [])

    def test_project_apis_keep_ios15_fallbacks(self):
        errors = []
        for directory in ['Feather', 'NimbleKit/Sources']:
            for file in (ROOT / directory).rglob('*.swift'):
                errors += [f'{file.relative_to(ROOT)}:{line}: iOS {minimum}+ API {symbol}'
                           for line, symbol, minimum in violations(file.read_text())]
        self.assertEqual(errors, [], '\n'.join(errors))


if __name__ == '__main__':
    unittest.main()
