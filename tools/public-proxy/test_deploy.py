import unittest

from deploy import canonical_route


class ExistingRouteProtectionTests(unittest.TestCase):
    def test_generated_group_names_can_change(self):
        original = {"routes": [{"group": "group18"}, {"group": "group18"}]}
        candidate = {"routes": [{"group": "group19"}, {"group": "group19"}]}
        self.assertEqual(canonical_route(original, "a"), canonical_route(candidate, "b"))

    def test_group_membership_change_is_detected(self):
        original = {"routes": [{"group": "group18"}, {"group": "group18"}]}
        candidate = {"routes": [{"group": "group19"}, {"group": "group20"}]}
        self.assertNotEqual(canonical_route(original, "a"), canonical_route(candidate, "b"))

    def test_only_generated_config_hide_path_is_normalized(self):
        original = {"handler": "file_server", "hide": ["/etc/caddy/Caddyfile", ".env"]}
        candidate = {"handler": "file_server", "hide": ["/etc/caddy/candidate", ".env"]}
        self.assertEqual(
            canonical_route(original, "/etc/caddy/Caddyfile"),
            canonical_route(candidate, "/etc/caddy/candidate"),
        )
        candidate["hide"].remove(".env")
        self.assertNotEqual(
            canonical_route(original, "/etc/caddy/Caddyfile"),
            canonical_route(candidate, "/etc/caddy/candidate"),
        )

    def test_upstream_change_is_detected(self):
        original = {"handler": "reverse_proxy", "upstreams": [{"dial": "127.0.0.1:18080"}]}
        candidate = {"handler": "reverse_proxy", "upstreams": [{"dial": "127.0.0.1:18090"}]}
        self.assertNotEqual(canonical_route(original, "a"), canonical_route(candidate, "b"))


if __name__ == "__main__":
    unittest.main()
