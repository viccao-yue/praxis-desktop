"""Generate verified single-page invoices as two-per-A4 DOCX plus image-layout PDF."""
from pathlib import Path
import argparse,csv,hashlib,json,re,io,math
from datetime import date
from decimal import Decimal
from PIL import Image,ImageOps
import pypdfium2 as pdfium
from docx import Document
from docx.shared import Mm,Pt
from docx.enum.table import WD_ROW_HEIGHT_RULE,WD_TABLE_ALIGNMENT,WD_CELL_VERTICAL_ALIGNMENT
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from reportlab.pdfgen.canvas import Canvas
from reportlab.lib.utils import ImageReader
from reportlab.lib.units import mm

def resolve(base,value):
    p=Path(value)
    return p if p.is_absolute() else (base/p).resolve()

def render(path):
    if path.suffix.lower()=='.pdf':
        doc=pdfium.PdfDocument(str(path))
        try:
            if len(doc)!=1:raise ValueError('多页发票必须单独核对：'+path.name)
            page=doc[0];bitmap=page.render(scale=200/72)
            im=bitmap.to_pil().convert('RGB').copy()
            bitmap.close();page.close()
            return im
        finally:doc.close()
    if path.suffix.lower() not in ('.png','.jpg','.jpeg','.tif','.tiff','.bmp','.webp'):
        raise ValueError('不支持的发票格式：'+path.name)
    with Image.open(path) as src:
        if getattr(src,'n_frames',1)!=1:raise ValueError('多帧图片需要单独核对')
        im=ImageOps.exif_transpose(src).convert('RGBA')
        bg=Image.new('RGBA',im.size,'white');bg.alpha_composite(im)
        return bg.convert('RGB')

