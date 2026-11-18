"""Waechter: keine SwiftUI-Ansicht enthaelt sich selbst ohne AnyView (Absturz am iPad Air 4, 18.11.2026, Build 45:
Stapelueberlauf in `_viewListCount` bei einer KI-Antwort mit Formeln). tools/pruefe-rekursive-ansichten.py."""
import importlib.util
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("rek", ROOT / "tools" / "pruefe-rekursive-ansichten.py")
rek = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rek)


def test_app_has_no_self_containing_views():
    found = [f"{f.relative_to(ROOT)}:{line}: {name}" for f, line, name in rek.findings(ROOT / "apps" / "apple")]
    assert not found, "Ansicht enthaelt sich selbst - mit AnyView(...) brechen:\n" + "\n".join(found)


def test_guard_catches_the_crash_pattern(tmp_path):
    (tmp_path / "Node.swift").write_text(textwrap.dedent("""
        struct NodeView: View {
            let node: Node
            var body: some View { content }
            @ViewBuilder private var content: some View {
                switch node {
                case .box(let inner): NodeView(node: inner).padding(4)
                case .leaf(let s): Text(s)
                }
            }
        }
        struct SafeView: View {
            let node: Node
            var body: some View { AnyView(content) }
            @ViewBuilder private var content: some View { SafeView(node: node) }
        }
        struct WrappedView: View {
            var body: some View { VStack { AnyView(WrappedView()) } }
        }
    """), encoding="utf-8")
    names = [name for _f, _l, name in rek.findings(tmp_path)]
    assert names == ["NodeView"]


def test_app_has_no_view_rings():
    rings = [ring for _f, _l, ring in rek.cycles(ROOT / "apps" / "apple")]
    assert not rings, "Ring von Ansichten ohne AnyView:\n" + "\n".join(rings)


def test_guard_catches_rings_across_views(tmp_path):
    (tmp_path / "Ring.swift").write_text(textwrap.dedent("""
        struct BlockList: View {
            let blocks: [Block]
            var body: some View { ForEach(blocks) { b in BlockRow(block: b) } }
        }
        struct BlockRow: View {
            let block: Block
            var body: some View { BlockList(blocks: block.children).padding(8) }
        }
        struct OkList: View {
            var body: some View { OkRow() }
        }
        struct OkRow: View {
            var body: some View { AnyView(OkList()) }
        }
    """), encoding="utf-8")
    rings = [ring for _f, _l, ring in rek.cycles(tmp_path)]
    assert len(rings) == 1 and "BlockList" in rings[0] and "BlockRow" in rings[0], rings
