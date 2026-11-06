"""Compare confirmed data with independently observed OA fields. Read-only."""
import argparse
import json
from collections import Counter
from decimal import Decimal, InvalidOperation
from pathlib import Path

HEADER_FIELDS = ('application_department', 'cost_bearing_department', 'bank',
                 'account_suffix', 'invoice_count', 'total', 'application_attachments')
ROW_FIELDS = ('date', 'subject', 'summary', 'amount', 'invoice_type', 'tax', 'attachments')


def normalize(field, value):
    if field in ('amount', 'tax', 'total'):
        amount = Decimal(str(value).replace(',', '').strip())
        if not amount.is_finite():
            raise ValueError('金额必须是有限数值')
        return amount
    if field == 'invoice_count':
        count = Decimal(str(value))
        if not count.is_finite() or count < 0 or count != count.to_integral_value():
            raise ValueError('发票张数必须是非负整数')
        return int(count)
    if field in ('attachments', 'application_attachments'):
        if not isinstance(value, list) or any(not isinstance(x, str) or not x.strip() for x in value):
            raise ValueError('附件必须是文件名列表')
        return Counter(value)
    if not isinstance(value, str) or not value.strip():
        raise ValueError('字段必须是非空文本')
    if field == 'account_suffix' and (len(value) != 4 or not value.isdecimal()):
        raise ValueError('只允许四位账号尾号')
    return value.strip()


def compare(expected, actual):
    differences = []

    def check(location, fields, left, right):
        for field in fields:
            if field not in left or field not in right:
                differences.append(f'{location} {field} 缺少确认值或页面读取值')
                continue
            if normalize(field, left[field]) != normalize(field, right[field]):
                if field in ('amount', 'tax', 'total', 'invoice_count'):
                    differences.append(f'{location} {field} 预期 {left[field]}，读取 {right[field]}')
                else:
                    differences.append(f'{location} {field} 不一致')

    check('抬头', HEADER_FIELDS, expected, actual)
    before, after = expected['rows'], actual['rows']
    if not before or len(before) != len(after):
        differences.append(f'明细行数 预期 {len(before)}，读取 {len(after)}')
    for index, (left, right) in enumerate(zip(before, after), 1):
        check(f'第 {index} 行', ROW_FIELDS, left, right)
    for label, form in (('确认清单', expected), ('OA页面', actual)):
        if 'total' in form and all('amount' in row for row in form['rows']):
            amounts = sum(normalize('amount', row['amount']) for row in form['rows'])
            if amounts != normalize('total', form['total']):
                differences.append(f'{label}明细合计 {amounts:.2f} 与单据总额不符')
    return differences


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('expected', type=Path)
    parser.add_argument('actual', type=Path)
    args = parser.parse_args()
    try:
        expected = json.loads(args.expected.read_text(encoding='utf-8-sig'))
        actual = json.loads(args.actual.read_text(encoding='utf-8-sig'))
        differences = compare(expected, actual)
    except (OSError, ValueError, KeyError, TypeError, InvalidOperation):
        parser.exit(2, '无法核对：请检查输入文件和字段格式。\n')
    print(json.dumps({'match': not differences, 'differences': differences}, ensure_ascii=False))
    return 0 if not differences else 2


if __name__ == '__main__':
    raise SystemExit(main())
