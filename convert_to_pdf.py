#!/usr/bin/env python3
"""Convert markdown documentation to PDF"""

import re
import os
from fpdf import FPDF

def clean_unicode(text):
    """Replace Unicode box-drawing and special characters with ASCII"""
    replacements = {
        '\u250c': '+', '\u2510': '+', '\u2514': '+', '\u2518': '+',  # corners
        '\u2500': '-', '\u2502': '|', '\u253c': '+',  # lines
        '\u251c': '+', '\u2524': '+', '\u252c': '+', '\u2534': '+',  # T-junctions
        '\u2550': '=', '\u2551': '|',  # double lines
        '\u2554': '+', '\u2557': '+', '\u255a': '+', '\u255d': '+',  # double corners
        '\u25a0': '*', '\u25cf': '*', '\u2022': '*',  # bullets
        '\u2713': '[x]', '\u2717': '[ ]', '\u2714': '[x]', '\u2718': '[ ]',  # checkmarks
        '\u2190': '<-', '\u2192': '->', '\u2191': '^', '\u2193': 'v',  # arrows
        '\u25b6': '>', '\u25c0': '<', '\u25b2': '^', '\u25bc': 'v',  # triangles
        '\u2026': '...', '\u2013': '-', '\u2014': '--',  # punctuation
        '\u201c': '"', '\u201d': '"', '\u2018': "'", '\u2019': "'",  # quotes
        '\u00d7': 'x',  # multiplication
        '\u2248': '~',  # approximately
        '\u2260': '!=',  # not equal
        '\u2264': '<=', '\u2265': '>=',  # comparisons
        '←': '<-', '→': '->', '↑': '^', '↓': 'v',  # arrows
        '✓': '[x]', '✗': '[ ]',  # checkmarks
        '│': '|', '─': '-', '┌': '+', '┐': '+', '└': '+', '┘': '+',
        '├': '+', '┤': '+', '┬': '+', '┴': '+', '┼': '+',
        '►': '>', '◄': '<', '▲': '^', '▼': 'v',
    }
    for uni, ascii_char in replacements.items():
        text = text.replace(uni, ascii_char)
    # Remove any remaining non-ASCII characters
    return ''.join(c if ord(c) < 256 else '?' for c in text)

class MarkdownPDF(FPDF):
    def __init__(self):
        super().__init__()
        self.add_page()
        self.set_auto_page_break(auto=True, margin=15)

    def chapter_title(self, title):
        self.set_font('Helvetica', 'B', 16)
        self.set_text_color(0, 51, 102)
        self.cell(0, 10, clean_unicode(title), new_x='LMARGIN', new_y='NEXT')
        self.ln(4)

    def section_title(self, title):
        self.set_font('Helvetica', 'B', 13)
        self.set_text_color(0, 51, 102)
        self.cell(0, 8, clean_unicode(title), new_x='LMARGIN', new_y='NEXT')
        self.ln(2)

    def subsection_title(self, title):
        self.set_font('Helvetica', 'B', 11)
        self.set_text_color(51, 51, 51)
        self.cell(0, 7, clean_unicode(title), new_x='LMARGIN', new_y='NEXT')
        self.ln(1)

    def body_text(self, text):
        self.set_font('Helvetica', '', 10)
        self.set_text_color(0, 0, 0)
        self.multi_cell(0, 5, clean_unicode(text))
        self.ln(2)

    def code_block(self, code):
        self.set_font('Courier', '', 8)
        self.set_fill_color(245, 245, 245)
        self.set_text_color(0, 0, 0)
        for line in code.split('\n'):
            clean_line = clean_unicode(line)
            if len(clean_line) > 80:
                clean_line = clean_line[:77] + '...'
            self.cell(0, 4, '  ' + clean_line, new_x='LMARGIN', new_y='NEXT', fill=True)
        self.ln(3)

    def table_row(self, cells, header=False):
        self.set_font('Helvetica', 'B' if header else '', 9)
        if header:
            self.set_fill_color(230, 230, 230)
        else:
            self.set_fill_color(255, 255, 255)

        num_cells = len(cells)
        if num_cells == 0:
            return
        col_width = (self.w - 20) / num_cells
        for cell in cells:
            clean_cell = clean_unicode(cell.strip())
            if len(clean_cell) > 25:
                clean_cell = clean_cell[:22] + '...'
            self.cell(col_width, 6, clean_cell, border=1, fill=header)
        self.ln()

    def bullet_point(self, text, indent=0):
        self.set_font('Helvetica', '', 10)
        self.set_text_color(0, 0, 0)
        x = self.get_x() + indent * 5
        self.set_x(x)
        self.cell(5, 5, '-')
        self.multi_cell(0, 5, clean_unicode(text))

