import copy
import unittest
from reveal_count_gate import compare, metrics


class RevealCountGateTests(unittest.TestCase):
    def evidence(self):
        return dict(bundle="com.taha.Attic.preview.phasex", settings=dict(mode="reveal", frame_monitor=False,
                    settle_seconds=20, idle_sample_seconds=60, allocations=False, reveal_counts=True),
                    counts=dict(hooks=["NSView.viewDidChangeEffectiveAppearance"],
                    native_function_counts={key: {"locations": 1, "calls": 2} for key in
                        ("hosting_environment_updates", "native_appearance_applications", "ca_transaction_commits")},
                    after=dict(hosting_roots=1, views=20, key_loop_views=6, layer_backed_views=14,
                               panel_is_key=True, app_key_is_panel=True),
                    ordering_calls={"NSView.viewDidChangeEffectiveAppearance": 2,
                                    "TasksPage.body": 1, "AtticTokenField.updateNSView": 1}))

    def test_unchanged_and_less_work_pass(self):
        a, b = self.evidence(), self.evidence()
        self.assertTrue(compare(a, b)["passed"])
        b["counts"]["after"]["views"] -= 1
        self.assertTrue(compare(a, b)["passed"])

    def test_extra_root_layer_key_view_or_callback_fails(self):
        for field in ("hosting_roots", "views", "key_loop_views", "layer_backed_views"):
            a, b = self.evidence(), self.evidence()
            b["counts"]["after"][field] += 1
            self.assertFalse(compare(a, b)["passed"])
        for field in ("NSView.viewDidChangeEffectiveAppearance", "TasksPage.body", "AtticTokenField.updateNSView"):
            a, b = self.evidence(), self.evidence()
            b["counts"]["ordering_calls"][field] += 1
            self.assertFalse(compare(a, b)["passed"])

    def test_unmatched_native_key_state_is_rejected(self):
        a, b = self.evidence(), self.evidence()
        b["counts"]["after"]["panel_is_key"] = False
        b["counts"]["after"]["app_key_is_panel"] = False
        with self.assertRaises(ValueError): compare(a, b)

    def test_missing_or_unresolved_native_functions_cannot_pass(self):
        a = self.evidence()
        a["counts"].pop("native_function_counts")
        with self.assertRaises(ValueError): metrics(a)
        a["counts"]["native_function_counts"] = {
            key: {"locations": 1, "calls": 2} for key in
            ("hosting_environment_updates", "native_appearance_applications", "ca_transaction_commits")
        }
        a["counts"]["native_function_counts"]["hosting_environment_updates"]["locations"] = 0
        with self.assertRaises(ValueError): metrics(a)

    def test_missing_invalid_or_mismatched_evidence_rejected(self):
        a = self.evidence()
        for path, value in ((["bundle"], "com.taha.Attic"), (["settings", "reveal_counts"], False),
                            (["counts", "hooks"], []), (["counts", "after", "hosting_roots"], 0),
                            (["counts", "after", "views"], -1)):
            bad = copy.deepcopy(a)
            target = bad
            for key in path[:-1]: target = target[key]
            target[path[-1]] = value
            with self.assertRaises(ValueError): metrics(bad)
        b = copy.deepcopy(a)
        b["settings"]["settle_seconds"] = 2
        with self.assertRaises(ValueError): compare(a, b)
        b = copy.deepcopy(a)
        b["counts"]["hooks"].append("another callback")
        with self.assertRaises(ValueError): compare(a, b)
