"""城市巡查 AI 助手的桌面界面。"""

import tkinter as tk
from tkinter import ttk

from inspection import classify_issue


def analyze_issue():
    """读取输入内容并把分类结果显示在界面上。"""
    result = classify_issue(issue_input.get())
    issue_type.set(result["问题类型"])
    department.set(result["处理部门"])
    priority.set(result["优先级"])


def clear_issue():
    """清空输入和识别结果。"""
    issue_input.delete(0, "end")
    issue_type.set("等待识别")
    department.set("等待识别")
    priority.set("等待识别")
    issue_input.focus_set()


root = tk.Tk()
root.title("城市巡查 AI 助手")
root.geometry("560x420")
root.minsize(520, 380)

main = ttk.Frame(root, padding=24)
main.pack(fill="both", expand=True)

ttk.Label(main, text="城市巡查 AI 助手", font=("Arial", 22, "bold")).pack(
    anchor="w", pady=(0, 8)
)
ttk.Label(main, text="输入巡查现场发现的问题，系统将给出处置建议。", foreground="#555555").pack(
    anchor="w", pady=(0, 16)
)

input_box = ttk.LabelFrame(main, text="在这里输入巡查问题", padding=14)
input_box.pack(fill="x")

issue_input = tk.Entry(
    input_box,
    font=("Arial", 15),
    bg="white",
    fg="black",
    relief="solid",
    bd=2,
    highlightthickness=2,
    highlightbackground="#2979ff",
    highlightcolor="#2979ff",
)
issue_input.pack(fill="x", ipady=10)
issue_input.insert(0, "发现道路井盖缺失")
issue_input.bind("<Return>", lambda _event: analyze_issue())

button_bar = ttk.Frame(main)
button_bar.pack(fill="x", pady=16)
ttk.Button(button_bar, text="开始识别", command=analyze_issue).pack(side="left")
ttk.Button(button_bar, text="清空输入", command=clear_issue).pack(side="left", padx=10)

result_box = ttk.LabelFrame(main, text="识别结果", padding=16)
result_box.pack(fill="both", expand=True)

issue_type = tk.StringVar(value="等待识别")
department = tk.StringVar(value="等待识别")
priority = tk.StringVar(value="等待识别")

for row, (label, variable) in enumerate(
    [("问题类型", issue_type), ("处理部门", department), ("优先级", priority)]
):
    ttk.Label(result_box, text=f"{label}：", font=("Arial", 13, "bold")).grid(
        row=row, column=0, sticky="w", padx=(0, 12), pady=7
    )
    ttk.Label(result_box, textvariable=variable, font=("Arial", 13)).grid(
        row=row, column=1, sticky="w", pady=7
    )

issue_input.focus_set()
issue_input.selection_range(0, "end")
root.mainloop()
