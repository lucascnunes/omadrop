#!/usr/bin/env python3
"""Verify a parent swap cannot redirect an in-flight state replacement."""

import importlib.machinery
import importlib.util
import os
import sys


sys.dont_write_bytecode = True
helper_path, root = sys.argv[1:]
loader = importlib.machinery.SourceFileLoader("write_shelf_state", helper_path)
spec = importlib.util.spec_from_loader(loader.name, loader)
if spec is None:
    raise RuntimeError("could not load state writer")
writer = importlib.util.module_from_spec(spec)
loader.exec_module(writer)

state = os.path.join(root, "state")
replacement = os.path.join(root, "replacement")
opened_parent = os.path.join(root, "opened-parent")
os.mkdir(root)
os.mkdir(state)
os.mkdir(replacement)
with open(os.path.join(state, "shelf.json"), "w", encoding="utf-8") as file:
    file.write("old")
with open(os.path.join(replacement, "shelf.json"), "w", encoding="utf-8") as file:
    file.write("redirected")

real_write = writer.os.write
swapped = False


def swap_parent_then_write(fd, data):
    global swapped
    if not swapped:
        os.rename(state, opened_parent)
        os.rename(replacement, state)
        swapped = True
    return real_write(fd, data)


writer.os.write = swap_parent_then_write
try:
    writer.write_state(os.path.join(state, "shelf.json"), "safe")
finally:
    writer.os.write = real_write

with open(os.path.join(opened_parent, "shelf.json"), encoding="utf-8") as file:
    assert file.read() == "safe"
with open(os.path.join(state, "shelf.json"), encoding="utf-8") as file:
    assert file.read() == "redirected"