def build(manifest,output):
    base=manifest.parent;data=json.loads(manifest.read_text(encoding='utf-8-sig'))
    month=data['reimbursement_month']
    if not re.fullmatch(r'\d{4}-\d{2}',month):raise ValueError('报销月份格式错误')
    date.fromisoformat(month+'-01')
    if output.exists():raise ValueError('输出目录已存在，停止以避免覆盖')
    groups={};ids=set();hashes=set();applications={}
    invoices=data['invoices']
    if not invoices:raise ValueError('没有发票')
    for inv in invoices:
        key=str(inv['invoice_id']).strip()
        if not key or key in ids:raise ValueError('发票ID缺失或重复')
        if inv.get('verified') is not True:raise ValueError('存在未核对票据')
        amount=Decimal(str(inv['amount']))
        if not amount.is_finite() or amount<=0 or amount!=amount.quantize(Decimal('.01')):raise ValueError('金额异常')
        if inv.get('currency')!='CNY':raise ValueError('非CNY票据需要单独核对')
        date.fromisoformat(inv['expense_date']);date.fromisoformat(inv['issue_date'])
        path=resolve(base,inv['file'])
        if not path.is_file():raise ValueError('发票原件不存在')
        digest=hashlib.sha256(path.read_bytes()).hexdigest()
        if digest in hashes:raise ValueError('重复发票文件')
        ids.add(key);hashes.add(digest)
        category=inv['category'];sub=inv['subtype']
        if category=='外地差旅' and sub in ('酒店','外地打车'):
            trip=str(inv['trip_id']);app=data.get('trips',{}).get(trip)
            if not app or not app.get('destination') or not app.get('period'):raise ValueError('出差关联信息缺失')
            ap=resolve(base,app['application'])
            if not ap.is_file():raise ValueError('出差申请不存在')
            applications[trip]={'trip_id':trip,'destination':app['destination'],'period':app['period'],'application':str(ap)}
            group=(category,trip)
        elif category=='成都本地用车及招待费' and sub in ('本地用车','招待费'):
            group=(category,sub)
        else:raise ValueError('分类需要核对')
        image=render(path)
        groups.setdefault(group,[]).append((inv,image,digest,str(path)))
    output.mkdir(parents=True)
    index=[]
    for group,items in groups.items():
        items.sort(key=lambda row:(row[0]['expense_date'],str(row[0]['invoice_id'])))
        stem=re.sub(r'[<>:"/\\|?*\x00-\x1f]','_',month+'_'+group[0]+'_'+group[1])[:100]
        stem+='_'+hashlib.sha256(repr(group).encode()).hexdigest()[:6]
        doc=Document();section=doc.sections[0]
        section.page_width=Mm(210);section.page_height=Mm(297)
        section.top_margin=section.bottom_margin=Mm(10)
        section.left_margin=section.right_margin=Mm(10)
        normal=doc.styles['Normal'];normal.font.size=Pt(9)
        normal.font.name='Arial';normal.element.rPr.rFonts.set(qn('w:eastAsia'),'宋体')
        normal.paragraph_format.space_after=Pt(0)
        pdf=Canvas(str(output/(stem+'-图片布局预览.pdf')),pagesize=(210*mm,297*mm))
        for start in range(0,len(items),2):
            if start:doc.add_page_break()
            table=doc.add_table(rows=2,cols=1);table.autofit=False
            table.alignment=WD_TABLE_ALIGNMENT.CENTER;table.columns[0].width=Mm(190)
            for slot,row in enumerate(table.rows):
                row.height=Mm(132);row.height_rule=WD_ROW_HEIGHT_RULE.EXACTLY
                prop=row._tr.get_or_add_trPr();prop.append(OxmlElement('w:cantSplit'))
                cell=row.cells[0];cell.vertical_alignment=WD_CELL_VERTICAL_ALIGNMENT.CENTER
                if start+slot>=len(items):continue
                inv,im,digest,path=items[start+slot]
                caption=cell.paragraphs[0]
                caption.text=f"{month} | {group[0]} | {group[1]} | {inv['invoice_id']} | {inv['amount']}元"
                if group[0]=='外地差旅':
                    application=applications[group[1]]
                    caption.text+='\n'+application['period']+' '+application['destination']+'；申请见 trip-applications.csv（'+group[1]+'）'
                caption.paragraph_format.space_after=Pt(2)
                width=min(184,im.width/im.height*112);height=width*im.height/im.width
                buffer=io.BytesIO();im.save(buffer,format='PNG');buffer.seek(0)
                p=cell.add_paragraph();p.alignment=1
                p.add_run().add_picture(buffer,width=Mm(width),height=Mm(height))
                top=10+slot*132+12
                pdf.drawImage(ImageReader(im),(210-width)/2*mm,(297-top-height)*mm,width*mm,height*mm)
                index.append({'invoice_id':inv['invoice_id'],'month':month,'category':group[0],'group':group[1],'amount':str(inv['amount']),'source':path,'sha256':digest,'docx':stem+'.docx','page':start//2+1,'slot':slot+1})
            pdf.showPage()
        doc.save(output/(stem+'.docx'));pdf.save()
    for filename,rows,fields in [('print-index.csv',index,list(index[0])),('trip-applications.csv',list(applications.values()),['trip_id','destination','period','application'])]:
        with (output/filename).open('w',encoding='utf-8-sig',newline='') as f:
            w=csv.DictWriter(f,fields);w.writeheader();w.writerows(rows)
    summary={'invoices':len(index),'groups':len(groups),'pages':sum(math.ceil(len(v)/2) for v in groups.values()),'total_cny':str(sum(Decimal(str(i['amount'])) for i in invoices)),'word_render_verified':False}
    (output/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
    return summary

if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('manifest',type=Path);ap.add_argument('--output',type=Path,required=True);args=ap.parse_args()
    try:print(json.dumps(build(args.manifest.resolve(),args.output.resolve()),ensure_ascii=False))
    except (ValueError,KeyError,OSError) as e:raise SystemExit('停止：'+str(e))
