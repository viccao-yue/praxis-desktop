"""Local regression checks; temporary files only, no OA or network access."""
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from pypdf import PdfWriter, PdfReader
from prepare_oa_plan import prepare
from compose_invoice_pdf import compose


class AutomationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def pdf(self, name, count=1):
        p = self.root/name
        w = PdfWriter()
        w.add_metadata({'/Title': name})
        for i in range(count):
            w.add_blank_page(width=400+i, height=200+i)
        w.write(p)
        return p

    def test_layout_preserves_multipage_and_extra(self):
        files = [self.pdf('one.pdf'), self.pdf('two.pdf', 3), self.pdf('three.pdf')]
        before = [p.read_bytes() for p in files]
        manifest = self.root/'input.json'
        manifest.write_text(json.dumps({'invoices': [
            {'invoice_id': str(i), 'file':str(p), 'verified':True, 'extra_copy':i==1}
            for i,p in enumerate(files)]}))
        result = compose(manifest,self.root/'out')
        self.assertEqual(result['regular_pages'],5)
        output = PdfReader(self.root/'out/发票打印清单_候选.pdf')
        self.assertEqual([float(p.mediabox.width) for p in output.pages[1:4]], [400,401,402])
        self.assertEqual(len(PdfReader(self.root/'out/额外独立加印_02.pdf').pages),3)
        self.assertEqual(before,[p.read_bytes() for p in files])
        with self.assertRaises(ValueError):
            compose(manifest,self.root/'out')

    def test_duplicate_invoice_rejected(self):
        p=self.pdf('a.pdf')
        manifest=self.root/'input.json'
        manifest.write_text(json.dumps({'invoices':[
            {'invoice_id':str(i),'file':str(p),'verified':True,'extra_copy':False} for i in range(2)]}))
        with self.assertRaisesRegex(ValueError,'重复原票'):
            compose(manifest,self.root/'out')
        self.assertFalse((self.root/'out').exists())

    def test_preflight_uses_paid_amount_not_face_and_checks_hash(self):
        source=self.pdf('a.pdf')
        evidence=self.root/'payment.jpg'; evidence.write_bytes(b'fixture')
        original=self.root/'原始文档'; original.mkdir()
        record=original/'处理记录.json'
        row={'document_type':'invoice','invoice_id':'1','expense_category':'费用报销',
             'subtype':'餐饮','currency':'CNY','original_path':str(source),
             'sha256':hashlib.sha256(source.read_bytes()).hexdigest(),
             'invoice_face_total':'100.00','actual_paid_amount':'99.88',
             'proposed_reimbursement_amount':'99.88','payment_date':'2026-10-21',
             'expense_subject':'销售费用_业务招待费','oa_summary':'客户招待费',
             'invoice_type':'普通发票','payment_evidence_path':str(evidence)}
        record.write_text(json.dumps({'records':[row]}))
        before=record.read_bytes()
        result=prepare(record,'费用报销')
        self.assertTrue(result['ready_for_review']); self.assertEqual(result['candidate_total'],'99.88')
        self.assertEqual(result['attachment_count'],2); self.assertEqual(before,record.read_bytes())
        row['sha256']='changed'; row['payment_date']=None; row['proposed_reimbursement_amount']=None
        record.write_text(json.dumps({'records':[row]}))
        result=prepare(record,'费用报销')
        self.assertFalse(result['ready_for_review'])
        messages=' '.join(x['message'] for x in result['issues'])
        for fragment in ['哈希','发生日期','拟报金额']:
            self.assertIn(fragment,messages)


if __name__=='__main__':
    unittest.main()
