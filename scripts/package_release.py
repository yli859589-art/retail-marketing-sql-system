"""创建不含 .env、缓存和字节码的课堂交付 ZIP。"""
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT.parent/'Retail_Marketing_Web_Final_Fixed.zip'
EXCLUDE={'.env','.pytest_cache','__pycache__'}

def include(path):
    return not any(part in EXCLUDE for part in path.parts) and path.suffix not in {'.pyc','.log'}

def main():
    with ZipFile(OUT,'w',ZIP_DEFLATED) as archive:
        for path in ROOT.rglob('*'):
            if path.is_file() and include(path.relative_to(ROOT)):
                archive.write(path,Path(ROOT.name)/path.relative_to(ROOT))
    print(OUT)
if __name__=='__main__': main()
