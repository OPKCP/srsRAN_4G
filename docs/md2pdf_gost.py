#!/usr/bin/env python3
# ==============================================================================
# md2pdf_gost.py — конвертация Markdown-документа в PDF в стилистике ГОСТ.
# Использует reportlab (чистый Python, без системных зависимостей).
# Стиль: шрифты Times, титульный лист, нумерация разделов, таблицы.
#
# Использование:
#   python md2pdf_gost.py <input.md> <output.pdf>
# ==============================================================================
import sys
import re
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib import colors
from reportlab.pdfgen import canvas
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle,
    PageBreak, KeepTogether
)
from reportlab.lib.enums import TA_CENTER, TA_LEFT, TA_JUSTIFY
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont

# --- Регистрация шрифтов с поддержкой кириллицы (DejaVuSans) ---
def register_cyrillic_fonts():
    """Регистрирует шрифты DejaVuSans (поддержка кириллицы), иначе квадратики."""
    import os
    # Пары (normal, bold) шрифтов с поддержкой кириллицы, в порядке предпочтения.
    candidates = [
        # DejaVuSans (Linux/macOS, часто в системах)
        ('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
         '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'),
        ('/usr/share/fonts/dejavu/DejaVuSans.ttf',
         '/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf'),
        # Arial (Windows, поддерживает кириллицу)
        ('C:/Windows/Fonts/arial.ttf',
         'C:/Windows/Fonts/arialbd.ttf'),
    ]
    normal = bold = None
    for n, b in candidates:
        if os.path.exists(n):
            normal, bold = n, b
            if not os.path.exists(bold):
                bold = n  # fallback: bold=normal
            break
    if normal is None:
        raise RuntimeError("Не найден шрифт с кириллицей (DejaVuSans или Arial)")
    pdfmetrics.registerFont(TTFont('DejaVuSans', normal))
    pdfmetrics.registerFont(TTFont('DejaVuSans-Bold', bold))
    return normal


FONT  = 'DejaVuSans'
FONTB = 'DejaVuSans-Bold'

def parse_markdown(md):
    """Разбирает Markdown в структурированный список: (type, text)."""
    lines = md.splitlines()
    elems = []
    i = 0
    in_code = False
    while i < len(lines):
        ln = lines[i]
        s = ln.strip()
        # таблица
        if s.startswith('|') and i + 1 < len(lines) and re.match(r'^\s*\|[\s:|-]+\|', lines[i+1]):
            header = [c.strip() for c in s.strip('|').split('|')]
            i += 2
            rows = []
            while i < len(lines) and lines[i].strip().startswith('|'):
                rows.append([c.strip() for c in lines[i].strip().strip('|').split('|')])
                i += 1
            elems.append(('TABLE', (header, rows)))
            continue
        if s.startswith('#'):
            level = len(ln) - len(ln.lstrip('#'))
            elems.append(('H', (level, s.lstrip('#').strip())))
        elif s.startswith('|'):
            # одиночная строка-таблица без заголовка — трактуем как пару
            cells = [c.strip() for c in s.strip('|').split('|')]
            if len(cells) >= 2:
                elems.append(('KV', cells[0:2]))
            else:
                elems.append(('P', s))
        elif s == '---':
            elems.append(('HR', None))
        elif s.startswith('- '):
            elems.append(('LI', s[2:].strip()))
        elif s.startswith('```'):
            in_code = not in_code
        else:
            if s:
                # Сначала экранируем угловые скобки (чтобы <контейнер> не стал тегом)
                txt = re.sub(r'<([^/][^>]*)>', r'&lt;\1&gt;', s)
                # затем применяем inline-разметку (генерует теги уже после экранирования)
                txt = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', txt)
                txt = re.sub(r'`(.+?)`', r'<font face="DejaVuSans">\1</font>', txt)
                elems.append(('P', txt))
        i += 1
    return elems


