"""Render docs/SOP.md to a compact one-page docs/SOP.pdf (minimal markdown subset)."""
import re
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import inch
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

DOCS = Path(__file__).resolve().parent.parent / "docs"
SRC, OUT = DOCS / "SOP.md", DOCS / "SOP.pdf"

BASE = 9.2
body = ParagraphStyle("body", fontName="Helvetica", fontSize=BASE, leading=BASE + 2.2, spaceAfter=1.5)
h1 = ParagraphStyle("h1", parent=body, fontName="Helvetica-Bold", fontSize=13, leading=15, spaceAfter=3)
h2 = ParagraphStyle("h2", parent=body, fontName="Helvetica-Bold", fontSize=10.5, leading=12.5,
                    spaceBefore=4, spaceAfter=1.5, textColor=colors.HexColor("#1F3A5F"))
note = ParagraphStyle("note", parent=body, backColor=colors.HexColor("#FFF4D6"), borderPadding=3,
                      spaceAfter=3)
li = ParagraphStyle("li", parent=body, leftIndent=11, bulletIndent=2)
cell = ParagraphStyle("cell", parent=body, fontSize=BASE - 0.7, leading=BASE + 1, spaceAfter=0)
cell_b = ParagraphStyle("cell_b", parent=cell, fontName="Helvetica-Bold")


def inline(t):
    t = t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    t = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", t)
    t = re.sub(r"`(.+?)`", r'<font face="Courier" size="%s">\1</font>' % (BASE - 0.8), t)
    return t


def build():
    story, table_rows = [], []
    lines = SRC.read_text().splitlines()

    def flush_table():
        if not table_rows:
            return
        data = []
        for i, r in enumerate(table_rows):
            data.append([Paragraph(inline(c), cell_b if i == 0 else cell) for c in r])
        t = Table(data, colWidths=[0.55 * inch, 2.9 * inch, 3.95 * inch])
        t.setStyle(TableStyle([
            ("GRID", (0, 0), (-1, -1), 0.3, colors.HexColor("#B8C2CC")),
            ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#E8EEF4")),
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("TOPPADDING", (0, 0), (-1, -1), 1.2), ("BOTTOMPADDING", (0, 0), (-1, -1), 1.2),
            ("LEFTPADDING", (0, 0), (-1, -1), 3), ("RIGHTPADDING", (0, 0), (-1, -1), 3),
        ]))
        story.append(t)
        story.append(Spacer(1, 3))
        table_rows.clear()

    for line in lines:
        if line.startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if not all(re.fullmatch(r"-+", c) for c in cells):
                table_rows.append(cells)
            continue
        flush_table()
        if not line.strip():
            continue
        if line.startswith("# "):
            story.append(Paragraph(inline(line[2:]), h1))
        elif line.startswith("## "):
            story.append(Paragraph(inline(line[3:]), h2))
        elif line.startswith("> "):
            story.append(Paragraph(inline(line[2:]), note))
        elif re.match(r"\d+\. ", line):
            n, rest = line.split(". ", 1)
            story.append(Paragraph(inline(rest), li, bulletText=f"{n}."))
        elif line.startswith("- "):
            story.append(Paragraph(inline(line[2:]), li, bulletText="•"))
        else:
            story.append(Paragraph(inline(line), body))
    flush_table()

    doc = SimpleDocTemplate(str(OUT), pagesize=letter, leftMargin=0.55 * inch, rightMargin=0.55 * inch,
                            topMargin=0.45 * inch, bottomMargin=0.4 * inch,
                            title="SOP: Monthly HIE Facility Data-Quality & Compliance Report (Synthetic)",
                            author="Pallavi Telu")
    doc.build(story)


if __name__ == "__main__":
    build()
    print(f"wrote {OUT}")
