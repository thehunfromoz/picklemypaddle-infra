"""Unit tests for staging/tailscale_serve.py (SCRUM-38).

    python3 -m unittest discover -s tests -p '*_test.py'
"""
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location(
    "tailscale_serve", pathlib.Path(__file__).parent.parent / "staging" / "tailscale_serve.py")
ts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ts)

HOST = "home-server.tail8bc7ae.ts.net"
TARGET = "http://127.0.0.1:8088"

# What home-server already serves: another app on :443 (must never change).
OTHER_APP = {
    "TCP": {"443": {"HTTPS": True}},
    "Web": {f"{HOST}:443": {"Handlers": {"/": {"Proxy": "http://localhost:3000"}}}},
}


def with_staging(base=OTHER_APP, target=TARGET, funnel=False):
    cfg = {"TCP": dict(base.get("TCP", {})), "Web": dict(base.get("Web", {}))}
    cfg["TCP"]["8443"] = {"HTTPS": True}
    cfg["Web"][f"{HOST}:8443"] = {"Handlers": {"/": {"Proxy": target}}}
    if funnel:
        cfg["AllowFunnel"] = {f"{HOST}:8443": True}
    return cfg


class DnsName(unittest.TestCase):
    def test_reads_magicdns_name_without_trailing_dot(self):
        status = {"BackendState": "Running", "Self": {"DNSName": HOST + "."}}
        self.assertEqual(ts.dnsname(status), HOST)

    def test_refuses_when_not_running(self):
        with self.assertRaisesRegex(ts.Problem, "not running"):
            ts.dnsname({"BackendState": "Stopped"})

    def test_refuses_without_magicdns(self):
        with self.assertRaisesRegex(ts.Problem, "MagicDNS"):
            ts.dnsname({"BackendState": "Running", "Self": {"DNSName": ""}})


class Check(unittest.TestCase):
    def test_applies_alongside_the_other_app(self):
        self.assertEqual(ts.check(OTHER_APP, HOST, 8443, TARGET), "apply")

    def test_applies_on_an_empty_config(self):
        self.assertEqual(ts.check({}, HOST, 8443, TARGET), "apply")

    def test_already_set_up_is_a_no_op(self):
        self.assertEqual(ts.check(with_staging(), HOST, 8443, TARGET), "already")

    def test_refuses_a_port_used_by_something_else(self):
        with self.assertRaisesRegex(ts.Problem, "already served"):
            ts.check(with_staging(target="http://127.0.0.1:9999"), HOST, 8443, TARGET)

    def test_refuses_a_port_held_by_a_foreground_session(self):
        cfg = dict(OTHER_APP, Foreground={"abc": with_staging({}, target="http://127.0.0.1:5000")})
        with self.assertRaisesRegex(ts.Problem, "already served"):
            ts.check(cfg, HOST, 8443, TARGET)

    def test_refuses_funnel_on_the_staging_port(self):
        with self.assertRaisesRegex(ts.Problem, "Funnel"):
            ts.check(with_staging(funnel=True), HOST, 8443, TARGET)


class State(unittest.TestCase):
    def test_states(self):
        self.assertEqual(ts.state(OTHER_APP, HOST, 8443, TARGET), "free")
        self.assertEqual(ts.state(with_staging(), HOST, 8443, TARGET), "ours")
        self.assertEqual(ts.state(with_staging(target="http://127.0.0.1:1"), HOST, 8443, TARGET), "other")
        self.assertEqual(ts.state(with_staging(funnel=True), HOST, 8443, TARGET), "other")


class Verify(unittest.TestCase):
    def test_accepts_staging_added_and_443_unchanged(self):
        ts.verify(OTHER_APP, with_staging(), HOST, 8443, TARGET)

    def test_ignores_etag_changes(self):
        ts.verify(dict(OTHER_APP, ETag="a"), dict(with_staging(), ETag="b"), HOST, 8443, TARGET)

    def test_rejects_a_change_to_the_other_app(self):
        after = with_staging()
        after["Web"][f"{HOST}:443"] = {"Handlers": {"/": {"Proxy": TARGET}}}
        with self.assertRaisesRegex(ts.Problem, "other than staging"):
            ts.verify(OTHER_APP, after, HOST, 8443, TARGET)

    def test_rejects_funnel(self):
        with self.assertRaisesRegex(ts.Problem, "Funnel"):
            ts.verify(OTHER_APP, with_staging(funnel=True), HOST, 8443, TARGET)

    def test_rejects_funnel_switched_on_elsewhere(self):
        after = dict(with_staging(), AllowFunnel={f"{HOST}:443": True})
        with self.assertRaisesRegex(ts.Problem, "other than staging"):
            ts.verify(OTHER_APP, after, HOST, 8443, TARGET)

    def test_rejects_wrong_target_or_plain_tcp(self):
        with self.assertRaisesRegex(ts.Problem, "does not point"):
            ts.verify(OTHER_APP, with_staging(target="http://127.0.0.1:1"), HOST, 8443, TARGET)
        after = with_staging()
        after["TCP"]["8443"] = {"HTTPS": False}
        with self.assertRaisesRegex(ts.Problem, "HTTPS"):
            ts.verify(OTHER_APP, after, HOST, 8443, TARGET)

    def test_off_removes_only_staging(self):
        ts.verify_off(with_staging(), OTHER_APP, HOST, 8443)
        with self.assertRaisesRegex(ts.Problem, "still served"):
            ts.verify_off(with_staging(), with_staging(), HOST, 8443)
        with self.assertRaisesRegex(ts.Problem, "other than staging"):
            ts.verify_off(with_staging(), {}, HOST, 8443)


if __name__ == "__main__":
    unittest.main()