def parse_markdown(md_content):
    """Parse markdown and yield (type, content) tuples"""
    lines = md_content.split('\n')
    i = 0
    in_code_block = False
    code_content = []
    in_table = False
    table_rows = []

    while i < len(lines):
        line = lines[i]

        # Code block
        if line.strip().startswith('```'):
            if in_code_block:
                yield ('code', '\n'.join(code_content))
                code_content = []
                in_code_block = False
            else:
                in_code_block = True
            i += 1
            continue

        if in_code_block:
            code_content.append(line)
            i += 1
            continue

        # Table
        if '|' in line and not line.strip().startswith('#'):
            cells = [c.strip() for c in line.split('|') if c.strip()]
            # Skip separator rows
            if cells and not all(set(c) <= set('-| :') for c in cells):
                if not in_table:
                    in_table = True
                    table_rows = []
                table_rows.append(cells)
            i += 1
            continue
        elif in_table:
            yield ('table', table_rows)
            table_rows = []
            in_table = False

        # Headers
        if line.startswith('# '):
            yield ('h1', line[2:].strip())
        elif line.startswith('## '):
            yield ('h2', line[3:].strip())
        elif line.startswith('### '):
            yield ('h3', line[4:].strip())
        # Horizontal rule
        elif line.strip() in ['---', '***', '___']:
            yield ('hr', '')
        # Bullet points
        elif line.strip().startswith('- ') or line.strip().startswith('* '):
            text = line.strip()[2:]
            indent = (len(line) - len(line.lstrip())) // 2
            yield ('bullet', (text, indent))
        elif line.strip() and line.strip()[0].isdigit() and '. ' in line:
            text = re.sub(r'^\d+\.\s*', '', line.strip())
            yield ('bullet', (text, 0))
        # Regular text
        elif line.strip():
            text = line.strip()
            text = re.sub(r'\*\*(.+?)\*\*', r'\1', text)
            text = re.sub(r'\*(.+?)\*', r'\1', text)
            text = re.sub(r'`(.+?)`', r'\1', text)
            yield ('text', text)

        i += 1

    if in_table and table_rows:
        yield ('table', table_rows)

def convert_markdown_to_pdf(md_path, pdf_path, title):
    """Convert a markdown file to PDF"""
    with open(md_path, 'r', encoding='utf-8') as f:
        content = f.read()

    pdf = MarkdownPDF()

    # Title page header
    pdf.set_font('Helvetica', 'B', 24)
    pdf.set_text_color(0, 51, 102)
    pdf.cell(0, 20, title, new_x='LMARGIN', new_y='NEXT', align='C')
    pdf.ln(5)
    pdf.set_font('Helvetica', '', 10)
    pdf.set_text_color(128, 128, 128)
    pdf.cell(0, 5, 'LiDAR Scanner App Documentation', new_x='LMARGIN', new_y='NEXT', align='C')
    pdf.ln(15)

    for item_type, item_content in parse_markdown(content):
        try:
            if item_type == 'h1':
                pdf.chapter_title(item_content)
            elif item_type == 'h2':
                pdf.section_title(item_content)
            elif item_type == 'h3':
                pdf.subsection_title(item_content)
            elif item_type == 'text':
                pdf.body_text(item_content)
            elif item_type == 'code':
                pdf.code_block(item_content)
            elif item_type == 'bullet':
                text, indent = item_content
                pdf.bullet_point(text, indent)
            elif item_type == 'table':
                rows = item_content
                if rows:
                    pdf.table_row(rows[0], header=True)
                    for row in rows[1:]:
                        pdf.table_row(row, header=False)
                    pdf.ln(3)
            elif item_type == 'hr':
                pdf.ln(3)
                pdf.set_draw_color(200, 200, 200)
                pdf.line(10, pdf.get_y(), pdf.w - 10, pdf.get_y())
                pdf.ln(5)
        except Exception as e:
            # Skip problematic content
            continue

    pdf.output(pdf_path)
    print(f"Created: {pdf_path}")

if __name__ == '__main__':
    docs_dir = os.path.dirname(os.path.abspath(__file__))
    docs_folder = os.path.join(docs_dir, 'docs')

    files_to_convert = [
        ('ML-Training-Guide.md', 'ML-Training-Guide.pdf', 'ML Training Guide'),
        ('Neural-Network-Explained.md', 'Neural-Network-Explained.pdf', 'Neural Network Explained'),
        ('Quick-Reference.md', 'Quick-Reference.pdf', 'Quick Reference Card'),
    ]

    for md_file, pdf_file, title in files_to_convert:
        md_path = os.path.join(docs_folder, md_file)
        pdf_path = os.path.join(docs_folder, pdf_file)

        if os.path.exists(md_path):
            convert_markdown_to_pdf(md_path, pdf_path, title)
        else:
            print(f"Not found: {md_path}")

    print("\nDone! PDF files are in docs/ folder")
