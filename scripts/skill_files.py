"""Inspect and transfer one skill on either side of an SSH connection."""

import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tarfile
import tempfile
import time


IGNORED = {".DS_Store", ".git", ".cache", "node_modules", "__pycache__"}
PREVIEW_LIMIT = 192 * 1024


def skill_path(root, name):
    if not name or name.startswith(".") or "/" in name or name in IGNORED:
        raise ValueError("无效的 Skill 目录名")
    return Path(root).expanduser() / name


def file_parts(relative):
    parts = relative.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        raise ValueError("无效的 Skill 文件路径")
    return parts


def skill_files(folder):
    root = folder.resolve(strict=True)

    def walk(directory, prefix, ancestors):
        for child in sorted(directory.iterdir()):
            if child.name in IGNORED or child.name.startswith("._"):
                continue
            relative = prefix + child.name
            path = child.resolve(strict=True) if child.is_symlink() else child
            if path != root and root not in path.parents:
                raise ValueError(f"{folder.name}/{relative} 链接到了技能目录之外")
            mode = path.stat().st_mode
            if stat.S_ISDIR(mode):
                if path in ancestors:
                    raise ValueError(f"{folder.name}/{relative} 存在循环链接")
                yield from walk(path, relative + "/", ancestors | {path})
            elif stat.S_ISREG(mode):
                yield relative, path, mode
            else:
                raise ValueError(f"{folder.name}/{relative} 不是普通文件或目录")

    yield from walk(root, "", {root})


def version_of(folder, files):
    if "_meta.json" in files:
        try:
            with (folder / "_meta.json").open("rb") as source:
                value = json.loads(source.read(16 * 1024))
            version = value.get("version") if isinstance(value, dict) else None
            if isinstance(version, str) and version.strip():
                return version.strip()
        except (UnicodeError, ValueError):
            pass
    with (folder / "SKILL.md").open("rb") as source:
        lines = source.read(16 * 1024).decode("utf-8-sig", errors="replace").splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    metadata = False
    for line in lines[1:]:
        if line.strip() in {"---", "..."}:
            break
        if line.strip() and not line.lstrip().startswith("#") and not line[0].isspace():
            metadata = bool(re.fullmatch(r"metadata:\s*(?:#.*)?", line))
        match = re.fullmatch(r"(\s*)version:\s*(.+?)\s*", line)
        if match and (not match[1] or metadata):
            return match[2].split(" #", 1)[0].strip().strip("\"'") or None
    return None


def describe(folder, entries=None):
    files = {}
    if entries is None:
        entries = skill_files(folder)
    for name, path, mode in entries:
        digest = hashlib.sha256()
        with path.open("rb") as file:
            for block in iter(lambda: file.read(128 * 1024), b""):
                digest.update(block)
        files[name] = [digest.hexdigest(), bool(mode & 0o111)]
    if "SKILL.md" not in files:
        raise ValueError(f"{folder.name} 缺少 SKILL.md")
    revision = hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()
    return {"revision": revision, "version": version_of(folder, files), "files": files}


def inventory(root):
    root = Path(root).expanduser()
    try:
        children = sorted(root.iterdir())
    except FileNotFoundError:
        return {}
    result = {}
    for folder in children:
        if folder.name.startswith(".") or folder.name in IGNORED or not (folder / "SKILL.md").is_file():
            continue
        try:
            result[folder.name] = describe(folder)
        except (OSError, RuntimeError, ValueError) as exc:
            result[folder.name] = {"error": str(exc)}
    return result


def read_preview(root, name, relative):
    folder = skill_path(root, name)
    base = folder.resolve()
    path = base.joinpath(*file_parts(relative)).resolve()
    if base not in path.parents:
        raise ValueError("文件链接到了技能目录之外")
    try:
        mode = path.stat().st_mode
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(mode):
        raise ValueError("文件类型已变更，请刷新对比")
    with path.open("rb") as file:
        data = file.read(PREVIEW_LIMIT + 1)
    if len(data) > PREVIEW_LIMIT:
        return {"reason": "文件过大"}
    try:
        if b"\0" not in data:
            return {"text": data.decode("utf-8"), "executable": bool(mode & 0o111)}
    except UnicodeDecodeError:
        pass
    return {"reason": "文件为二进制或非 UTF-8 文本"}


def export_skill(root, name, expected):
    folder = skill_path(root, name)
    entries = list(skill_files(folder))
    if describe(folder, entries)["revision"] != expected:
        raise ValueError("来源技能已变化，请刷新对比后重试")
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz", dereference=True) as archive:
        for relative, path, _ in entries:
            archive.add(path, arcname=relative, recursive=False)
    return buffer.getvalue()


def unpack_skill(payload, folder):
    with tarfile.open(fileobj=payload, mode="r|gz") as archive:
        for member in archive:
            if not member.isreg():
                raise ValueError("技能包包含不支持的文件类型")
            target = folder.joinpath(*file_parts(member.name))
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(member) as source, target.open("xb") as output:
                shutil.copyfileobj(source, output)
            target.chmod(member.mode & 0o777)


def verify_target(folder, expected):
    if not os.path.lexists(folder):
        if expected == "-":
            return False
    elif expected != "-" and (folder / "SKILL.md").is_file():
        if describe(folder)["revision"] == expected:
            return True
    raise ValueError("目标已变化，或同名目录不是 Skill。请刷新对比后重试")


def install_skill(root, name, expected, incoming, payload):
    destination = skill_path(Path(root).expanduser().resolve(), name)
    had_target = verify_target(destination, expected)
    cache = destination.parent / ".cache" / "ferret-skill-updates"
    cache.mkdir(mode=0o700, parents=True, exist_ok=True)
    backup = None
    with tempfile.TemporaryDirectory(prefix="stage-", dir=cache) as work:
        staged = Path(work) / "skill"
        staged.mkdir()
        unpack_skill(payload, staged)
        if describe(staged)["revision"] != incoming:
            raise ValueError("收到的文件和对比结果不同，请刷新对比后重试")

        with (cache / "lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            verify_target(destination, expected)
            # 备份目录入口本身，保留符号链接的指向。
            if had_target:
                staged.chmod(stat.S_IMODE(destination.stat().st_mode))
                saved = Path(tempfile.mkdtemp(prefix=time.strftime("backup-%Y%m%d-%H%M%S-"), dir=cache))
                backup = saved / name
                destination.rename(backup)
            try:
                staged.rename(destination)
            except OSError:
                if backup is not None:
                    backup.rename(destination)
                raise
    return {"backup": str(backup) if backup else None}


def main(argv):
    action, *args = argv
    try:
        if action == "inventory":
            result = inventory(*args)
        elif action == "preview":
            result = read_preview(*args)
        elif action == "install":
            result = install_skill(*args, payload=sys.stdin.buffer)
        else:
            raise ValueError("未知的 Skills 操作")
        print(json.dumps(result))
    except (OSError, RuntimeError, ValueError, tarfile.TarError) as exc:
        sys.exit(str(exc))


if __name__ == "__main__":
    main(sys.argv[1:])
