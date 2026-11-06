"""Read-only batch preflight. Never writes source records or operates OA."""
import argparse
import hashlib
import json
from datetime import date
from decimal import Decimal, InvalidOperation
from pathlib import Path


def money(value):
    try:
        n = Decimal(str(value))
        if not n.is_finite() or n <= 0 or n != n.quantize(Decimal('0.01')):
            raise ValueError('金额必须是正数且最多两位小数')
        return n
    except InvalidOperation as e:
        raise ValueError('金额无效') from e


def digest(path):
    with path.open('rb') as f:
        h = hashlib.sha256()
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
        return h.hexdigest()


def prepare(record_path, category):
    data = json.loads(record_path.read_text(encoding='utf-8-sig'))
    # Standard batch location: batch/原始文档/处理记录.json
    base = record_path.parent.parent
    issues, rows, ids, hashes = [], [], set(), {}
    records = data['records']

    def issue(key, message):
        issues.append({'invoice_id': key, 'message': message})

    def attachment(key, kind, value, expected=None):
        if not value:
            issue(key, '缺少' + kind)
            return None
        p = Path(value)
        if not p.is_absolute():
            p = base / p
        p = p.resolve()
        if not p.is_file():
            issue(key, kind + '文件不存在')
            return {'kind': kind, 'path': str(p), 'exists': False}
        sha = digest(p)
        if expected and sha != expected:
            issue(key, kind + '哈希与记录不符')
        return {'kind': kind, 'path': str(p), 'exists': True, 'sha256': sha}

    total = Decimal('0')
    for r in records:
        if r.get('document_type') != 'invoice' or r.get('expense_category') != category:
            continue
        key = str(r.get('invoice_id') or '')
        if not key or key in ids:
            issue(key, '缺少或重复票号')
        ids.add(key)
        fields = r.get('oa_fields', {})
        # Face value is only a candidate when claim amount has not been confirmed.
        claimed = fields.get('amount', r.get('proposed_reimbursement_amount'))
        if claimed is None:
            issue(key, '拟报金额未结构化确认；候选合计暂用票面，不可据此直接填报')
        try:
            amount = money(claimed if claimed is not None else r.get('invoice_face_total'))
            total += amount
        except ValueError as e:
            issue(key, str(e))
            amount = None
        if r.get('currency') != 'CNY':
            issue(key, '币种不是已确认CNY')
        actual = r.get('actual_paid_amount')
        if actual is not None and amount is not None and money(actual) != amount:
            issue(key, '拟报金额与实付不同，需明确本项申报依据')
        day = fields.get('date') or r.get('payment_date') or r.get('expense_date')
        try:
            date.fromisoformat(day)
        except (TypeError, ValueError):
            issue(key, '发生日期未确认；不取开票日或订单号')
        subject = fields.get('subject') or r.get('expense_subject')
        summary = fields.get('summary') or r.get('oa_summary')
        if not subject:
            issue(key, '缺少科目')
        if not summary:
            issue(key, '缺少已确认费用说明')
        attachments = [attachment(key, '原发票', r.get('original_path'), r.get('sha256'))]
        if attachments[0] and attachments[0].get('exists'):
            sha = attachments[0]['sha256']
            if sha in hashes:
                issue(key, '原票文件与另一票重复：' + hashes[sha])
            hashes[sha] = key
        if r.get('subtype') == '网约车':
            mates = [x for x in records if x.get('document_type') == 'ride_hailing_itinerary'
                     and str(x.get('matched_invoice_id')) == key]
            if not mates:
                issue(key, '缺少匹配完整行程单')
            for m in mates:
                # Original hash does not necessarily describe the electronic copy.
                value = m.get('electronic_attachment') or m.get('original_path')
                expected = m.get('sha256') if value == m.get('original_path') else None
                attachments.append(attachment(key, '完整行程单', value, expected))
        elif category == '费用报销':
            attachments.append(attachment(key, '付款截图', r.get('payment_evidence_path'),
                                          r.get('payment_evidence_sha256')))
        else:
            issue(key, '差旅配套申请及结账单需单独核对，本脚本不判定差旅材料齐备')
        invtype = r.get('invoice_type', '')
        tax = fields.get('tax')
        if tax is None and '普通发票' in invtype:
            tax = '0.00'
        if tax is None:
            issue(key, '专票/通行票等需核对OA税额')
        rows.append({'invoice_id': key, 'merchant': r.get('seller_name'), 'date': day,
                     'subject': subject, 'summary': summary,
                     'amount': str(amount) if amount is not None else None,
                     'amount_confirmed': claimed is not None, 'invoice_type': invtype,
                     'tax': tax, 'attachments': [a for a in attachments if a]})
    if not rows:
        issue('', '指定类别无原发票记录')
    return {'source_sha256': digest(record_path), 'category': category,
            'invoice_count': len(rows), 'detail_rows': len(rows),
            'candidate_total': f'{total:.2f}',
            'attachment_count': sum(len(r['attachments']) for r in rows),
            'ready_for_review': not issues, 'issues': issues, 'rows': rows,
            'scope': '一票一行候选；合并/分摊需另行确认。通过预检不证明内容真实或OA已保存。'}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('record', type=Path)
    p.add_argument('--category', default='费用报销', choices=['费用报销', '差旅报销'])
    p.add_argument('--output', type=Path, help='内部核验JSON；必须是不存在的新文件')
    a = p.parse_args()
    result = prepare(a.record.resolve(), a.category)
    if a.output:
        # Exclusive create prevents accidental overwrite of existing evidence.
        with a.output.open('x', encoding='utf-8') as f:
            json.dump(result, f, ensure_ascii=False, indent=2)
            f.write('\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'rows'}, ensure_ascii=False))
    return 0 if result['ready_for_review'] else 2


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, KeyError, OSError) as e:
        raise SystemExit('停止：' + str(e))
