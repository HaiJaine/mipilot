#!/usr/bin/env python3

import argparse
import itertools

import pexpect


def expect_send(child, pattern, value, timeout=180):
    child.expect(pattern, timeout=timeout)
    child.sendline(value)


def finish_menu(child):
    expect_send(child, "策略组管理", "0")
    expect_send(child, "MiPilot 代理管理器", "0")
    child.expect(pexpect.EOF)
    child.close()
    if child.exitstatus != 0:
        raise RuntimeError(f"menu exited with {child.exitstatus}")


def open_create(command):
    child = pexpect.spawn(command, encoding="utf-8", timeout=180)
    expect_send(child, "请选择编号后按 Enter", "4")
    expect_send(child, "策略组管理", "2")
    child.expect("输入地区编号")
    return child


def run_valid_case(command, selection, name, strategy, should_create):
    child = open_create(command)
    child.sendline(selection)
    expect_send(child, "自定义策略组名称", name)
    expect_send(child, "选择策略类型", str(strategy))
    if not should_create:
        child.expect("当前订阅没有匹配到所选地区的实际节点")
        expect_send(child, "按 Enter 或 Esc 返回菜单", "")
        finish_menu(child)
        return

    expect_send(child, "确认创建策略组", "y")
    child.expect("自定义策略组已创建")
    expect_send(child, "按 Enter 或 Esc 返回菜单", "")
    expect_send(child, "策略组管理", "5")
    expect_send(child, "选择要删除的 MiPilot 策略组", "1")
    expect_send(child, "确认删除策略组", "y")
    child.expect("策略组已删除")
    expect_send(child, "按 Enter 或 Esc 返回菜单", "")
    finish_menu(child)


def run_invalid_case(command, selection, expected):
    child = open_create(command)
    child.sendline(selection)
    child.expect(expected)
    expect_send(child, "按 Enter 或 Esc 返回菜单", "")
    finish_menu(child)


def main():
    parser = argparse.ArgumentParser(description="Exercise MiPilot region combinations through its PTY menu")
    parser.add_argument("--command", default="/usr/local/bin/mipilot")
    parser.add_argument("--supported", required=True, help="Comma-separated one-based regions with nodes")
    parser.add_argument("--start", type=int, default=1, help="One-based valid case to start from")
    options = parser.parse_args()
    supported = {int(value) for value in options.supported.split(",") if value}

    cases = [(str(index), (index,)) for index in range(1, 15)]
    cases.extend((f"{left},{right}", (left, right)) for left, right in itertools.combinations(range(1, 15), 2))
    cases.append((",".join(str(index) for index in range(1, 15)), tuple(range(1, 15))))
    cases.extend(
        [
            (" 3 , 4 ", (3, 4)),
            ("3，4", (3, 4)),
            ("4,3", (4, 3)),
            ("3,3,4", (3, 4)),
        ]
    )

    for number, (selection, regions) in enumerate(cases, start=1):
        if number < options.start:
            continue
        should_create = bool(supported.intersection(regions))
        run_valid_case(options.command, selection, f"矩阵-{number:03d}", ((number - 1) % 4) + 1, should_create)
        print(f"[PASS] region case {number}/{len(cases)}")

    invalid_cases = [
        ("0", "地区编号无效"),
        ("15", "地区编号无效"),
        ("abc", "地区编号格式无效"),
        ("3;4", "地区编号格式无效"),
        (",3", "地区编号格式无效"),
        ("3,", "地区编号格式无效"),
        ("3,,4", "地区编号格式无效"),
        ("1234567890", "地区编号格式无效"),
    ]
    for number, (selection, expected) in enumerate(invalid_cases, start=1):
        run_invalid_case(options.command, selection, expected)
        print(f"[PASS] invalid region case {number}/{len(invalid_cases)}")


if __name__ == "__main__":
    main()
