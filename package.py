import os
import pathlib
import sys
import subprocess
import zipfile

root = pathlib.Path(__file__).resolve().parent
subprocess.run([sys.executable, str(root / "scripts" / "make_manifest.py")], check=True)
output = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else root.parent / "kiln.zip").resolve()
temporary = output.with_name(output.name + ".tmp")
output.parent.mkdir(parents=True, exist_ok=True)

with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for directory, subdirectories, files in os.walk(root):
        subdirectories[:] = sorted(
            name for name in subdirectories
            if name not in {".git", "build", "__pycache__", ".ruby-lsp", "validation"}
        )
        for name in sorted(files):
            path = pathlib.Path(directory) / name
            relative = path.relative_to(root)
            if path.resolve() in {output, temporary} or path.suffix == ".zip":
                continue
            archive.write(path, relative.as_posix())

os.replace(temporary, output)
print(output)
