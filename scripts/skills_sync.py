"""Compare two skill folders and update a selected skill over SSH."""

import argparse
import difflib
import itertools
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tarfile

sys.dont_write_bytecode = True
import skill_files


def remote(host, action, *args, data=None, timeout=45):
    program = Path(skill_files.__file__).read_text(encoding="utf-8")
    command = "python3 -c " + " ".join(shlex.quote(arg) for arg in (program, action, *args))
    result = subprocess.run(
        ["/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
         "-o", "ClearAllForwardings=yes", "--", host, command],
        input=data if data is not None else b"", capture_output=True, timeout=timeout,
    )
    if result.returncode:
        detail = result.stderr.decode(errors="replace").strip() or f"退出状态 {result.returncode}"
        raise ValueError(f"服务器操作失败：{detail}")
    return result.stdout


def compare(host, local_root, remote_root):
    local = skill_files.inventory(local_root)
    server = json.loads(remote(host, "inventory", remote_root))
    rows = []
    for name in sorted(local.keys() | server.keys(), key=lambda value: (value.casefold(), value)):
        left, right = local.get(name), server.get(name)
        left_files = left.pop("files", {}) if left else {}
        right_files = right.pop("files", {}) if right else {}
        changes = []
        if not any(side and "error" in side for side in (left, right)):
            ordered = sorted(left_files.keys() | right_files.keys(), key=lambda path: (path != "SKILL.md", path))
            for path in ordered:
                if left_files.get(path) == right_files.get(path):
                    continue
                if path not in right_files:
                    status = "localOnly"
                elif path not in left_files:
                    status = "remoteOnly"
                else:
                    status = "different"
                changes.append({"path": path, "status": status})
        rows.append({"name": name, "local": left, "remote": right, "changes": changes})
    return {"localCount": len(local), "remoteCount": len(server), "skills": rows}


def preview(host, local_root, remote_root, name, path, status):
    left = skill_files.read_preview(local_root, name, path) if status != "remoteOnly" else None
    right = json.loads(remote(host, "preview", remote_root, name, path)) if status != "localOnly" else None
    if (status != "remoteOnly" and left is None) or (status != "localOnly" and right is None):
        return {"text": "文件已变化，请刷新对比。"}
    problems = [f"{side}：{value['reason']}" for side, value in (("本机", left), ("服务器", right))
                if value and "reason" in value]
    if problems:
        return {"text": "\n".join(problems)}

    def lines(value):
        return value["text"].splitlines(keepends=True) if value else []

    diff = difflib.unified_diff(
        lines(right), lines(left),
        fromfile=f"服务器/{path}" if right else "服务器/缺少此文件",
        tofile=f"本机/{path}" if left else "本机/缺少此文件",
    )
    output = [line if line.endswith("\n") else line + "\n\\ 文件末尾无换行\n"
              for line in itertools.islice(diff, 1601)]
    if len(output) > 1600:
        output[-1] = "\n差异较长，已显示前 1,600 行。"
    if left and right and left["executable"] != right["executable"]:
        flag = "本机" if left["executable"] else "服务器"
        output.insert(0, f"仅{flag}文件有执行权限。\n\n")
    if not output:
        output = ["只有一端包含这个空文件。" if bool(left) != bool(right) else "文件已变化，请刷新对比。"]
    return {"text": "".join(output)}


def update(host, local_root, remote_root, name, local_revision, remote_revision):
    packed = skill_files.export_skill(local_root, name, local_revision)
    return json.loads(remote(host, "install", remote_root, name, remote_revision, local_revision,
                             data=packed, timeout=120))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--local", required=True)
    parser.add_argument("--remote", required=True)
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("compare")
    diff = commands.add_parser("preview")
    diff.add_argument("name")
    diff.add_argument("file")
    diff.add_argument("status", choices=("localOnly", "remoteOnly", "different"))
    transfer = commands.add_parser("update")
    transfer.add_argument("name")
    transfer.add_argument("local_revision")
    transfer.add_argument("remote_revision")
    args = parser.parse_args()
    args_common = args.host, args.local, args.remote
    try:
        if args.action == "compare":
            result = compare(*args_common)
        elif args.action == "preview":
            result = preview(*args_common, args.name, args.file, args.status)
        else:
            result = update(*args_common, args.name, args.local_revision, args.remote_revision)
        print(json.dumps(result))
    except subprocess.TimeoutExpired:
        sys.exit("等待服务器响应超时，请刷新对比后重试。")
    except (OSError, RuntimeError, ValueError, tarfile.TarError) as exc:
        sys.exit(str(exc))


if __name__ == "__main__":
    main()
