#!/usr/bin/env python3
"""Fails when a SwiftUI control would be silent for VoiceOver:
- a Button whose label is only an Image, without .accessibilityLabel(...) right after it;
- Toggle / Picker / TextField with an empty title ("" — use a real title with .labelsHidden())."""
import pathlib, re, sys

problems = []
for path in sorted(pathlib.Path("Sources/KongPrism").rglob("*.swift")):
    lines = path.read_text(encoding="utf-8").split("\n")
    for i, line in enumerate(lines):
        if re.search(r'\b(Toggle|Picker|TextField|SecureField)\(""', line):
            problems.append(f"{path}:{i+1}: 空标题的 {line.strip()[:60]}")
        if "label: {" in line:
            window = "\n".join(lines[i:i + 3])
            label = window[window.index("label: {"):]
            label = label[:label.find("}") + 1] if "}" in label else label
            if "Image(" in label and "Text(" not in label and "Label(" not in label:
                after = "\n".join(lines[i:i + 7])
                if ".accessibilityLabel(" not in after:
                    problems.append(f"{path}:{i+1}: 只有图标的按钮缺少 .accessibilityLabel")
for problem in problems:
    print(problem)
print(f"无障碍检查：{len(problems)} 个问题")
sys.exit(1 if problems else 0)
