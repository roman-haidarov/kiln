import hashlib
import json
import os
import pathlib

root = pathlib.Path(__file__).resolve().parent.parent
output_dir = pathlib.Path(os.environ.get("KILN_VALIDATION_DIR", "/tmp/kiln-validation"))
target = output_dir / "manifest.json"
skip_dirs = {".git", "build", "__pycache__", ".ruby-lsp", "validation"}
digests = {}
for directory, subdirectories, files in os.walk(root):
    subdirectories[:] = sorted(name for name in subdirectories if name not in skip_dirs)
    for name in sorted(files):
        path = pathlib.Path(directory) / name
        if path.suffix == ".zip":
            continue
        digests[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
output_dir.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps(digests, indent=2, sort_keys=True) + "\n")
print(f"{len(digests)} files -> {target}")
