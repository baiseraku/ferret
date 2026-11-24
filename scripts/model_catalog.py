"""Merge a model catalog received over SSH into the server's Codex catalog."""

import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
import time


REVIEW_OVERRIDE = "auto_review_model_override"


def read_catalog(source, label):
    try:
        catalog = json.load(source)
    except ValueError as exc:
        raise ValueError(f"{label}模型清单无法解析为 JSON：{exc}") from exc
    models = catalog.get("models") if isinstance(catalog, dict) else None
    if not isinstance(models, list) or any(
        not isinstance(model, dict) or not isinstance(model.get("slug"), str) or not model["slug"]
        for model in models
    ):
        raise ValueError(f"{label}模型清单必须包含带 slug 的 models 列表")
    return catalog


def preserve_auto_review(models, previous):
    server_models = {model["slug"]: model for model in previous}
    local_slugs = {model["slug"] for model in models}
    reviewers = {}
    preserved = 0
    for model in models:
        server_override = server_models.get(model["slug"], {}).get(REVIEW_OVERRIDE)
        if isinstance(server_override, str) and server_override and server_override != model.get(REVIEW_OVERRIDE):
            model[REVIEW_OVERRIDE] = server_override
            preserved += 1
        reviewer = model.get(REVIEW_OVERRIDE)
        if isinstance(reviewer, str) and reviewer not in local_slugs and reviewer in server_models:
            reviewers[reviewer] = server_models[reviewer]
    models.extend(reviewers.values())
    return preserved


def replace_text(path, text):
    path = path.resolve()
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    temporary = Path(name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            output.write(text)
        if path.exists():
            temporary.chmod(stat.S_IMODE(path.stat().st_mode))
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def set_catalog_path(config, destination):
    try:
        current = config.read_text(encoding="utf-8")
    except FileNotFoundError:
        return
    setting = f"model_catalog_json = {json.dumps(str(destination), ensure_ascii=False)}"
    updated, matches = re.subn(r"(?m)^model_catalog_json[ \t]*=.*$", lambda _: setting, current)
    if not matches:
        updated = f"{setting}\n{current}"
    if updated != current:
        backup = config.with_name(config.name + time.strftime(".bak-sync-%Y%m%d-%H%M%S"))
        shutil.copy2(config, backup)
        replace_text(config, updated)


def sync_catalog(source, destination, config):
    incoming = read_catalog(source, "本机")
    try:
        with destination.open(encoding="utf-8") as installed:
            current = read_catalog(installed, "服务器")
    except FileNotFoundError:
        current = {"models": []}
    preserved = preserve_auto_review(incoming["models"], current["models"])
    if incoming != current or not destination.exists():
        replace_text(destination, json.dumps(incoming, ensure_ascii=False, indent=2) + "\n")
    set_catalog_path(config, destination)
    return len(incoming["models"]), preserved


def main():
    destination = Path(sys.argv[1]).absolute()
    try:
        count, preserved = sync_catalog(sys.stdin, destination, Path.home() / ".codex" / "config.toml")
    except (OSError, ValueError) as exc:
        sys.exit(f"  同步模型目录失败：{exc}")
    print(f"  已同步 {count} 个模型 → {destination}")
    if preserved:
        print(f"  已保留 {preserved} 项服务器自动审批配置")


if __name__ == "__main__":
    main()
