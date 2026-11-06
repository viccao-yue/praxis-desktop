"""Vector PDF invoice layout: two single pages per A4; multipage originals intact."""
import argparse
import hashlib
import json
from copy import copy
from pathlib import Path
from pypdf import PdfReader, PdfWriter, Transformation

A4 = (595.2756, 841.8898)


def compose(manifest, output):
    data = json.loads(manifest.read_text(encoding='utf-8-sig'))
    if output.exists():
        raise ValueError('输出目录已存在；请用新的内部核验目录')
    invoices = data['invoices']
    if not invoices:
        raise ValueError('没有发票')
    checked, ids, hashes = [], set(), set()
    for r in invoices:
        key = str(r.get('invoice_id') or '')
        if not key or key in ids or r.get('verified') is not True:
            raise ValueError('缺少/重复票号或票据未核实')
        path = Path(r['file'])
        path = path if path.is_absolute() else manifest.parent / path
        sha = hashlib.sha256(path.read_bytes()).hexdigest()
        if sha in hashes:
            raise ValueError('重复原票文件')
        if r.get('sha256') and r['sha256'] != sha:
            raise ValueError('原票哈希变化')
        ids.add(key); hashes.add(sha)
        reader = PdfReader(path)
        if reader.is_encrypted or not reader.pages:
            raise ValueError('加密或空PDF，需另行核对')
        # Flags must be explicit; no guessing invoice type from the filename.
        if not isinstance(r.get('extra_copy'), bool):
            raise ValueError('必须明确extra_copy：专票/通行票true，其他false')
        checked.append((r, reader, sha))
    writer = PdfWriter()
    pending = None
    index = []
    for r, reader, sha in checked:
        if len(reader.pages) > 1 or r.get('full_page') is True:
            pending = None
            start = len(writer.pages) + 1
            for page in reader.pages:
                writer.add_page(page)
            index.append({'invoice_id': r['invoice_id'], 'sha256': sha,
                          'pages': list(range(start, len(writer.pages) + 1)), 'layout': '完整原页'})
        else:
            if pending is None:
                pending = writer.add_blank_page(width=A4[0], height=A4[1])
                slot = 0
            else:
                slot = 1
            page = copy(reader.pages[0])
            page.transfer_rotation_to_content()
            page.cropbox = copy(page.mediabox)
            # Include the whole media box; no automatic cropping.
            w, h = float(page.mediabox.width), float(page.mediabox.height)
            scale = min((A4[0]-40)/w, (A4[1]/2-40)/h)
            x = (A4[0]-w*scale)/2
            y = A4[1] - (slot+1)*A4[1]/2 + (A4[1]/2-h*scale)/2
            transform = Transformation().translate(-float(page.mediabox.left),
                                                    -float(page.mediabox.bottom))
            transform = transform.scale(scale).translate(x,y)
            pending.merge_transformed_page(page, transform)
            index.append({'invoice_id': r['invoice_id'], 'sha256': sha,
                          'pages': [len(writer.pages)], 'slot': slot+1, 'layout': '两票A4'})
            if slot:
                pending = None
    output.mkdir(parents=True)
    writer.write(output/'发票打印清单_候选.pdf')
    extras = []
    for i, (r, reader, _) in enumerate(checked, 1):
        if r['extra_copy']:
            extra = PdfWriter()
            for page in reader.pages:
                extra.add_page(page)
            name = f'额外独立加印_{i:02d}.pdf'
            extra.write(output/name)
            extras.append({'invoice_id': r['invoice_id'], 'file': name})
    result = {'invoice_count': len(checked), 'regular_pages': len(writer.pages),
              'extra_copies': extras, 'index': index, 'visual_review_passed': False}
    (output/'拼版核验.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    return {k:v for k,v in result.items() if k!='index'}


if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('manifest', type=Path)
    p.add_argument('--output', type=Path, required=True)
    a=p.parse_args()
    try:
        print(json.dumps(compose(a.manifest.resolve(),a.output.resolve()),ensure_ascii=False))
    except (ValueError,KeyError,OSError) as e:
        raise SystemExit('停止：'+str(e))
