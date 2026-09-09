#!/usr/bin/env python3
"""
Pull one step's effective definition straight out of bitbucket-pipelines.yml.

YAML anchors/aliases (&build-step / *build-step) are resolved by PyYAML at
parse time, so this reads exactly what Bitbucket itself would evaluate for a
given step -- no hand-copied/out-of-sync script text.

Usage:
    pipeline_step.py <yaml-file> --list
    pipeline_step.py <yaml-file> --step "<step name>" --field script
    pipeline_step.py <yaml-file> --step "<step name>" --field after-script
    pipeline_step.py <yaml-file> --step "<step name>" --field image
    pipeline_step.py <yaml-file> --step "<step name>" --field size
    pipeline_step.py <yaml-file> --step "<step name>" --field services
    pipeline_step.py <yaml-file> --docker-service-memory
"""
import argparse
import sys

import yaml


def load(path):
    with open(path) as f:
        return yaml.safe_load(f)


def find_step(doc, name):
    for entry in doc.get("definitions", {}).get("steps", []):
        step = entry.get("step", {})
        if step.get("name") == name:
            return step
    raise SystemExit(f"no step named {name!r} found under definitions.steps")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("yaml_file")
    p.add_argument("--list", action="store_true")
    p.add_argument("--step")
    p.add_argument("--field", choices=["script", "after-script", "image", "size", "services"])
    p.add_argument("--docker-service-memory", action="store_true")
    args = p.parse_args()

    doc = load(args.yaml_file)

    if args.list:
        for entry in doc.get("definitions", {}).get("steps", []):
            step = entry.get("step", {})
            print(step.get("name", "<unnamed>"))
        return

    if args.docker_service_memory:
        mem = (
            doc.get("definitions", {})
            .get("services", {})
            .get("docker", {})
            .get("memory")
        )
        print(mem if mem is not None else "")
        return

    if not args.step or not args.field:
        p.error("--step and --field are required unless --list or --docker-service-memory")

    step = find_step(doc, args.step)

    if args.field in ("script", "after-script"):
        lines = step.get(args.field, [])
        for line in lines:
            # Folded (">") scalars already collapse to one string with real
            # newlines; print each list item as one shell command.
            print(line)
        return

    if args.field == "image":
        image = step.get("image", doc.get("image"))
        if isinstance(image, dict):
            print(image.get("name", ""))
        else:
            print(image or "")
        return

    if args.field == "size":
        print(step.get("size", "1x"))
        return

    if args.field == "services":
        for svc in step.get("services", []):
            print(svc)
        return


if __name__ == "__main__":
    main()
