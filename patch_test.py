import re

with open('sidecar/test/parser.test.ts', 'r', encoding='utf-8') as f:
    code = f.read()

def patch_test(m):
    return '''  test('replies nested more than one level down are all listed, depth-first', () => {
    const raw = page(
      [thread('r1', [thread('r2', [thread('r3')]), thread('r4')]), thread('r5')],
      [
        ...commentEntities('r1', 'reply-1', 1),
        ...commentEntities('r2', 'reply-2', 2),
        ...commentEntities('r3', 'reply-3', 3),
        ...commentEntities('r4', 'reply-4', 2),
        ...commentEntities('r5', 'reply-5', 1),
      ],
    );
    const items = parseComments(raw, 'synthetic').items;
    expect(items.map((c) => c.id)).toEqual([
      'reply-1', 'reply-2', 'reply-3', 'reply-4', 'reply-5',
    ]);
    expect(items.map((c) => c.depth)).toEqual([1, 2, 3, 2, 1]);
  });'''

code = re.sub(r"  test\('replies nested more than one level down are all listed, depth-first', \(\) => \{.*?\n  \}\);", patch_test, code, flags=re.DOTALL)

with open('sidecar/test/parser.test.ts', 'w', encoding='utf-8') as f:
    f.write(code)
