#!/usr/bin/env python3
"""No network or GitHub token required: release decision unit checks."""
import unittest
from release_decision import decide_release


class ReleaseDecisionTests(unittest.TestCase):
    def test_first_release_on_branch(self):
        self.assertEqual(decide_release('0.6.1', 'refs/heads/main', None, False)[0], True)

    def test_newer_version_publishes_without_manual_tag(self):
        self.assertEqual(decide_release('0.6.1', 'refs/heads/master', 'v0.6.0', False)[0], True)

    def test_same_version_does_not_release_again(self):
        self.assertEqual(decide_release('0.6.1', 'refs/heads/main', 'v0.6.1', True)[0], False)

    def test_lower_version_rejected(self):
        with self.assertRaises(ValueError):
            decide_release('0.6.1', 'refs/heads/main', 'v0.7.0', False)

    def test_existing_tag_unpublished_rejected(self):
        with self.assertRaises(ValueError):
            decide_release('0.6.1', 'refs/heads/main', 'v0.6.0', True)

    def test_unrelated_tag_rejected(self):
        with self.assertRaises(ValueError):
            decide_release('0.6.1', 'refs/tags/v0.6.0', 'v0.6.0', True)

    def test_version_arithmetic(self):
        self.assertTrue(decide_release('0.10.0', 'refs/heads/main', 'v0.9.9', False)[0])


if __name__ == '__main__':
    unittest.main()
