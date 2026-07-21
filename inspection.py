def classify_issue(description):
    """根据巡查问题描述，给出初步分类和处置建议。"""

    description = description.strip()

    if not description:
        return {
            "问题类型": "无法识别",
            "处理部门": "待人工确认",
            "优先级": "待确认"
        }

    if any(word in description for word in ["垃圾", "落叶", "污水", "保洁"]):
        return {
            "问题类型": "环境卫生",
            "处理部门": "环卫部门",
            "优先级": "一般"
        }

    if any(word in description for word in ["井盖", "路灯", "护栏", "道路破损"]):
        return {
            "问题类型": "市政设施",
            "处理部门": "市政管理部门",
            "优先级": "较高"
        }

    if any(word in description for word in ["树木倒伏", "树枝断裂", "绿化带"]):
        return {
            "问题类型": "园林绿化",
            "处理部门": "园林部门",
            "优先级": "较高"
        }

    return {
        "问题类型": "其他问题",
        "处理部门": "城市管理部门",
        "优先级": "一般"
    }


if __name__ == "__main__":
    issue = input("请输入巡查发现的问题：")
    result = classify_issue(issue)

    print("\n识别结果：")
    for key, value in result.items():
        print(f"{key}：{value}")