def build_pdf(md_path, pdf_path):
    register_cyrillic_fonts()  # с кириллицей (иначе квадратики)
    doc = SimpleDocTemplate(
        pdf_path, pagesize=A4,
        leftMargin=30*mm, rightMargin=15*mm,
        topMargin=20*mm, bottomMargin=20*mm,
        title="Техническое описание стенда LTE"
    )
    story = []

    styles = {
        'title': ParagraphStyle('title', fontName=FONTB, fontSize=16,
                                leading=20, alignment=TA_CENTER),
        'sub': ParagraphStyle('sub', fontName=FONT, fontSize=12,
                              leading=15, alignment=TA_CENTER),
        'h1': ParagraphStyle('h1', fontName=FONTB, fontSize=14,
                             leading=18, spaceBefore=12, spaceAfter=6),
        'h2': ParagraphStyle('h2', fontName=FONTB, fontSize=12,
                             leading=16, spaceBefore=8, spaceAfter=4),
        'h3': ParagraphStyle('h3', fontName=FONTB, fontSize=11,
                             leading=14, spaceBefore=6, spaceAfter=3),
        'body': ParagraphStyle('body', fontName=FONT, fontSize=11,
                               leading=15, alignment=TA_JUSTIFY, spaceAfter=4),
        'li': ParagraphStyle('li', fontName=FONT, fontSize=11,
                             leading=14, leftIndent=14, spaceAfter=2),
        'kv': ParagraphStyle('kv', fontName=FONT, fontSize=11,
                             leading=14, spaceAfter=1),
        'hr': ParagraphStyle('hr', fontName=FONT, fontSize=8, leading=8),
    }

    # Титульный лист
    story.append(Spacer(1, 40*mm))
    story.append(Paragraph("ТЕХНИЧЕСКОЕ ОПИСАНИЕ", styles['title']))
    story.append(Paragraph("СТЕНДА-ДЕМОНСТРАТОРА СЕТИ LTE", styles['title']))
    story.append(Spacer(1, 10*mm))
    story.append(Paragraph("ЛТЕ.СТЕНД.001-ТО", styles['sub']))
    story.append(Spacer(1, 20*mm))
    story.append(Paragraph("Рабочая документация", styles['sub']))
    story.append(Spacer(1, 40*mm))
    story.append(Paragraph("26.08.2026", styles['sub']))
    story.append(PageBreak())

    # Основной текст
    for etype, data in parse_markdown(open(md_path, encoding='utf-8').read()):
        if etype == 'H':
            level, text = data
            if level == 1:
                story.append(Paragraph(text, styles['h1']))
            elif level == 2:
                story.append(Paragraph(text, styles['h2']))
            else:
                story.append(Paragraph(text, styles['h3']))
        elif etype == 'P':
            story.append(Paragraph(data, styles['body']))
        elif etype == 'LI':
            story.append(Paragraph("• " + data, styles['li']))
        elif etype == 'KV':
            k, v = data
            story.append(Paragraph(f"<b>{k}</b>: {v}", styles['kv']))
        elif etype == 'TABLE':
            header, rows = data
            # Определяем ширины: если много столбцов - уменьшаем шрифт
            ncols = len(header)
            cell_style = ParagraphStyle(
                'cell', fontName=FONT, fontSize=8.5, leading=10.5)
            cell_style_h = ParagraphStyle(
                'cellh', fontName=FONTB, fontSize=8.5, leading=10.5)
            # Ячейки как Paragraph - перенос текста
            tdata = [[Paragraph(c, cell_style_h) for c in header]]
            for r in rows:
                tdata.append([Paragraph(c, cell_style) for c in r])
            t = Table(tdata, repeatRows=1)
            t.setStyle(TableStyle([
                ('GRID', (0,0), (-1,-1), 0.5, colors.black),
                ('BACKGROUND', (0,0), (-1,0), colors.Color(0.9,0.9,0.9)),
                ('VALIGN', (0,0), (-1,-1), 'TOP'),
                ('LEFTPADDING', (0,0), (-1,-1), 4),
                ('RIGHTPADDING', (0,0), (-1,-1), 4),
            ]))
            story.append(Spacer(1, 4))
            story.append(t)
            story.append(Spacer(1, 6))
        elif etype == 'HR':
            story.append(Spacer(1, 4))

    # Колонтитулы
    def on_page(canv, doc_):
        page_num = canv.getPageNumber()
        if page_num > 1:
            canv.setFont(FONT, 9)
            canv.drawRightString(A4[0]-20*mm, 12*mm, f"Лист {page_num}")
            canv.drawString(30*mm, 12*mm, "ЛТЕ.СТЕНД.001-ТО")

    doc.build(story, onFirstPage=on_page, onLaterPages=on_page)
    print(f"[OK] PDF создан: {pdf_path}")


if __name__ == '__main__':
    if len(sys.argv) < 3:
        # дефолтные пути
        md_path = "WALLSTAND_TECH_DESCRIPTION.md"
        pdf_path = "WALLSTAND_TECH_DESCRIPTION.pdf"
    else:
        md_path, pdf_path = sys.argv[1], sys.argv[2]
    build_pdf(md_path, pdf_path)
