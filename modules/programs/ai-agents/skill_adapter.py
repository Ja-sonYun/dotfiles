import argparse
import re
from pathlib import Path

import yaml


def adapt_skill(directory: Path) -> None:
    skill_path = directory / "SKILL.md"
    text = skill_path.read_text(encoding="utf-8")
    match = re.match(
        r"\A---[ \t]*\n(.*?)^---[ \t]*(?:\n|$)",
        text,
        re.MULTILINE | re.DOTALL,
    )
    if match is None:
        raise ValueError(f"Missing or unterminated frontmatter in {skill_path}")

    frontmatter = yaml.safe_load(match.group(1))
    if not isinstance(frontmatter, dict):
        raise ValueError(f"Invalid frontmatter in {skill_path}")
    field = "disable-model-invocation"
    if field not in frontmatter:
        return
    disabled = frontmatter.pop(field)
    if not isinstance(disabled, bool):
        raise ValueError(f"{field} must be a boolean in {skill_path}")

    metadata_path = directory / "agents" / "openai.yaml"
    metadata = (
        yaml.safe_load(metadata_path.read_text(encoding="utf-8"))
        if metadata_path.exists()
        else {}
    )
    if not isinstance(metadata, dict):
        raise ValueError(f"Invalid metadata in {metadata_path}")
    policy = metadata.setdefault("policy", {})
    if not isinstance(policy, dict):
        raise ValueError(f"Invalid policy in {metadata_path}")
    policy["allow_implicit_invocation"] = not disabled

    skill_path.write_text(
        "---\n"
        + yaml.safe_dump(frontmatter, sort_keys=False, allow_unicode=True)
        + "---\n"
        + text[match.end() :],
        encoding="utf-8",
    )
    metadata_path.parent.mkdir(parents=True, exist_ok=True)
    metadata_path.write_text(
        yaml.safe_dump(metadata, sort_keys=False, allow_unicode=True),
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--skill-dir", type=Path, required=True)
    args = parser.parse_args()
    adapt_skill(args.skill_dir)


if __name__ == "__main__":
    main()
